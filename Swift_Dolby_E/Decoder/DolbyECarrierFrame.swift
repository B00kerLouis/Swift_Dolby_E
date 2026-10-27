// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyECarrierFrame: Sendable {
    public let program: DolbyEProgram
    public let frameRate: DolbyEFrameRate
    public let frameNumber: UInt16
    public let versions: [Int]
    public let firstGains: [UInt16]
    public let secondGains: [UInt16]
    public let audioSegments: [[UInt32]]
    public let meterCodes: [UInt16]
    public let ac3Metadata: [DolbyEAC3ProgramInfo]
    /// Complete packed Evolution/EMDF tail, still protected by its own checksum
    /// and authentication. Section CRC validity does not verify this metadata.
    public let evolutionWords: [UInt32]
    public let coreWords: [UInt32]

    /// Accepts either a burst starting at Pa or one edit unit with a leading
    /// AES3 null guard. Only whole, zero-valued AES3 frames may precede Pa.
    public init(words: [UInt32]) throws {
        let start = words.firstIndex(where: { $0 != 0 }) ?? words.count
        guard start % 2 == 0, start <= 4094, words.count - start >= 8,
              words[start] == 0x6f872000, words[start + 1] == 0x54e1f000 else {
            throw DolbyEError.malformed("missing 20-bit SMPTE carrier preamble")
        }
        // Pc's 16-bit control field stays aligned at bit 16 in a 20-bit word;
        // Pd's bit count uses all twenty significant bits, aligned at bit 12.
        let info = words[start + 2] >> 16
        let lengthBits = Int(words[start + 3] >> 12)
        let payloadCount = (lengthBits + 19) / 20
        guard info & 31 == 28, (info >> 5) & 3 == 1,
              lengthBits > 0, payloadCount <= 4095, payloadCount <= words.count - start - 4 else {
            throw DolbyEError.malformed("carrier data type, word width or burst length")
        }
        var payload = Array(words[(start + 4)..<(start + 4 + payloadCount)])
        if lengthBits % 20 != 0 {
            let padding = 20 - lengthBits % 20
            // Pd is a bit length, not a count of complete AES words. Bits
            // below that length are outside the burst and are not parsed.
            payload[payload.count - 1] &= ~(((1 << padding) - 1) << 12)
        }
        let sync = payload[0] >> 12
        guard sync & 0xffffe == 0x0788e else { throw DolbyEError.malformed("invalid Dolby E frame sync") }
        var cursor = SectionCursor(words: payload, offset: 1, keyed: sync & 1 != 0)
        let first = try cursor.peek()
        let metadataCount = Int((first >> 18) & 1023)
        guard metadataCount > 0 else { throw DolbyEError.malformed("zero metadata size") }
        let metadata = try cursor.read(metadataCount)
        let header = try DolbyEDecoding.inspectPrimaryMetadata(words: metadata)
        let program: DolbyEProgram
        switch header.programConfiguration {
        case 0: program = .fiveOnePlusTwo
        case 10: program = .eightMono
        case 23: program = .sevenOneScreen
        default: throw DolbyEError.unsupported("program configuration \(header.programConfiguration)")
        }
        guard let rate = DolbyEFrameRate.allCases.first(where: { $0.referenceCode == header.frameRateCode }) else {
            throw DolbyEError.malformed("video cadence code")
        }
        var bits = try DolbyEBitReader(words: metadata)
        for _ in 0..<6 { _ = try bits.read(bits: 32) }
        _ = try bits.read(bits: 20)
        for _ in program.programChannelCounts { _ = try bits.read(bits: 10) }
        var versions: [Int] = [], firstGains: [UInt16] = [], secondGains: [UInt16] = []
        for _ in 0..<8 {
            let version = Int(try bits.read(bits: 4))
            guard version < 2 else { throw DolbyEError.malformed("unsupported channel coding version") }
            versions.append(version)
            _ = try bits.read(bits: 1)
            firstGains.append(UInt16(try bits.read(bits: 10)))
            secondGains.append(UInt16(try bits.read(bits: 10)))
        }
        let ac3 = try DolbyEAC3MetadataReader.read(&bits, programs: program.programChannelCounts.count)
        var segments: [[UInt32]] = []
        for half in 0..<2 {
            for group in 0..<2 {
                let sizes = Array(header.audioSegmentWordCounts[(group * 4)..<(group * 4 + 4)])
                guard sizes.allSatisfy({ $0 > 0 }) else { throw DolbyEError.malformed("empty audio channel segment") }
                let data = try cursor.read(sizes.reduce(0, +))
                var offset = 0
                for count in sizes {
                    segments.append(Array(data[offset..<(offset + count)]))
                    offset += count
                }
            }
            if half == 0 { _ = try cursor.read(header.extendedMetadataWordCount) }
        }
        let meterWords = try cursor.read(header.meterWordCount)
        var meters: [UInt16] = []
        if !meterWords.isEmpty {
            var meterReader = try DolbyEBitReader(words: meterWords)
            for _ in 0..<16 { meters.append(UInt16(try meterReader.read(bits: 10))) }
        }
        let tail = Array(payload[cursor.offset...])
        if tail.contains(where: { $0 != 0 }) {
            guard header.evolutionDataPresent, tail.first.map({ $0 >> 16 == 0x5838 }) == true else {
                throw DolbyEError.malformed("unexpected trailing Dolby E payload")
            }
        }
        self.program = program
        self.frameRate = rate
        self.frameNumber = header.timecodeWords[0]
        self.versions = versions
        self.firstGains = firstGains
        self.secondGains = secondGains
        self.audioSegments = segments
        self.meterCodes = meters
        self.ac3Metadata = ac3
        self.evolutionWords = tail.contains(where: { $0 != 0 }) ? tail : []
        self.coreWords = Array(payload.prefix(cursor.offset))
    }

    private struct SectionCursor {
        let words: [UInt32]
        var offset: Int
        let keyed: Bool

        func peek() throws -> UInt32 {
            guard offset < words.count, !keyed || offset + 1 < words.count else {
                throw DolbyEError.malformed("truncated section key")
            }
            return keyed ? words[offset + 1] ^ words[offset] : words[offset]
        }

        mutating func read(_ count: Int) throws -> [UInt32] {
            guard count >= 0, count < 4096, offset <= words.count,
                  count + 1 + (keyed ? 1 : 0) <= words.count - offset else {
                throw DolbyEError.malformed("section extends beyond declared burst")
            }
            let key: UInt32
            if keyed { key = words[offset]; offset += 1 } else { key = 0 }
            let section = words[offset..<(offset + count + 1)].map { $0 ^ key }
            offset += count + 1
            guard try DolbyEIntegrity.remainder(of: section, wordWidth: 20) == 0 else {
                throw DolbyEError.malformed("Dolby E section CRC mismatch")
            }
            return Array(section.dropLast())
        }
    }
}
