// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Reference-derived polynomial division on significant word bits, MSB first.
/// Initial remainder is zero; input bits enter at the low bit before reduction.
/// This is deliberately not a generic CRC-16 preset with an implicit augmentation.
public enum DolbyEIntegrity {
    private static func zeroRemainders(bits: Int) -> [UInt16] {
        (0..<(1 << bits)).map { value in
            var state = UInt16(value) << (16 - bits)
            for _ in 0..<bits {
                let carry = state & 0x8000 != 0
                state = state &<< 1
                if carry { state ^= 0x8005 }
            }
            return state
        }
    }
    private static let octets = zeroRemainders(bits: 8)
    private static let nibbles = zeroRemainders(bits: 4)

    public static func remainder(of words: [UInt32], wordWidth: Int) throws -> UInt16 {
        try validate(words, width: wordWidth)
        var crc: UInt16 = 0
        for word in words {
            // Input enters the low bits after reduction, unlike an augmented
            // CRC preset. These tables only advance the existing remainder.
            crc = (crc &<< 8) ^ octets[Int(crc >> 8)] ^ UInt16(word >> 24)
            crc = (crc &<< 8) ^ octets[Int(crc >> 8)] ^ UInt16((word >> 16) & 255)
            if wordWidth == 20 { crc = (crc &<< 4) ^ nibbles[Int(crc >> 12)] ^ UInt16((word >> 12) & 15) }
            else if wordWidth == 24 { crc = (crc &<< 8) ^ octets[Int(crc >> 8)] ^ UInt16((word >> 8) & 255) }
        }
        return crc
    }

    /// The final word is reserved for the remainder. Existing payload is never overwritten.
    public static func appendingCRC(to payload: [UInt32], wordWidth: Int) throws -> [UInt32] {
        guard payload.count < 65536 else { throw DolbyEError.invalidArgument("CRC section too large") }
        var result = payload + [0]
        let crc = try remainder(of: result, wordWidth: wordWidth)
        result[result.count - 1] = UInt32(crc) << (32 - wordWidth)
        return result
    }

    /// Selects the first unused 10-bit prefix and applies the reference synchronization mask.
    /// This operation is transport scrambling, with no encryption or license behavior.
    public static func applySynchronization(to words: [UInt32], wordWidth: Int, key: UInt16 = 0) throws
        -> (syncWord: UInt32, words: [UInt32]) {
        try validate(words, width: wordWidth)
        guard !words.isEmpty else { throw DolbyEError.invalidArgument("synchronization requires a reserved first word") }
        var used = Array(repeating: false, count: 1024)
        for word in words.dropFirst() { used[Int(word >> 22)] = true }
        guard let prefix = used.firstIndex(of: false) else {
            throw DolbyEError.invalidArgument("all 1024 synchronization prefixes are present")
        }
        let base: UInt32
        switch wordWidth {
        case 16: base = 0x340000
        case 20: base = 0x151000
        default: base = 0x257800
        }
        let sync = (UInt32(prefix) << 22 | base) ^ (UInt32(key) << 16)
        var masked = words
        masked[0] = sync
        for index in 1..<masked.count { masked[index] ^= sync }
        return (sync, masked)
    }

    private static func validate(_ words: [UInt32], width: Int) throws {
        guard [16, 20, 24].contains(width), words.count <= 65536 else {
            throw DolbyEError.invalidArgument("invalid significant word width or section size")
        }
        let lowMask = (UInt32(1) << (32 - width)) - 1
        guard words.allSatisfy({ $0 & lowMask == 0 }) else {
            throw DolbyEError.invalidArgument("word contains nonzero bits outside significant width")
        }
    }
}
