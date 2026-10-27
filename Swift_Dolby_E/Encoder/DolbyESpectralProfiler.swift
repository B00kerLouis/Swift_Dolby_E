// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Optional bounded preflight for a known programme. Feed the same complete
/// routed/limited PCM as the encoder, then configure one fixed shift vector.
/// This is distinct from live encoding and never changes gains from the first
/// silent frame or normalizes individual frames independently.
public struct DolbyESpectralProfiler: Codable,Sendable {
    private var e: DolbyEPCMFrameEncoder?
    private var ed2: DolbyED2PCMFrameEncoder?
    public private(set) var peaks: [Double]
    public private(set) var samplePosition: UInt64 = 0
    public init(encodeVision: DolbyEEncodeVision = .e,program: DolbyEProgram = .fiveOnePlusTwo,
                frameRate: DolbyEFrameRate = .fps25) throws {
        if encodeVision == .ed2 { ed2 = try DolbyED2PCMFrameEncoder(frameRate:frameRate);peaks = Array(repeating:0,count:16) }
        else {
            e = try DolbyEPCMFrameEncoder(program:program,frameRate:frameRate,programs:program.programChannelCounts.indices.map {
                try DolbyEProgramMetadata(ac3:.defaults(program:program,index:$0))
            });peaks = Array(repeating:0,count:8)
        }
    }
    public func requiredInputFrames() throws -> Int {
        if let e { return try e.requiredInputFrames() }
        guard let ed2 else { throw DolbyEError.malformed("spectral profiler codec") }
        return try ed2.requiredInputFrames()
    }
    public mutating func append(_ pcm: [Double],maximumParallelism:Int=0) throws {
        var next = self
        let count = try requiredInputFrames(),end = samplePosition.addingReportingOverflow(UInt64(count))
        guard !end.overflow else { throw DolbyEError.invalidArgument("profiler sample clock overflow") }
        let values: [Double]
        if var encoder = next.e { values = try encoder.measureSpectralPeaks(pcm,maximumParallelism:maximumParallelism);next.e = encoder }
        else if var encoder = next.ed2 { values = try encoder.measureSpectralPeaks(pcm,maximumParallelism:maximumParallelism);next.ed2 = encoder }
        else { throw DolbyEError.malformed("spectral profiler codec") }
        next.peaks = zip(peaks,values).map(max);next.samplePosition = end.partialValue
        self = next
    }
    public func spectralShifts() throws -> [Int] {
        guard samplePosition > 0 else { throw DolbyEError.invalidArgument("profile contains no PCM") }
        return try DolbyEPCMFrameEncoder.normalizationShifts(peaks:peaks)
    }
}
