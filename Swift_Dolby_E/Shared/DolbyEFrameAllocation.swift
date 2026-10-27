// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyEFrameAllocation: Sendable {
    public let payloadWords: Int
    public let metadataWords: Int
    public let extensionWords: Int
    public let meterWords: Int
    public let audioWords: [Int]
    public let paddingBits: Int

    public init(program: DolbyEProgram, rate: DolbyEFrameRate, payloadWords override: Int? = nil,
                evolution: Bool = false, audioWordCounts: [Int]? = nil) throws {
        // Historical raw-metadata/reference-vector budgets. A complete carrier
        // encoder supplies its actual cadence-aware RDD 33 capacity explicitly.
        let payload = override ?? [3644, 3640, 3648, 3040, 3040][rate.referenceCode - 1]
        guard (1024...4095).contains(payload) else { throw DolbyEError.invalidArgument("frame payload word count") }
        let count = program.programChannelCounts.count
        let rawMetadataBits = count * 131 + 144 + 8 * 35 + 8 + (evolution ? count * 6 + 20 : 0)
        var metadata = (rawMetadataBits + 19) / 20
        let extensionSize = (count * 40 + 20 + 19) / 20
        let budget = payload - 8 - metadata - 8 - extensionSize
        let weighted = program.lfeChannel == nil ? budget / 8 : Int(Double(budget) * 0.14084507042253522)
        var audio = [Int](repeating: weighted / 2, count: 8)
        if program.lfeChannel != nil { audio[5] = Int(Double(weighted) * 0.1) / 2 }
        let extra = (budget - 2 * audio.reduce(0, +)) / 2
        for index in 0..<extra { audio[index % 8] += 1 }
        let remainder = budget - 2 * audio.reduce(0, +)
        if let audioWordCounts {
            guard audioWordCounts.count == 8, audioWordCounts.allSatisfy({ (1...1023).contains($0) }),
                  audioWordCounts.reduce(0, +) == audio.reduce(0, +) else {
                throw DolbyEError.invalidArgument("audio allocation must preserve the frame word budget")
            }
            audio = audioWordCounts
        }
        let padding = metadata * 20 - rawMetadataBits + remainder * 20
        metadata += remainder
        self.payloadWords = payload
        self.metadataWords = metadata
        self.extensionWords = extensionSize
        self.meterWords = 8
        self.audioWords = audio
        self.paddingBits = padding
    }
}
