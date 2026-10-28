// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

@available(macOS 13, *)
fileprivate struct DolbyEModernRealtimeDeadline: Sendable {
    let value: ContinuousClock.Instant
}

/// One complete carrier edit unit. ED2 is delivered as two synchronized AES
/// pairs. The deadline is a monotonic publication time, not hardware genlock.
public struct DolbyERealtimeFrame: Sendable {
    public let frameIndex: UInt64
    public let samplePosition: UInt64
    public let sampleCount: Int
    public let primaryWords: [UInt32]
    public let expansionWords: [UInt32]?
    public let deadlineUptimeNanoseconds: UInt64
    public let encodingDurationNanoseconds: UInt64
    public let latenessNanoseconds: UInt64
    fileprivate let modernDeadline: (any Sendable)?

    @available(macOS 13, *)
    public var deadline: ContinuousClock.Instant { (modernDeadline as! DolbyEModernRealtimeDeadline).value }
    @available(macOS 13, *)
    public var encodingDuration: Duration { .nanoseconds(Int64(encodingDurationNanoseconds)) }
    @available(macOS 13, *)
    public var lateness: Duration { .nanoseconds(Int64(latenessNanoseconds)) }
}

/// Bounded48kHz PCM-to-carrier encoding and1X publication. One in-flight frame,
/// no frame dropping/repetition and no unbounded AsyncStream queue. Raw live
/// inputs use fixed configured spectral shifts; there is no first-frame or
/// per-frame normalization. File jobs retain their full-source profiling pass.
public actor DolbyERealtimeEncoder {
    private enum Codec: Codable,Sendable {
        case e(DolbyEPCMFrameEncoder),ed2(DolbyED2PCMFrameEncoder)
        var rate: DolbyEFrameRate { switch self { case .e(let c):c.frameRate;case .ed2(let c):c.frameRate } }
        var channels: Int { switch self { case .e:8;case .ed2:16 } }
        func required() throws -> Int { switch self { case .e(let c):try c.requiredInputFrames();case .ed2(let c):try c.requiredInputFrames() } }
    }
    private struct Checkpoint: Codable {
        let version: Int
        let codec: Codec
        let frameIndex: UInt64
        let samplePosition: UInt64
    }
    private var codec: Codec
    private var frameIndex: UInt64 = 0
    private var samplePosition: UInt64 = 0
    private var busy = false
    private var origin: UInt64?
    private var originSample: UInt64 = 0
    private let workers: Int
    private let startupLeadFrames: Int
    private let maximumLateness: UInt64

    public init(encodeVision: DolbyEEncodeVision = .e,program: DolbyEProgram = .fiveOnePlusTwo,
                frameRate: DolbyEFrameRate = .fps25,ac3Metadata: [DolbyEAC3Metadata]? = nil,
                spectralShifts: [Int]? = nil,maximumParallelism: Int = 0,
                startupLeadFrames: Int = 3,maximumLatenessNanoseconds: Int64 = 20_000_000) throws {
        workers = try DolbyEEncoderWork.limit(maximumParallelism)
        guard (1...32).contains(startupLeadFrames),(0...1_000_000_000).contains(maximumLatenessNanoseconds) else { throw DolbyEError.invalidArgument("realtime buffering or lateness limit") }
        self.startupLeadFrames = startupLeadFrames;self.maximumLateness = UInt64(maximumLatenessNanoseconds)
        if encodeVision == .ed2 {
            codec = .ed2(try DolbyED2PCMFrameEncoder(frameRate:frameRate,ac3Metadata:ac3Metadata,
                spectralShifts:spectralShifts ?? Array(repeating:0,count:16)))
        } else {
            let values = ac3Metadata ?? program.programChannelCounts.indices.map { DolbyEAC3Metadata.defaults(program:program,index:$0) }
            codec = .e(try DolbyEPCMFrameEncoder(program:program,frameRate:frameRate,
                programs:values.map { try DolbyEProgramMetadata(ac3:$0) },spectralShifts:spectralShifts ?? Array(repeating:0,count:8)))
        }
    }

    /// Bounded DSP checkpoints may be stored in the caller's persistent job.
    /// Save only after the corresponding delivered output is durable. Monotonic
    /// clock instants are deliberately excluded and restart on restoration.
    public init(checkpoint: Data,maximumParallelism: Int = 0,startupLeadFrames: Int = 3,
                maximumLatenessNanoseconds: Int64 = 20_000_000) throws {
        guard checkpoint.count <= 16*1024*1024,(1...32).contains(startupLeadFrames),
              (0...1_000_000_000).contains(maximumLatenessNanoseconds) else { throw DolbyEError.invalidArgument("realtime checkpoint or timing limits") }
        let saved = try JSONDecoder().decode(Checkpoint.self,from:checkpoint)
        let scaled = saved.frameIndex.multipliedReportingOverflow(by:UInt64(48000*saved.codec.rate.denominator))
        guard saved.version == 1,!scaled.overflow,saved.samplePosition == scaled.partialValue/UInt64(saved.codec.rate.numerator) else { throw DolbyEError.malformed("realtime checkpoint clock") }
        codec = saved.codec;frameIndex = saved.frameIndex;samplePosition = saved.samplePosition
        originSample = saved.samplePosition;workers = try DolbyEEncoderWork.limit(maximumParallelism)
        self.startupLeadFrames = startupLeadFrames;self.maximumLateness = UInt64(maximumLatenessNanoseconds)
        _ = try saved.codec.required()
    }

    public func requiredInputFrames() throws -> Int { try codec.required() }
    public func checkpoint() throws -> Data {
        guard !busy else { throw DolbyEError.invalidArgument("realtime frame is in flight") }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Checkpoint(version:1,codec:codec,frameIndex:frameIndex,samplePosition:samplePosition))
    }
    /// Resume after a pause or a reported deadline miss without resetting DSP,
    /// frame counters, object ramps or resampler phase.
    public func resynchronizeClock() throws {
        guard !busy else { throw DolbyEError.invalidArgument("realtime frame is in flight") }
        origin = nil;originSample = samplePosition
    }
    private func interval(_ samples: UInt64) throws -> UInt64 {
        let whole = (samples / 48000).multipliedReportingOverflow(by: 1_000_000_000)
        let result = whole.partialValue.addingReportingOverflow((samples % 48000) * 1_000_000_000 / 48000)
        guard !whole.overflow, !result.overflow else { throw DolbyEError.invalidArgument("realtime clock overflow") }
        return result.partialValue
    }
    private func advanced(_ instant: UInt64, by interval: UInt64) throws -> UInt64 {
        let result = instant.addingReportingOverflow(interval)
        guard !result.overflow, result.partialValue <= UInt64(Int64.max) else { throw DolbyEError.invalidArgument("realtime clock overflow") }
        return result.partialValue
    }

    /// Duration convenience APIs retain source compatibility on newer systems;
    /// nanosecond limits and timing values are available on macOS 12 as well.
    @available(macOS 13, *)
    public init(encodeVision: DolbyEEncodeVision = .e, program: DolbyEProgram = .fiveOnePlusTwo,
                frameRate: DolbyEFrameRate = .fps25, ac3Metadata: [DolbyEAC3Metadata]? = nil,
                spectralShifts: [Int]? = nil, maximumParallelism: Int = 0,
                startupLeadFrames: Int = 3, maximumLateness: Duration) throws {
        guard maximumLateness >= .zero, maximumLateness <= .seconds(1) else { throw DolbyEError.invalidArgument("realtime lateness limit") }
        let parts = maximumLateness.components
        try self.init(encodeVision: encodeVision, program: program, frameRate: frameRate, ac3Metadata: ac3Metadata,
            spectralShifts: spectralShifts, maximumParallelism: maximumParallelism, startupLeadFrames: startupLeadFrames,
            maximumLatenessNanoseconds: parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
    }
    @available(macOS 13, *)
    public init(checkpoint: Data, maximumParallelism: Int = 0, startupLeadFrames: Int = 3,
                maximumLateness: Duration) throws {
        guard maximumLateness >= .zero, maximumLateness <= .seconds(1) else { throw DolbyEError.invalidArgument("realtime lateness limit") }
        let parts = maximumLateness.components
        try self.init(checkpoint: checkpoint, maximumParallelism: maximumParallelism, startupLeadFrames: startupLeadFrames,
            maximumLatenessNanoseconds: parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
    }

    public func encodeNext(_ pcm: [Double],scene: DolbyED2SceneMetadata? = nil,
                           preparedObjectPCM: Bool = false,programmeLoudness: DolbyEProgrammeLoudness? = nil) async throws -> DolbyERealtimeFrame {
        guard !busy else { throw DolbyEError.invalidArgument("realtime encoder accepts one frame at a time") }
        try Task.checkCancellation()
        busy = true;defer { busy = false }
        let count = try codec.required(),nextPosition = samplePosition.addingReportingOverflow(UInt64(count))
        guard pcm.count == count*codec.channels,!nextPosition.overflow,frameIndex < UInt64.max else { throw DolbyEError.invalidArgument("realtime PCM size or stream clock") }
        let began = DolbyEMonotonicTime.now
        let leadSamples = UInt64(startupLeadFrames)*UInt64(48000*codec.rate.denominator)/UInt64(codec.rate.numerator)
        let proposedOrigin = try origin ?? advanced(began, by: interval(leadSamples))
        let deadline = try advanced(proposedOrigin, by: interval(samplePosition-originSample))
        let modernDeadline: (any Sendable)?
        if #available(macOS 13, *) {
            let offset = Int64(deadline) - Int64(DolbyEMonotonicTime.now)
            modernDeadline = DolbyEModernRealtimeDeadline(value: ContinuousClock.now.advanced(by: .nanoseconds(offset)))
        } else { modernDeadline = nil }
        var candidate = codec
        let words: [UInt32]
        switch candidate {
        case .e(var encoder):
            guard scene == nil,!preparedObjectPCM,programmeLoudness == nil else { throw DolbyEError.invalidArgument("scene/programme loudness metadata requires ED2") }
            words = try encoder.encode(pcm,maximumParallelism:workers);candidate = .e(encoder)
        case .ed2(var encoder):
            guard let scene else { throw DolbyEError.invalidArgument("ED2 realtime input requires scene metadata") }
            words = try encoder.encode(pcm,scene:scene,preparedObjectPCM:preparedObjectPCM,maximumParallelism:workers,programmeLoudness:programmeLoudness);candidate = .ed2(encoder)
        }
        var primary: [UInt32] = [],expansion: [UInt32]?
        if candidate.channels == 16 {
            var second: [UInt32] = [];primary.reserveCapacity(count*2);second.reserveCapacity(count*2)
            for at in stride(from:0,to:words.count,by:4) { primary += words[at..<(at+2)];second += words[(at+2)..<(at+4)] }
            expansion = second
        } else { primary = words }
        let encodedAt = DolbyEMonotonicTime.now
        try Task.checkCancellation()
        guard encodedAt <= (try advanced(deadline, by: maximumLateness)) else { throw DolbyEError.outputUnavailable("realtime encoding missed its1X deadline; DSP is unchanged, resynchronizeClock before retry") }
        try await DolbyEMonotonicTime.sleep(until: deadline)
        try Task.checkCancellation()
        let publishedAt = DolbyEMonotonicTime.now
        let late = publishedAt > deadline ? publishedAt - deadline : 0
        guard late <= maximumLateness else { throw DolbyEError.outputUnavailable("realtime publication missed its1X deadline; DSP is unchanged, resynchronizeClock before retry") }
        let result = DolbyERealtimeFrame(frameIndex:frameIndex,samplePosition:samplePosition,sampleCount:count,
            primaryWords:primary,expansionWords:expansion,deadlineUptimeNanoseconds:deadline,encodingDurationNanoseconds:encodedAt-began,latenessNanoseconds:late,modernDeadline:modernDeadline)
        codec = candidate;origin = proposedOrigin;samplePosition = nextPosition.partialValue;frameIndex += 1
        return result
    }
}
