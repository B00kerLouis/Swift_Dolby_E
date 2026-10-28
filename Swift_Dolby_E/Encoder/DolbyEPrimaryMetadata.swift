// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Seven 16-bit program metadata words, initialized directly or from typed AC-3 settings.
public struct DolbyEProgramMetadata: Codable, Sendable {
    public let rawWords: [UInt16]
    public let ac3: DolbyEAC3Metadata?

    public init(rawWords: [UInt16]) throws {
        guard rawWords.count == 7 else { throw DolbyEError.invalidArgument("program metadata requires seven words") }
        self.rawWords = rawWords
        self.ac3 = nil
    }
    public init(ac3: DolbyEAC3Metadata) throws {
        try ac3.validate()
        self.rawWords = ac3.referenceWords; self.ac3 = ac3
    }

    private enum CodingKeys: String, CodingKey { case rawWords, ac3 }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let words = try values.decode([UInt16].self, forKey: .rawWords)
        if let settings = try values.decodeIfPresent(DolbyEAC3Metadata.self, forKey: .ac3) {
            try self.init(ac3: settings)
            guard rawWords == words else { throw DolbyEError.malformed("AC-3 metadata checkpoint fields disagree") }
        } else { try self.init(rawWords: words) }
    }
}

public struct DolbyEMetadataSection: Sendable {
    public let words: [UInt32]
    public let audioSegmentWordCounts: [Int]
    public let extendedMetadataWordCount: Int
    public let meterWordCount: Int
}

/// Emits the primary metadata section.
/// This section is not a complete encoded audio frame and must not be delivered as one.
public enum DolbyEPrimaryMetadata {
    public static func fiveOnePlusTwo(frameRate: DolbyEFrameRate, timecodeWords: [UInt16],
                                      programs: [DolbyEProgramMetadata]) throws -> DolbyEMetadataSection {
        try encode(program: .fiveOnePlusTwo, frameRate: frameRate, timecodeWords: timecodeWords, programs: programs)
    }

    public static func encode(program: DolbyEProgram, frameRate: DolbyEFrameRate, timecodeWords: [UInt16],
                               programs: [DolbyEProgramMetadata], evolution: Bool = false,
                               payloadWordCount: Int? = nil, audioWordCounts: [Int]? = nil,
                               channelGains: [UInt16] = Array(repeating: 960, count: 8)) throws -> DolbyEMetadataSection {
        let programCount = program.programChannelCounts.count
        guard timecodeWords.count == 5, programs.count == programCount,
              channelGains.count == 8, channelGains.allSatisfy({ $0 < 1024 }) else {
            throw DolbyEError.invalidArgument("program metadata record count or timecode word count")
        }
        let allocation = try DolbyEFrameAllocation(program: program, rate: frameRate, payloadWords: payloadWordCount,
            evolution: evolution, audioWordCounts: audioWordCounts)
        let sizes = allocation.audioWords
        var writer = try DolbyEBitWriter(capacityWords: allocation.metadataWords)
        try writer.append(0, bits: 4)
        try writer.append(UInt32(allocation.metadataWords), bits: 10)
        try writer.append(UInt32(program.referenceTableIndex), bits: 6)
        try writer.append(UInt32(frameRate.referenceCode), bits: 4)
        try writer.append(UInt32(frameRate.referenceCode), bits: 4)
        for timecode in timecodeWords { try writer.append(UInt32(timecode), bits: 16) }
        try writer.append(evolution ? 128 : 0, bits: 8)
        for size in sizes { try writer.append(UInt32(size), bits: 10) }
        try writer.append(UInt32(allocation.extensionWords), bits: 8)
        try writer.append(UInt32(allocation.meterWords), bits: 8)
        for _ in 0..<programCount { try writer.append(0, bits: 8); try writer.append(0, bits: 2) }
        for gain in channelGains {
            try writer.append(1, bits: 4)
            try writer.append(0, bits: 1)
            try writer.append(UInt32(gain), bits: 10)
            try writer.append(UInt32(gain), bits: 10)
        }
        try writer.append(1, bits: 4)
        try writer.append(UInt32(programCount * 121), bits: 12)
        let centerCodes: [UInt32] = [0, 0, 0, 0, 0, 1, 2, 2]
        let surroundCodes: [UInt32] = [0, 0, 0, 0, 0, 1, 1, 2]
        for program in programs {
            let p = program.rawWords.map(UInt32.init)
            try writer.append(UInt32(program.ac3?.bitRateCode ?? 31), bits: 5)
            try writer.append((p[0] >> 10) & 7, bits: 3)
            try writer.append((p[0] >> 7) & 7, bits: 3)
            try writer.append(centerCodes[Int((p[3] >> 3) & 7)], bits: 2)
            try writer.append(surroundCodes[Int(p[3] & 7)], bits: 2)
            try writer.append((p[0] >> 1) & 3, bits: 2)
            try writer.append(p[0] & 1, bits: 1)
            try writer.append((p[1] >> 9) & 31, bits: 5)
            try writer.append(0, bits: 1)
            try writer.append(0, bits: 8)
            try writer.append((p[2] >> 9) & 1, bits: 1)
            try writer.append((p[2] >> 4) & 31, bits: 5)
            try writer.append((p[2] >> 2) & 3, bits: 2)
            try writer.append((p[2] >> 1) & 1, bits: 1)
            try writer.append(p[2] & 1, bits: 1)
            try writer.append(1, bits: 1)
            try writer.append(p[3] & 0x3fff, bits: 14)
            try writer.append(1, bits: 1)
            try writer.append(p[4] & 0x3fff, bits: 14)
            for bit in stride(from: 14, through: 10, by: -1) {
                try writer.append((p[5] >> bit) & 1, bits: 1)
            }
            try writer.append(program.ac3?.rfPreEmphasis == true ? 1 : 0, bits: 1)
            try writer.append(0, bits: 1)
            try writer.append(p[5] & 255, bits: 8)
            try writer.append(0, bits: 1)
            try writer.append(p[6] & 255, bits: 8)
            for _ in 0..<3 { try writer.append(UInt32(program.ac3?.lineProfile.code ?? 0), bits: 8) }
        }
        for _ in 0..<programCount { try writer.append(0, bits: 1) }
        try writer.append(0, bits: 4)
        if evolution {
            // Intelligent-loudness evolution segment. No loudness correction
            // has been applied to the encoded independent essence signals.
            try writer.append(1, bits: 4)
            try writer.append(UInt32(programCount * 6), bits: 12)
            for _ in 0..<programCount { try writer.append(0, bits: 6) }
            try writer.append(0, bits: 4)
        }
        // The final unused capacity is protocol zero padding.
        return DolbyEMetadataSection(words: writer.finalizedWords(), audioSegmentWordCounts: sizes,
                                     extendedMetadataWordCount: allocation.extensionWords, meterWordCount: allocation.meterWords)
    }
}
