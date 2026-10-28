// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Packs fields MSB first into left-justified 32-bit storage words.
/// The significant width is independent of the storage width. Final unused bits are zero.
public struct DolbyEBitWriter: Sendable {
    public let wordWidth: Int
    public let capacityWords: Int
    public private(set) var bitCount = 0
    private var words: [UInt32]

    public init(wordWidth: Int = 20, capacityWords: Int) throws {
        guard [16, 20, 24].contains(wordWidth), (0...65536).contains(capacityWords) else {
            throw DolbyEError.invalidArgument("packing requires 16/20/24-bit words and a bounded capacity")
        }
        self.wordWidth = wordWidth
        self.capacityWords = capacityWords
        self.words = Array(repeating: 0, count: capacityWords)
    }

    public mutating func append(_ value: UInt32, bits: Int) throws {
        guard (1...wordWidth).contains(bits), value < UInt32(1) << bits else {
            throw DolbyEError.invalidArgument("\(value) does not fit a \(bits)-bit field")
        }
        guard bits <= capacityWords * wordWidth - bitCount else {
            throw DolbyEError.invalidArgument("bit writer capacity exceeded")
        }
        var remaining = bits
        while remaining > 0 {
            let wordIndex = bitCount / wordWidth
            let offset = bitCount % wordWidth
            let portion = min(remaining, wordWidth - offset)
            let field = (value >> (remaining - portion)) & ((UInt32(1) << portion) - 1)
            words[wordIndex] |= field << (32 - offset - portion)
            bitCount += portion
            remaining -= portion
        }
    }

    /// Returns the complete declared capacity, including zero padding.
    public func finalizedWords() -> [UInt32] { words }

    /// Converts left-justified storage to packed 24-bit little-endian carrier samples.
    /// This packs words only; it does not create a complete Dolby E audio frame.
    public func packed24BitSamples() -> Data {
        var data = Data()
        data.reserveCapacity(words.count * 3)
        for word in words {
            data.append(UInt8(truncatingIfNeeded: word >> 8))
            data.append(UInt8(truncatingIfNeeded: word >> 16))
            data.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return data
    }
}
