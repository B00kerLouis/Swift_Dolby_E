// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Reads left-justified significant words using the same bit order as the encoder.
public struct DolbyEBitReader: Sendable {
    public let wordWidth: Int
    public private(set) var bitPosition = 0
    private let words: [UInt32]

    public init(words: [UInt32], wordWidth: Int = 20) throws {
        guard [16, 20, 24].contains(wordWidth), words.count <= 65536 else {
            throw DolbyEError.invalidArgument("invalid word width or metadata capacity")
        }
        let lowMask = (UInt32(1) << (32 - wordWidth)) - 1
        guard words.allSatisfy({ $0 & lowMask == 0 }) else {
            throw DolbyEError.malformed("nonzero bits below significant word width")
        }
        self.words = words
        self.wordWidth = wordWidth
    }

    public mutating func read(bits: Int) throws -> UInt32 {
        guard (1...32).contains(bits), bits <= words.count * wordWidth - bitPosition else {
            throw DolbyEError.malformed("truncated bit field at bit \(bitPosition)")
        }
        var result: UInt32 = 0, remaining = bits
        while remaining > 0 {
            let offset = bitPosition % wordWidth
            let count = min(remaining, wordWidth - offset)
            let mask = (UInt32(1) << count) - 1
            let value = (words[bitPosition / wordWidth] >> (32 - offset - count)) & mask
            result = (result &<< count) | value
            bitPosition += count; remaining -= count
        }
        return result
    }
}

public struct DolbyEPrimaryMetadataView: Codable, Sendable {
    public let revision: UInt32
    public let wordCount: Int
    public let programConfiguration: UInt32
    public let frameRateCode: UInt32
    public let timecodeWords: [UInt16]
    public let audioSegmentWordCounts: [Int]
    public let extendedMetadataWordCount: Int
    public let meterWordCount: Int
    public let evolutionDataPresent: Bool
}

/// Parses unsynchronized primary metadata sections, not compressed audio or an entire carrier.
public enum DolbyEDecoding {
    public static func inspectPrimaryMetadata(words: [UInt32]) throws -> DolbyEPrimaryMetadataView {
        var reader = try DolbyEBitReader(words: words)
        let revision = try reader.read(bits: 4)
        let count = Int(try reader.read(bits: 10))
        guard revision == 0, count == words.count else {
            throw DolbyEError.malformed("primary metadata revision or declared word count")
        }
        let config = try reader.read(bits: 6)
        guard config == 0 || config == 10 || config == 23 else { throw DolbyEError.unsupported("primary metadata configuration \(config)") }
        let rate = try reader.read(bits: 4)
        guard (1...5).contains(rate), try reader.read(bits: 4) == rate else {
            throw DolbyEError.malformed("invalid or inconsistent frame-rate codes")
        }
        var timecode: [UInt16] = []
        for _ in 0..<5 { timecode.append(UInt16(try reader.read(bits: 16))) }
        let evolutionFlags = try reader.read(bits: 8)
        guard evolutionFlags & 127 == 0 else { throw DolbyEError.malformed("nonzero reserved metadata field") }
        var sizes: [Int] = []
        for _ in 0..<8 { sizes.append(Int(try reader.read(bits: 10))) }
        let extended = Int(try reader.read(bits: 8))
        let meters = Int(try reader.read(bits: 8))
        return DolbyEPrimaryMetadataView(revision: revision, wordCount: count, programConfiguration: config,
                                         frameRateCode: rate, timecodeWords: timecode,
                                         audioSegmentWordCounts: sizes, extendedMetadataWordCount: extended,
                                         meterWordCount: meters, evolutionDataPresent: evolutionFlags & 128 != 0)
    }
}
