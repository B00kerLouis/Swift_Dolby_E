// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Dispatch

typealias DolbyEEncoderWork = DolbyEParallelWork

/// Assembles the complete two-channel 20-bit carrier frame from both audio halves.
/// Analysis input order is the stream's even-channel group followed by its odd-channel group.
public enum DolbyEFrameEncoder {
    public static func encodeFiveOnePlusTwo25(analysisInputs: [[Double]], frameNumber: UInt16,
                                              programs: [DolbyEProgramMetadata], meters: [UInt16]) throws -> [UInt32] {
        try encode(analysisInputs: analysisInputs, program: .fiveOnePlusTwo, frameRate: .fps25,
                   carrierFrames: 1920, frameNumber: frameNumber, programs: programs, meters: meters)
    }

    public static func encode(analysisInputs: [[Double]], program: DolbyEProgram, frameRate: DolbyEFrameRate,
                               carrierFrames: Int, frameNumber: UInt16, programs: [DolbyEProgramMetadata],
                               meters: [UInt16], evolution: Bool = false, payloadWordCount: Int? = nil,
                               spectralShifts: [Int] = Array(repeating: 0, count: 8),
                               maximumParallelism: Int = 0) throws -> [UInt32] {
        guard analysisInputs.count == 16, meters.count == 16, meters.allSatisfy({ $0 < 1024 }),
              spectralShifts.count == 8, spectralShifts.allSatisfy({ (0...14).contains($0) }) else {
            throw DolbyEError.invalidArgument("frame requires two eight-channel analysis halves and 16 meter fields")
        }
        let timing = DolbyECarrierTiming(frameRate: frameRate)
        let capacity = try timing.maximumPayloadWords(carrierFrames: carrierFrames)
        // Do not expand an admitted audio profile merely to fill transport
        // space. At 23.976/24 fps the nominal core leaves additional null
        // padding beyond the reserved Table 5 interval.
        let nominal = try DolbyEFrameAllocation(program: program, rate: frameRate, evolution: evolution).payloadWords
        let payloadWords = payloadWordCount ?? min(nominal, capacity)
        guard payloadWords <= capacity else {
            throw DolbyEError.invalidArgument("payload exceeds the RDD 33 carrier guard-band capacity")
        }
        let allocation = try DolbyEFrameAllocation(program: program, rate: frameRate, payloadWords: payloadWords, evolution: evolution)
        let parallelism = try DolbyEEncoderWork.limit(maximumParallelism)
        var segments = try DolbyEEncoderWork.map(analysisInputs,parallelism:parallelism) { input,index in
                let half = index / 8,wire = index % 8
                let lfe = program.lfeChannel != nil && wire == 5
                let block: DolbyEAnalysisBlock = lfe ? (half == 0 ? .lfeLongStart : .lfeLongContinue)
                    : (half == 0 ? .longStart : .longContinue)
                let spectrum = try DolbyEAnalysisBank.analyze(input, block: block)
                let scale = Double(1 << spectralShifts[wire])
                let scaled = spectrum.map { $0 * scale }
                guard scaled.allSatisfy({ abs($0) < 1 }) else {
                    throw DolbyEError.invalidArgument("spectral normalization exceeds quantizer headroom")
                }
                return try DolbyEAudioSegment.Prepared(coefficients: scaled,
                lfe: program.lfeChannel != nil && index % 8 == 5, rate: frameRate)
        }
        let sizes = try allocate(&segments, nominal: allocation.audioWords,maximumParallelism:parallelism)
        let encoded = try DolbyEEncoderWork.map(segments,parallelism:parallelism) { segment,index in
            try segment.words(capacityWords:sizes[index % 8])
        }
        let metadata = try DolbyEPrimaryMetadata.encode(program: program, frameRate: frameRate,
                                                         timecodeWords: [frameNumber, 0x3f, 0, 0, 0], programs: programs,
                                                         evolution: evolution, payloadWordCount: payloadWords,
                                                         audioWordCounts: sizes,
                                                         channelGains: spectralShifts.map { UInt16(960 - $0 * 64) })
        var payload: [UInt32] = [0x0788e000]
        payload += try DolbyEIntegrity.appendingCRC(to: metadata.words, wordWidth: 20)
        for half in 0..<2 {
            for group in 0..<2 {
                var segment: [UInt32] = []
                for wireChannel in (group * 4)..<(group * 4 + 4) {
                    segment += encoded[half * 8 + wireChannel]
                }
                payload += try DolbyEIntegrity.appendingCRC(to: segment, wordWidth: 20)
            }
            if half == 0 {
                // Disabled optional per-program user bytes use empty extension syntax.
                var extensionBits = try DolbyEBitWriter(capacityWords: metadata.extendedMetadataWordCount)
                try extensionBits.append(1, bits: 4)
                let count = program.programChannelCounts.count
                try extensionBits.append(UInt32(count * 40), bits: 12)
                for _ in 0..<(count * 5) { try extensionBits.append(0, bits: 8) }
                try extensionBits.append(0, bits: 4)
                payload += try DolbyEIntegrity.appendingCRC(to: extensionBits.finalizedWords(), wordWidth: 20)
            }
        }
        var meterBits = try DolbyEBitWriter(capacityWords: metadata.meterWordCount)
        for value in meters { try meterBits.append(UInt32(value), bits: 10) }
        payload += try DolbyEIntegrity.appendingCRC(to: meterBits.finalizedWords(), wordWidth: 20)
        guard payload.count == allocation.payloadWords else { throw DolbyEError.malformed("encoder frame allocation does not match its declared payload") }
        var carrier = [UInt32](repeating: 0, count: timing.referenceOffsetFrames * 2)
        carrier += [0x6f872000, 0x54e1f000, 0x003c0000, UInt32(payload.count * 20) << 12]
        carrier += payload
        carrier += repeatElement(UInt32(0), count: carrierFrames * 2 - carrier.count)
        return carrier
    }

    /// Reclaim only proven unused words. Every active channel first receives
    /// its nominal slot; its selected spectrum remains a feasible candidate
    /// during redistribution. A heuristic cannot improve the reported average
    /// by silently worsening another channel. Two bounded passes reuse caches.
    static func allocate(_ segments: inout [DolbyEAudioSegment.Prepared], nominal: [Int],maximumParallelism: Int = 0) throws -> [Int] {
        let parallelism = try DolbyEEncoderWork.limit(maximumParallelism)
        if parallelism == 1 { for index in segments.indices { try segments[index].fit(capacityWords:nominal[index % 8]) } }
        else { segments = try DolbyEEncoderWork.map(segments,parallelism:parallelism) { value,index in
            var result = value;try result.fit(capacityWords:nominal[index % 8]);return result
        } }
        var sizes = nominal
        for _ in 0..<2 {
            sizes = (0..<8).map { max(segments[$0].usedWords,segments[$0+8].usedWords) }
            var remaining = nominal.reduce(0,+) - sizes.reduce(0,+)
            let active = (0..<8).filter { (segments[$0].selection?.error ?? 0) + (segments[$0+8].selection?.error ?? 0) > 0 }
            let recipients = active.isEmpty ? Array(0..<8) : active
            while remaining > 0 {
                let available = recipients.filter { sizes[$0] < 1023 }
                let targets = available.isEmpty ? (0..<8).filter { sizes[$0] < 1023 } : available
                guard !targets.isEmpty else { throw DolbyEError.invalidArgument("audio allocation exceeds channel size fields") }
                for channel in targets where remaining > 0 { sizes[channel] += 1; remaining -= 1 }
            }
            let capacities = sizes
            if parallelism == 1 {
                for index in segments.indices where capacities[index % 8] >= segments[index].usedWords + 4 { try segments[index].fit(capacityWords:capacities[index % 8]) }
            } else { segments = try DolbyEEncoderWork.map(segments,parallelism:parallelism) { value,index in
                var result = value
                if capacities[index % 8] >= result.usedWords + 4 { try result.fit(capacityWords:capacities[index % 8]) }
                return result
            } }
        }
        return sizes
    }
}
