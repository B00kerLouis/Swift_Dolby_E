// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Stateful eight-channel PCM-to-carrier codec for both supported programs and
/// all five video cadences. The last pair is program-two L/R or Screen Le/Re.
public struct DolbyEPCMFrameEncoder: Codable, Sendable {
    public let program: DolbyEProgram
    public let frameRate: DolbyEFrameRate
    private var resampler: DolbyEResampler
    private var channels: [DolbyEChannelAnalysis]
    private var frameNumber: UInt16 = 0
    private let programs: [DolbyEProgramMetadata]
    private let spectralShifts: [Int]

    public init(program: DolbyEProgram = .fiveOnePlusTwo, frameRate: DolbyEFrameRate = .fps25,
                programs: [DolbyEProgramMetadata], spectralShifts: [Int] = Array(repeating: 0, count: 8)) throws {
        guard programs.count == program.programChannelCounts.count, spectralShifts.count == 8,
              spectralShifts.allSatisfy({ (0...14).contains($0) }) else { throw DolbyEError.invalidArgument("metadata program count or spectral normalization") }
        self.program = program
        self.frameRate = frameRate
        self.programs = programs
        self.spectralShifts = spectralShifts
        self.resampler = try DolbyEResampler(channelCount: 8, frameRate: frameRate)
        self.channels = (0..<8).map { DolbyEChannelAnalysis(lfe: $0 == program.lfeChannel) }
    }

    public func requiredInputFrames() throws -> Int { try resampler.requiredInputFrames(outputFrames: 1792) }

    public mutating func encode(_ pcm: [Double], evolution: Bool = false, payloadWordCount: Int? = nil,
                                maximumParallelism: Int = 0) throws -> [UInt32] {
        // Analysis advances resampling and overlap history before assembly can
        // reject headroom or capacity. Commit the complete frame atomically.
        var next = self
        let result = try next.encodeFrame(pcm, evolution: evolution, payloadWordCount: payloadWordCount,maximumParallelism:maximumParallelism)
        self = next
        return result
    }

    private mutating func encodeFrame(_ pcm: [Double], evolution: Bool, payloadWordCount: Int?,maximumParallelism: Int) throws -> [UInt32] {
        let prepared = try prepare(pcm)
        let order = [0, 2, 4, 6, 1, 3, 5, 7]
        let result = try DolbyEFrameEncoder.encode(analysisInputs: prepared.inputs, program: program, frameRate: frameRate,
                                                   carrierFrames: pcm.count / 8, frameNumber: frameNumber,
                                                   programs: programs, meters: prepared.meters, evolution: evolution,
                                                   payloadWordCount: payloadWordCount, spectralShifts: order.map { spectralShifts[$0] },maximumParallelism:maximumParallelism)
        frameNumber &+= 1
        return result
    }

    /// Profiling uses its own codec value. It advances exactly the same bounded
    /// resampling/filter history without constructing or quantizing a frame.
    mutating func measureSpectralPeaks(_ pcm: [Double],maximumParallelism:Int=0) throws -> [Double] {
        var next=self
        let prepared=try next.prepare(pcm),program=self.program
        let order=[0,2,4,6,1,3,5,7]
        let values=try DolbyEParallelWork.map(prepared.inputs,parallelism:maximumParallelism) {input,index in
            let half=index/8,channel=order[index%8],lfe=channel==program.lfeChannel
            let block:DolbyEAnalysisBlock=lfe ? (half==0 ? .lfeLongStart:.lfeLongContinue):(half==0 ? .longStart:.longContinue)
            return try DolbyEAnalysisBank.analyze(input,block:block).map(abs).max() ?? 0
        }
        var peaks=Array(repeating:0.0,count:8)
        for index in values.indices{let channel=order[index%8];peaks[channel]=max(peaks[channel],values[index])}
        self=next;return peaks
    }

    static func normalizationShifts(peaks: [Double]) throws -> [Int] {
        guard peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1 }) else {
            throw DolbyEError.invalidArgument("source spectrum exceeds quantizer headroom")
        }
        return peaks.map { $0 == 0 ? 0 : max(0, min(14, Int(floor(log2(0.9 / $0))))) }
    }

    private mutating func prepare(_ pcm: [Double]) throws -> (inputs: [[Double]], meters: [UInt16]) {
        let frameCount = try requiredInputFrames()
        guard channels.count == 8, channels.enumerated().allSatisfy({ $0.element.isValidState && $0.element.lfe == ($0.offset == program.lfeChannel) }),
              resampler.channelCount == 8, resampler.frameRate == frameRate,
              pcm.count == frameCount * 8, pcm.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("PCM frame must contain \(frameCount) interleaved eight-channel samples")
        }
        let order = [0, 2, 4, 6, 1, 3, 5, 7]
        var prepared: [[Double]] = []
        var peak = [UInt16](repeating: 0, count: 8)
        var rms = [UInt16](repeating: 0, count: 8)
        var inputPosition = 0
        for half in 0..<2 {
            let count = try resampler.requiredInputFrames()
            let converted = try resampler.convert(Array(pcm[inputPosition..<(inputPosition + count * 8)]))
            inputPosition += count * 8
            for (wire, channel) in order.enumerated() {
                let samples = stride(from: channel, to: converted.count, by: 8).map { converted[$0] }
                let result = try channels[channel].prepare(samples, secondHalf: half == 1)
                prepared.append(result.samples)
                if let meters = result.meters { peak[wire] = meters.peak; rms[wire] = meters.rms }
            }
        }
        return (prepared, peak + rms)
    }
}
