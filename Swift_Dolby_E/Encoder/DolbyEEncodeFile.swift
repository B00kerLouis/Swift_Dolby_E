// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct EncodingCheckpoint: Codable {
    let codec: DolbyEPCMFrameEncoder
    let router: DolbyEEncodingRouter
    let limiter: DolbyETruePeakLimiter
    let writer: DolbyEMediaWriter.Checkpoint
    let sourcePosition: UInt64
    let videoFrames: UInt64
    let tailFrames: Int
    let complete: Bool
    let profiling: Bool
    let spectralPeaks: [Double]
    var loudnessProcessor: DolbyELoudnessProcessor? = nil
}

actor DolbyEEncodeFileWorker {
    func run(_ request: DolbyERequest, stateDirectory: URL? = nil) async throws -> DolbyEFileResult {
        _ = try DolbyEEncoderWork.limit(request.maximumParallelism)
        try request.loudness?.validate()
        if request.encodeVision == .ed2 { return try await DolbyED2EncodeFileWorker().run(request, stateDirectory: stateDirectory) }
        let store = try DolbyEFileJobStore(operation: "encode", directory: stateDirectory)
        let signature = DolbyEFileJobStore.signature(request, operation: "encode")
        let candidate = try store.active(output: request.outputURL)
        let matching = candidate?.signature == signature
        let inputAccess = DolbyESecurityAccess(url: request.inputURL, bookmark: matching ? candidate?.sourceBookmarkBytes ?? Data() : Data())
        let outputAccess = DolbyESecurityAccess(url: request.outputURL.deletingLastPathComponent(), bookmark: matching ? candidate?.outputBookmarkBytes ?? Data() : Data())
        defer { inputAccess.stop(); outputAccess.stop() }
        let outputURL = outputAccess.url.appendingPathComponent(request.outputURL.lastPathComponent)
        guard inputAccess.url.standardizedFileURL.resolvingSymlinksInPath() != outputURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw DolbyEError.invalidArgument("source and output must be different files")
        }
        let outputLock = try DolbyEOutputLock(output: outputURL, directory: store.directory)
        defer { withExtendedLifetime(outputLock) {} }
        let existing = try store.resumable(output: request.outputURL, signature: signature)
        var job = existing
        do {
            let saved = try existing.flatMap { try store.restore(EncodingCheckpoint.self, from: $0) }
            let source = try DolbyEInputSource(url: inputAccess.url, program: request.program)
            let identity = try source.identity()
            let rate = request.frameRate ?? source.embeddedFrameRate ?? .fps25
            guard existing == nil || existing?.sourceIdentity == identity else {
                throw DolbyEError.invalidArgument("source identity changed; the saved codec state cannot be resumed against it")
            }
            let active: DolbyEFileJob
            if let existing { active = existing }
            else {
                guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw DolbyEError.invalidArgument("output already exists")
                }
                active = DolbyEFileJob(signature: signature, input: request.inputURL, output: request.outputURL,
                    sourceIdentity: identity, sourceFrames: source.info.frameCount)
                active.sourceBookmarkBytes = inputAccess.bookmark
                active.outputBookmarkBytes = outputAccess.bookmark
                try store.insert(active)
            }
            job = active
            let partial = outputAccess.url.appendingPathComponent(".\(request.outputURL.lastPathComponent).\(active.id.uuidString).partial")
            active.partialPath = partial.path
            if existing != nil {
                guard FileManager.default.fileExists(atPath: outputAccess.url.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
            } else {
                try FileManager.default.createDirectory(at: outputAccess.url, withIntermediateDirectories: true)
            }
            let loudnessPlan=try DolbyEOfflineLoudnessPreparation.run(request,sourceURL:inputAccess.url,outputURL:outputURL,directory:store.directory)
            let effectiveRequest=try loudnessPlan?.ordinaryRequest(request) ?? request
            var programmeProcessor=try saved?.loudnessProcessor ?? (loudnessPlan?.settings.mode == .normalize ? loudnessPlan?.processor(request:request):nil)
            var router = try saved?.router ?? DolbyEEncodingRouter(source: source, request: request)
            var limiter = try saved?.limiter ?? DolbyETruePeakLimiter(groups: router.limitingGroups)
            guard limiter.groups == router.limitingGroups else { throw DolbyEError.malformed("saved limiter program groups changed") }
            let metadata = try DolbyEEncoding.programMetadata(effectiveRequest, stereoMode: router.stereoMode)
            var codec = try saved?.codec ?? DolbyEPCMFrameEncoder(program: request.program, frameRate: rate,
                programs: metadata,spectralShifts:loudnessPlan?.spectralShifts ?? Array(repeating:0,count:8))
            var frames = saved?.videoFrames ?? 0
            var tail = saved?.tailFrames ?? 1
            var profiling = saved?.profiling ?? (loudnessPlan?.spectralShifts == nil)
            var spectralPeaks = saved?.spectralPeaks ?? Array(repeating: 0, count: 8)
            guard spectralPeaks.count == 8, spectralPeaks.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  !(saved?.complete == true && profiling) else { throw DolbyEError.malformed("invalid spectral profiling checkpoint") }
            if let saved { try source.seek(toFrame: saved.sourcePosition) }
            if let saved, saved.complete, FileManager.default.fileExists(atPath: outputURL.path),
               !FileManager.default.fileExists(atPath: partial.path) {
                let info = try DolbyEMediaWriter.inspect(outputURL, format: request.format)
                guard info.dataBytes == saved.writer.dataBytes, info.channelCount == 2 else {
                    throw DolbyEError.malformed("finalized output no longer matches the saved job")
                }
                try store.update(active, status: "completed")
                var result=DolbyEFileResult(outputURL: outputURL, jobID: active.id.uuidString, program: request.program,
                    frameRate: rate, inputFrames: source.info.frameCount, outputFrames: info.frameCount,
                    videoFrames: frames, resumed: true)
                result.loudness=loudnessPlan?.reports;return result
            }
            let writer: DolbyEMediaWriter
            if let saved {
                writer = try DolbyEMediaWriter(resuming: partial, checkpoint: saved.writer, recoveringFinalization: saved.complete)
            } else {
                if FileManager.default.fileExists(atPath: partial.path) {
                    let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size <= 32768 else { throw DolbyEError.malformed("uncheckpointed partial output is larger than an output header") }
                    try FileManager.default.removeItem(at: partial)
                }
                writer = try DolbyEMediaWriter(url: partial, format: request.format, rate: rate, channels: 2, dolbyE: true,
                    description: "Dolby E \(request.program.rawValue), \(rate.rawValue) fps")
                try store.save(EncodingCheckpoint(codec: codec, router: router, limiter: limiter, writer: writer.checkpoint(),
                    sourcePosition: source.position, videoFrames: frames, tailFrames: tail, complete: false,
                    profiling: profiling, spectralPeaks: spectralPeaks,loudnessProcessor:programmeProcessor), job: active, complete: false, phase: "profiling")
            }
            func checkpoint(complete: Bool) throws {
                try store.save(EncodingCheckpoint(codec: codec, router: router, limiter: limiter, writer: writer.checkpoint(),
                    sourcePosition: source.position, videoFrames: frames, tailFrames: tail, complete: complete,
                    profiling: profiling, spectralPeaks: spectralPeaks,loudnessProcessor:programmeProcessor), job: active, complete: complete, phase: profiling ? "profiling" : "processing")
            }
            if profiling {
                while source.position < source.info.frameCount || tail > 0 {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let count = try codec.requiredInputFrames()
                        if source.position >= source.info.frameCount { tail -= 1 }
                        var routed = try source.readRouted(maxFrames: count, router: &router)
                        if !limiter.groups.isEmpty || programmeProcessor != nil {
                            var preview = try source.peekRouted(maxFrames: DolbyETruePeakLimiter.previewFrames, router: router)
                            if !limiter.groups.isEmpty {try limiter.process(&routed, preview: &preview)}
                            if var processor=programmeProcessor {_ = try processor.ordinary(&routed,preview:&preview,collect:false);programmeProcessor=processor}
                        }
                        spectralPeaks = zip(spectralPeaks, try codec.measureSpectralPeaks(routed,maximumParallelism:request.maximumParallelism)).map(max)
                        frames += 1
                        if frames % 25 == 0 { try checkpoint(complete: false) }
                    }
                }
                guard try source.identity() == identity else { throw DolbyEError.invalidArgument("source changed during spectral profiling") }
                codec = try DolbyEPCMFrameEncoder(program: request.program, frameRate: rate, programs: metadata,
                    spectralShifts: DolbyEPCMFrameEncoder.normalizationShifts(peaks: spectralPeaks))
                router = try DolbyEEncodingRouter(source: source, request: request)
                limiter = try DolbyETruePeakLimiter(groups: router.limitingGroups)
                try source.seek(toFrame: 0)
                programmeProcessor=try loudnessPlan?.settings.mode == .normalize ? loudnessPlan?.processor(request:request):nil
                frames = 0; tail = 1; profiling = false
                try checkpoint(complete: false)
            }
            if saved?.complete != true {
                while source.position < source.info.frameCount || tail > 0 {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let count = try codec.requiredInputFrames()
                        let hadSource = source.position < source.info.frameCount
                        if !hadSource { tail -= 1 }
                        var routed = try source.readRouted(maxFrames: count, router: &router)
                        if !limiter.groups.isEmpty || programmeProcessor != nil {
                            var preview = try source.peekRouted(maxFrames: DolbyETruePeakLimiter.previewFrames, router: router)
                            if !limiter.groups.isEmpty {try limiter.process(&routed, preview: &preview)}
                            if var processor=programmeProcessor {_ = try processor.ordinary(&routed,preview:&preview,collect:false);programmeProcessor=processor}
                        }
                        let carrier = try codec.encode(routed,maximumParallelism:request.maximumParallelism)
                        try writer.appendCarrier(carrier)
                        frames += 1
                        if frames % 25 == 0 {
                            try checkpoint(complete: false)
                        }
                    }
                }
                try checkpoint(complete: true)
            }
            guard try source.identity() == identity else { throw DolbyEError.invalidArgument("source or Atmos sidecar changed during encoding") }
            try writer.finish()
            try store.update(active, status: "ready")
            let verified = try DolbyEMediaWriter.inspect(partial, format: request.format)
            guard verified.dataBytes == writer.dataBytes, verified.sampleRate == 48000, verified.channelCount == 2 else {
                throw DolbyEError.malformed("final output validation failed")
            }
            try FileManager.default.moveItem(at: partial, to: outputURL)
            try store.update(active, status: "completed")
            var result=DolbyEFileResult(outputURL: outputURL, jobID: active.id.uuidString, program: request.program,
                frameRate: rate, inputFrames: source.info.frameCount, outputFrames: verified.frameCount,
                videoFrames: frames, resumed: saved != nil)
            result.loudness=loudnessPlan?.reports;return result
        } catch {
            if let job {
                let status = error is CancellationError ? "cancelled"
                    : (!FileManager.default.fileExists(atPath: inputAccess.url.path) || !FileManager.default.fileExists(atPath: outputAccess.url.path) ? "waitingForStorage" : "failed")
                try? store.update(job, status: status, error: error.localizedDescription)
            }
            throw error
        }
    }
}

extension DolbyEEncoding {
    /// Runs the file pipeline off the caller's actor and retains durable processing state.
    public static func encode(_ request: DolbyERequest) async throws -> DolbyEFileResult {
        try await DolbyEEncodeFileWorker().run(request)
    }
}
