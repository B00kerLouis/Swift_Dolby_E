// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct ED2EncodingCheckpoint: Codable {
    let codec: DolbyED2PCMFrameEncoder
    let router: DolbyED2SceneRouter
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

/// A system frame, all sixteen DSP channels, and every output file share one
/// durable checkpoint. OP-Atom publication can resume after either rename.
actor DolbyED2EncodeFileWorker {
    func run(_ request: DolbyERequest, stateDirectory: URL? = nil, progress: DolbyEEncodingProgressHandler? = nil) throws -> DolbyEFileResult {
        _ = try DolbyEEncoderWork.limit(request.maximumParallelism)
        try request.loudness?.validate()
        let reporter = DolbyEEncodingProgressReporter(request: request, handler: progress)
        let store = try DolbyEFileJobStore(operation: "encode", directory: stateDirectory)
        let signature = DolbyEFileJobStore.signature(request, operation: "encode")
        let candidate = try store.active(output: request.outputURL)
        let matching = candidate?.signature == signature
        let input = DolbyESecurityAccess(url: request.inputURL, bookmark: matching ? candidate?.sourceBookmarkBytes ?? Data() : Data())
        let destination = DolbyESecurityAccess(url: request.outputURL.deletingLastPathComponent(), bookmark: matching ? candidate?.outputBookmarkBytes ?? Data() : Data())
        defer { input.stop(); destination.stop() }
        let requestedOutput = destination.url.appendingPathComponent(request.outputURL.lastPathComponent)
        let paired = request.format == .mxfOPAtom || request.format == .pcm
        let output = paired ? DolbyED2CompanionFile.primaryURL(for: requestedOutput) : requestedOutput
        let companion = paired ? DolbyED2CompanionFile.url(for: output) : nil
        let legacyFinalURLs = [requestedOutput] + (paired ? [DolbyED2CompanionFile.legacyURL(for: requestedOutput)] : [])
        let finalURLs = [output] + (companion.map { [$0] } ?? [])
        guard !(finalURLs + [requestedOutput]).contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == input.url.standardizedFileURL.resolvingSymlinksInPath() }) else {
            throw DolbyEError.invalidArgument("ED2 source and output must be different files")
        }
        // Canonical locks also exclude aliases such as base.wav and base_AES1.wav.
        // Legacy locks keep older encoder processes from writing the same job.
        let lockURLs = Set((finalURLs + legacyFinalURLs).map { $0.standardizedFileURL })
        let locks = try lockURLs.sorted { $0.path < $1.path }.map { try DolbyEOutputLock(output: $0, directory: store.directory) }
        defer { withExtendedLifetime(locks) {} }
        let existing = try store.resumable(output: request.outputURL, signature: signature)
        var job = existing
        do {
            let saved = try existing.flatMap { try store.restore(ED2EncodingCheckpoint.self, from: $0) }
            let source = try DolbyEInputSource(url: input.url, program: .eightMono)
            let identity = try source.identity()
            guard existing == nil || existing?.sourceIdentity == identity else { throw DolbyEError.invalidArgument("ED2 master or sidecar identity changed") }
            let rate = request.frameRate ?? source.embeddedFrameRate ?? .fps25
            var router = saved?.router ?? DolbyED2SceneRouter(dialogueSource: request.dialogueSource, inputLayout: request.inputLayout)
            var limiter = try saved?.limiter ?? DolbyETruePeakLimiter(groups: [Array(0..<16)], channelCount: 16)
            guard limiter.channelCount == 16, limiter.groups == [Array(0..<16)] else { throw DolbyEError.malformed("ED2 limiter checkpoint has a different signal graph") }
            var codec = try saved?.codec ?? DolbyED2PCMFrameEncoder(frameRate: rate, ac3Metadata: request.ac3Metadata)
            // Validate actual scene admission before creating any output.
            if saved == nil { _ = try source.peekED2(maxFrames: 256, router: router) }
            if let saved { try source.seek(toFrame: saved.sourcePosition) }
            let active: DolbyEFileJobRecord
            if let existing { active = existing }
            else {
                guard finalURLs.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else { throw DolbyEError.invalidArgument("an ED2 output or companion file already exists") }
                active = DolbyEFileJobRecord(signature: signature, input: request.inputURL, output: request.outputURL,
                    sourceIdentity: identity, sourceFrames: source.info.frameCount)
                active.sourceBookmarkBytes = input.bookmark; active.outputBookmarkBytes = destination.bookmark
                try store.insert(active)
            }
            job = active
            if existing == nil { try FileManager.default.createDirectory(at: destination.url, withIntermediateDirectories: true) }
            // The requested base remains the durable job identity. Restore the
            // stored temporary names when resuming a job created by an older build.
            let partial = destination.url.appendingPathComponent(URL(fileURLWithPath: active.partialPath).lastPathComponent)
            let savedPartnerName: String?
            switch saved?.writer {
            case .some(.ed2Atoms(let checkpoint)): savedPartnerName = checkpoint.companionFileName
            case .some(.ed2Waves(let checkpoint)): savedPartnerName = checkpoint.companionFileName
            default: savedPartnerName = nil
            }
            if let name = savedPartnerName {
                guard !name.isEmpty, name != ".", name != "..", URL(fileURLWithPath: name).lastPathComponent == name else {
                    throw DolbyEError.malformed("ED2 companion checkpoint filename")
                }
            }
            let partnerPartial = companion.map { _ in
                destination.url.appendingPathComponent(savedPartnerName ?? ".\(requestedOutput.lastPathComponent).\(active.id.uuidString)_AES2.partial")
            }
            let partialURLs = [partial] + (partnerPartial.map { [$0] } ?? [])
            let usesLegacyPublication = savedPartnerName == ".\(requestedOutput.lastPathComponent).\(active.id.uuidString).AES2.partial"
            let recoverableFinalURLs = usesLegacyPublication ? legacyFinalURLs : finalURLs
            active.partialPath = partial.path
            let loudnessPlan=try DolbyEOfflineLoudnessPreparation.run(request,sourceURL:input.url,outputURL:requestedOutput,directory:store.directory,progress:reporter)
            if saved==nil,let shifts=loudnessPlan?.spectralShifts {codec=try .init(frameRate:rate,ac3Metadata:request.ac3Metadata,spectralShifts:shifts)}
            var programmeProcessor=try saved?.loudnessProcessor ?? (loudnessPlan?.settings.mode == .normalize ? loudnessPlan?.processor(request:request):nil)
            var frames = saved?.videoFrames ?? 0, tail = saved?.tailFrames ?? 1
            var profiling = saved?.profiling ?? (loudnessPlan?.spectralShifts == nil)
            var spectralPeaks = saved?.spectralPeaks ?? Array(repeating: 0, count: 16)
            guard spectralPeaks.count == 16, spectralPeaks.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  !(saved?.complete == true && profiling) else { throw DolbyEError.malformed("invalid ED2 profiling checkpoint") }

            func inspect(_ a: URL, _ b: URL?) throws -> WavePCMInfo {
                try DolbyEMediaWriter.inspectED2(a, companionURL: b, format: request.format)
            }
            func result(_ info: WavePCMInfo) -> DolbyEFileResult {
                var value=DolbyEFileResult(outputURL: output, jobID: active.id.uuidString, program: .eightMono,
                    frameRate: rate, inputFrames: source.info.frameCount, outputFrames: info.frameCount,
                    videoFrames: frames, resumed: saved != nil, encodeVision: .ed2,
                    additionalOutputURLs: companion.map { [$0] } ?? [])
                value.loudness=loudnessPlan?.reports;return value
            }
            if let saved, saved.complete,
               (finalURLs + recoverableFinalURLs).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                reporter.emit(.finalizing, processed: source.info.frameCount, total: source.info.frameCount)
                // Validate both members before finishing publication. A partially
                // published legacy job can move its validated members to canonical names.
                let locations = finalURLs.indices.map { index -> URL in
                    if FileManager.default.fileExists(atPath: finalURLs[index].path) { return finalURLs[index] }
                    if FileManager.default.fileExists(atPath: recoverableFinalURLs[index].path) { return recoverableFinalURLs[index] }
                    return partialURLs[index]
                }
                let info = try inspect(locations[0], locations.count == 2 ? locations[1] : nil)
                guard info.dataBytes == saved.writer.dataBytes else { throw DolbyEError.malformed("published ED2 output disagrees with its durable checkpoint") }
                guard try source.identity() == identity else { throw DolbyEError.invalidArgument("ED2 master changed during finalization") }
                for (from, to) in zip(locations, finalURLs) where from.standardizedFileURL != to.standardizedFileURL {
                    try FileManager.default.moveItem(at: from, to: to)
                }
                try store.update(active, status: "completed")
                reporter.emit(.completed, processed: source.info.frameCount, total: source.info.frameCount)
                return result(info)
            }
            let writer: DolbyEMediaWriter
            if let saved {
                writer = try DolbyEMediaWriter(resuming: partial, checkpoint: saved.writer,
                    recoveringFinalization: saved.complete, companionURL: partnerPartial)
            } else {
                for url in partialURLs where FileManager.default.fileExists(atPath: url.path) {
                    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard bytes <= 32768 else { throw DolbyEError.malformed("uncheckpointed ED2 partial contains media") }
                    try FileManager.default.removeItem(at: url)
                }
                writer = try DolbyEMediaWriter(url: partial, format: request.format, rate: rate, channels: 4,
                    dolbyE: true, description: "Dolby ED2 5.1.2 bed + objects, \(rate.rawValue) fps", companionURL: partnerPartial)
                try store.save(ED2EncodingCheckpoint(codec: codec, router: router, limiter: limiter, writer: writer.checkpoint(),
                    sourcePosition: source.position, videoFrames: frames, tailFrames: tail, complete: false,
                    profiling: profiling, spectralPeaks: spectralPeaks,loudnessProcessor:programmeProcessor), job: active, complete: false, phase: "profiling")
            }
            func checkpoint(complete: Bool) throws {
                try store.save(ED2EncodingCheckpoint(codec: codec, router: router, limiter: limiter, writer: writer.checkpoint(),
                    sourcePosition: source.position, videoFrames: frames, tailFrames: tail, complete: complete,
                    profiling: profiling, spectralPeaks: spectralPeaks,loudnessProcessor:programmeProcessor), job: active, complete: complete, phase: profiling ? "profiling" : "processing")
            }
            if profiling {
                reporter.emit(.profiling, processed: source.position, total: source.info.frameCount)
                // Scan the actual routed/limited source through the same DSP.
                // Only bounded history and sixteen maxima are retained. This
                // phase can resume after storage loss; no PCM is staged.
                while source.position < source.info.frameCount || tail > 0 {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let count = try codec.requiredInputFrames()
                        if source.position >= source.info.frameCount { tail -= 1 }
                        var routed = try source.readED2(maxFrames: count, router: &router)
                        var preview = try source.peekED2(maxFrames: DolbyETruePeakLimiter.previewFrames, router: router)
                        try limiter.process(&routed.samples, preview: &preview.samples)
                        if var processor=programmeProcessor {_ = try processor.immersive(&routed.samples,scene:routed.metadata,preview:&preview.samples,previewScene:preview.metadata,maximumParallelism:request.maximumParallelism);programmeProcessor=processor}
                        spectralPeaks = zip(spectralPeaks, try codec.measureSpectralPeaks(routed.samples,maximumParallelism:request.maximumParallelism)).map(max)
                        frames += 1
                        reporter.emit(.profiling, processed: source.position, total: source.info.frameCount)
                        if frames % 25 == 0 { try checkpoint(complete: false) }
                    }
                }
                guard try source.identity() == identity else { throw DolbyEError.invalidArgument("ED2 master changed during spectral profiling") }
                let shifts = try DolbyEPCMFrameEncoder.normalizationShifts(peaks: spectralPeaks)
                codec = try DolbyED2PCMFrameEncoder(frameRate: rate, ac3Metadata: request.ac3Metadata, spectralShifts: shifts)
                router = DolbyED2SceneRouter(dialogueSource: request.dialogueSource, inputLayout: request.inputLayout)
                limiter = try DolbyETruePeakLimiter(groups: [Array(0..<16)], channelCount: 16)
                try source.seek(toFrame: 0)
                programmeProcessor=try loudnessPlan?.settings.mode == .normalize ? loudnessPlan?.processor(request:request):nil
                frames = 0; tail = 1; profiling = false
                try checkpoint(complete: false)
            }
            reporter.emit(.encoding, processed: source.position, total: source.info.frameCount)
            if saved?.complete != true {
                while source.position < source.info.frameCount || tail > 0 {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let count = try codec.requiredInputFrames()
                        if source.position >= source.info.frameCount { tail -= 1 }
                        var routed = try source.readED2(maxFrames: count, router: &router)
                        var preview = try source.peekED2(maxFrames: DolbyETruePeakLimiter.previewFrames, router: router)
                        try limiter.process(&routed.samples, preview: &preview.samples)
                        if var processor=programmeProcessor {_ = try processor.immersive(&routed.samples,scene:routed.metadata,preview:&preview.samples,previewScene:preview.metadata,maximumParallelism:request.maximumParallelism);programmeProcessor=processor}
                        try writer.appendCarrier(codec.encode(routed.samples, scene: routed.metadata, preparedObjectPCM: true,maximumParallelism:request.maximumParallelism,programmeLoudness:loudnessPlan?.programmePayload()))
                        frames += 1
                        reporter.emit(.encoding, processed: source.position, total: source.info.frameCount)
                        if frames % 25 == 0 {
                            try checkpoint(complete: false)
                        }
                    }
                }
                try checkpoint(complete: true)
            }
            guard try source.identity() == identity else { throw DolbyEError.invalidArgument("ED2 master or sidecars changed while processing") }
            reporter.emit(.finalizing, processed: source.info.frameCount, total: source.info.frameCount)
            try writer.finish()
            try store.update(active, status: "ready")
            let info = try inspect(partial, partnerPartial)
            guard info.dataBytes == writer.dataBytes, info.channelCount == 4, info.sampleRate == 48000 else { throw DolbyEError.malformed("finalized ED2 output validation failed") }
            for (from, to) in zip(partialURLs, finalURLs) { try FileManager.default.moveItem(at: from, to: to) }
            try store.update(active, status: "completed")
            reporter.emit(.completed, processed: source.info.frameCount, total: source.info.frameCount)
            return result(info)
        } catch {
            if let job {
                let status = error is CancellationError ? "cancelled" :
                    (!FileManager.default.fileExists(atPath: input.url.path) || !FileManager.default.fileExists(atPath: destination.url.path) ? "waitingForStorage" : "failed")
                try? store.update(job, status: status, error: error.localizedDescription)
            }
            throw error
        }
    }
}
