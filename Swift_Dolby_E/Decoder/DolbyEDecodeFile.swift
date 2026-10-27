// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

private struct DecodingCheckpoint: Codable {
    let codec: DolbyEPCMFrameDecoder
    let writer: DolbyEMediaWriter.Checkpoint
    let sourceWord: UInt64
    let videoFrames: UInt64
    let complete: Bool
    var boundaries: DolbyEStreamBoundaryInfo? = nil
}

actor DolbyEDecodeFileWorker {
    func run(_ request: DolbyERequest, stateDirectory: URL? = nil) async throws -> DolbyEFileResult {
        guard request.loudness == nil else{throw DolbyEError.invalidArgument("offline loudness correction is an encoder option; use DolbyELoudnessAnalyzer for decoded PCM")}
        let store = try DolbyEFileJobStore(operation: "decode", directory: stateDirectory)
        let signature = DolbyEFileJobStore.signature(request, operation: "decode")
        let candidate = try store.active(output: request.outputURL)
        let matching = candidate?.signature == signature
        let inputAccess = DolbyESecurityAccess(url: request.inputURL, bookmark: matching ? candidate?.sourceBookmarkBytes ?? Data() : Data())
        let outputAccess = DolbyESecurityAccess(url: request.outputURL.deletingLastPathComponent(), bookmark: matching ? candidate?.outputBookmarkBytes ?? Data() : Data())
        defer { inputAccess.stop(); outputAccess.stop() }
        // Detect the system topology after resolving durable source access and
        // before decoding a checkpoint into the generation-specific state.
        let inspection = try DolbyEWaveCarrierReader(url: inputAccess.url)
        if inspection.info.channelCount == 4 || request.secondaryInputURL != nil {
            return try await DolbyED2DecodeFileWorker().run(request, stateDirectory: stateDirectory)
        }
        if let first = try inspection.readFrame(), first.program == .eightMono, !first.evolutionWords.isEmpty {
            return try await DolbyED2DecodeFileWorker().run(request, stateDirectory: stateDirectory)
        }
        guard request.decodeLayout == nil else { throw DolbyEError.invalidArgument("file --layout requires ED2; Dolby E file exports retain their native program channels") }
        let outputURL = outputAccess.url.appendingPathComponent(request.outputURL.lastPathComponent)
        guard inputAccess.url.standardizedFileURL.resolvingSymlinksInPath() != outputURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw DolbyEError.invalidArgument("source and output must be different files")
        }
        let outputLock = try DolbyEOutputLock(output: outputURL, directory: store.directory)
        defer { withExtendedLifetime(outputLock) {} }
        let existing = try store.resumable(output: request.outputURL, signature: signature)
        var job = existing
        do {
            let saved = try existing.flatMap { try store.restore(DecodingCheckpoint.self, from: $0) }
            let source = try DolbyEWaveCarrierReader(url: inputAccess.url)
            let identity = try DolbyEFileJobStore.identity(inputAccess.url)
            guard existing == nil || existing?.sourceIdentity == identity else {
                throw DolbyEError.invalidArgument("source identity changed; the saved decoder cannot be resumed against it")
            }
            guard let first = try source.readFrame() else { throw DolbyEError.malformed("source contains no complete Dolby E frames") }
            guard first.program == request.program else {
                throw DolbyEError.invalidArgument("source program is \(first.program.rawValue); select that --program value")
            }
            let outputChannels: Int
            switch request.decodeSelection {
            case .all: outputChannels = 8
            case .main: outputChannels = first.program.programChannelCounts[0]
            case .stereo:
                guard first.program == .fiveOnePlusTwo else { throw DolbyEError.invalidArgument("the stream has no independent Stereo program") }
                outputChannels = 2
            }
            try source.seek(toWord: saved?.sourceWord ?? 0, restoring: saved?.boundaries)
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
            var codec = try saved?.codec ?? DolbyEPCMFrameDecoder(program: first.program, frameRate: first.frameRate)
            var frames = saved?.videoFrames ?? 0
            if let saved, saved.complete, FileManager.default.fileExists(atPath: outputURL.path),
               !FileManager.default.fileExists(atPath: partial.path) {
                let info = try DolbyEMediaWriter.inspect(outputURL, format: request.format)
                guard info.dataBytes == saved.writer.dataBytes, info.channelCount == outputChannels else {
                    throw DolbyEError.malformed("finalized decoded output no longer matches the job")
                }
                try store.update(active, status: "completed")
                return DolbyEFileResult(outputURL: outputURL, jobID: active.id.uuidString, program: first.program,
                    frameRate: first.frameRate, inputFrames: source.info.frameCount, outputFrames: info.frameCount,
                    videoFrames: frames, resumed: true, boundaryInfo: source.boundaryInfo)
            }
            let writer: DolbyEMediaWriter
            if let saved {
                writer = try DolbyEMediaWriter(resuming: partial, checkpoint: saved.writer, recoveringFinalization: saved.complete)
            } else {
                if FileManager.default.fileExists(atPath: partial.path) {
                    let size = (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size <= 32768 else { throw DolbyEError.malformed("uncheckpointed partial output is larger than a header") }
                    try FileManager.default.removeItem(at: partial)
                }
                writer = try DolbyEMediaWriter(url: partial, format: request.format, rate: first.frameRate, channels: outputChannels, dolbyE: false,
                    description: "Dolby E decoded \(first.program.rawValue), \(first.frameRate.rawValue) fps",
                    channelMask: outputChannels == 2 ? 3 : (outputChannels == 6 ? 0x60f : (first.program == .sevenOneScreen ? 0xff : 0)))
                try store.save(DecodingCheckpoint(codec: codec, writer: writer.checkpoint(), sourceWord: source.wordPosition,
                    videoFrames: frames, complete: false, boundaries: source.boundaryInfo), job: active, complete: false)
            }
            if saved?.complete != true {
                while try autoreleasepool(invoking: {
                    guard let frame = try source.readFrame() else { return false }
                    try Task.checkCancellation()
                    let pcm = try codec.decode(frame)
                    let selected = request.decodeSelection == .all ? pcm : try DolbyEPlaybackRouting.selectProgram(pcm,
                        configuration: first.program, index: request.decodeSelection == .main ? 0 : 1).samples
                    try writer.appendPCM(selected)
                    frames += 1
                    if frames % 25 == 0 {
                        try store.save(DecodingCheckpoint(codec: codec, writer: writer.checkpoint(), sourceWord: source.wordPosition,
                            videoFrames: frames, complete: false, boundaries: source.boundaryInfo), job: active, complete: false)
                    }
                    return true
                }) {}
                try store.save(DecodingCheckpoint(codec: codec, writer: writer.checkpoint(), sourceWord: source.wordPosition,
                    videoFrames: frames, complete: true, boundaries: source.boundaryInfo), job: active, complete: true)
            }
            try writer.finish()
            try store.update(active, status: "ready")
            let verified = try DolbyEMediaWriter.inspect(partial, format: request.format)
            guard verified.dataBytes == writer.dataBytes, verified.sampleRate == 48000, verified.channelCount == outputChannels else {
                throw DolbyEError.malformed("decoded output validation failed")
            }
            try FileManager.default.moveItem(at: partial, to: outputURL)
            try store.update(active, status: "completed")
            return DolbyEFileResult(outputURL: outputURL, jobID: active.id.uuidString, program: first.program,
                frameRate: first.frameRate, inputFrames: source.info.frameCount, outputFrames: verified.frameCount,
                videoFrames: frames, resumed: saved != nil, boundaryInfo: source.boundaryInfo)
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

extension DolbyEDecoding {
    public static func decode(_ request: DolbyERequest) async throws -> DolbyEFileResult {
        try await DolbyEDecodeFileWorker().run(request)
    }
}
