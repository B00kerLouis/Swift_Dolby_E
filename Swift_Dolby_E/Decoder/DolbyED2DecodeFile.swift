// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

private struct ED2DecodingCheckpoint: Codable {
    let codec: DolbyED2PCMFrameDecoder
    let renderer: DolbyED2PresentationRenderer?
    let limiter: DolbyETruePeakLimiter?
    let writer: DolbyEMediaWriter.Checkpoint
    let sceneWriter: DolbyED2SceneWriter.Checkpoint?
    let firstWord: UInt64
    let secondWord: UInt64
    let firstBoundaries: DolbyEStreamBoundaryInfo
    let secondBoundaries: DolbyEStreamBoundaryInfo
    let discardedLeadingFrames: [UInt64]
    let secondaryBookmark: Data
    let videoFrames: UInt64
    let outputSamples: UInt64
    let clippedSamples: UInt64
    let complete: Bool
}

actor DolbyED2DecodeFileWorker {
    func run(_ request: DolbyERequest, stateDirectory: URL? = nil) throws -> DolbyEFileResult {
        guard request.loudness == nil else{throw DolbyEError.invalidArgument("offline loudness correction is an encoder option")}
        guard request.decodeLayout == nil || request.decodeSelection == .main
            || request.decodeSelection == .stereo && request.decodeLayout == .stereo else {
            throw DolbyEError.invalidArgument("--layout selects an ED2 Main render; raw signals and Stereo have fixed output layouts")
        }
        let store = try DolbyEFileJobStore(operation: "decode", directory: stateDirectory)
        let signature = DolbyEFileJobStore.signature(request, operation: "decode")
        let existing = try store.resumable(output: request.outputURL, signature: signature)
        let saved = try existing.flatMap { try store.restore(ED2DecodingCheckpoint.self, from: $0) }
        let input = DolbyESecurityAccess(url: request.inputURL, bookmark: existing?.sourceBookmarkBytes ?? Data())
        let destination = DolbyESecurityAccess(url: request.outputURL.deletingLastPathComponent(), bookmark: existing?.outputBookmarkBytes ?? Data())
        var secondaryURL = request.secondaryInputURL
        if secondaryURL == nil {
            secondaryURL = DolbyED2CompanionFile.existingURL(for: input.url)
        }
        let secondary = secondaryURL.map { DolbyESecurityAccess(url: $0, bookmark: saved?.secondaryBookmark ?? Data()) }
        defer { input.stop(); secondary?.stop(); destination.stop() }
        let output = destination.url.appendingPathComponent(request.outputURL.lastPathComponent)
        let metadataURL = request.decodeSelection == .all ? destination.url.appendingPathComponent(output.lastPathComponent + ".ed2.jsonl") : nil
        let finals = [output] + (metadataURL.map { [$0] } ?? [])
        let sources = [input.url] + (secondary.map { [$0.url] } ?? [])
        guard !finals.contains(where: { target in sources.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == target.standardizedFileURL.resolvingSymlinksInPath() } }) else {
            throw DolbyEError.invalidArgument("ED2 input and export files must be distinct")
        }
        let locks = try finals.sorted { $0.path < $1.path }.map { try DolbyEOutputLock(output: $0, directory: store.directory) }
        defer { withExtendedLifetime(locks) {} }
        var job = existing
        do {
            let reader = try DolbyED2CarrierReader(url: input.url, secondaryURL: secondary?.url)
            func identity() throws -> String {
                try DolbyEFileJobStore.hash(Data(reader.sourceURLs.map { $0.standardizedFileURL.path + "|" + (try DolbyEFileJobStore.identity($0)) }.joined(separator: "\n").utf8))
            }
            let sourceIdentity = try identity()
            guard existing == nil || existing?.sourceIdentity == sourceIdentity else { throw DolbyEError.invalidArgument("ED2 substream identity changed since the durable checkpoint") }
            guard let first = try reader.readFrame() else { throw DolbyEError.malformed("source contains no complete ED2 frame pair") }
            let rate = first.frameRate
            let layout: DolbyEPlaybackLayout = request.decodeSelection == .stereo ? .stereo : request.decodeLayout ?? .fiveOneTwo
            let channels = request.decodeSelection == .all ? 16 : layout.speakers.count
            if let saved {
                guard saved.renderer?.layout == (request.decodeSelection == .all ? nil : layout),
                      saved.renderer == nil || saved.renderer?.downmixMode == request.downmixMode else {
                    throw DolbyEError.malformed("saved ED2 renderer does not match the requested speaker layout")
                }
            }
            var codec = try saved?.codec ?? DolbyED2PCMFrameDecoder(frameRate: rate)
            var renderer = saved?.renderer ?? (request.decodeSelection == .all ? nil : DolbyED2PresentationRenderer(layout: layout, downmixMode: request.downmixMode))
            var limiter = try saved?.limiter ?? (channels == 2 ? DolbyETruePeakLimiter(groups: [[0, 1]], channelCount: 2) : nil)
            try reader.seek(firstWord: saved?.firstWord ?? 0, secondWord: saved?.secondWord ?? 0,
                firstBoundaries: saved?.firstBoundaries, secondBoundaries: saved?.secondBoundaries,
                discardedLeadingFrames: saved?.discardedLeadingFrames ?? [0, 0])
            let active: DolbyEFileJobRecord
            if let existing { active = existing }
            else {
                guard finals.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else { throw DolbyEError.invalidArgument("ED2 PCM export or metadata sidecar already exists") }
                active = DolbyEFileJobRecord(signature: signature, input: request.inputURL, output: request.outputURL,
                    sourceIdentity: sourceIdentity, sourceFrames: reader.first.info.frameCount)
                active.sourceBookmarkBytes = input.bookmark; active.outputBookmarkBytes = destination.bookmark
                try store.insert(active)
            }
            job = active
            if existing == nil { try FileManager.default.createDirectory(at: destination.url, withIntermediateDirectories: true) }
            let partial = destination.url.appendingPathComponent(".\(output.lastPathComponent).\(active.id.uuidString).partial")
            let scenePartial = metadataURL.map { _ in destination.url.appendingPathComponent(".\(output.lastPathComponent).\(active.id.uuidString).scene.partial") }
            let partials = [partial] + (scenePartial.map { [$0] } ?? [])
            active.partialPath = partial.path
            var frames = saved?.videoFrames ?? 0, samples = saved?.outputSamples ?? 0, clipped = saved?.clippedSamples ?? 0
            func result(_ info: WavePCMInfo) -> DolbyEFileResult {
                DolbyEFileResult(outputURL: output, jobID: active.id.uuidString, program: .eightMono,
                    frameRate: rate, inputFrames: reader.first.info.frameCount, outputFrames: info.frameCount,
                    videoFrames: frames, resumed: saved != nil, boundaryInfo: reader.first.boundaryInfo,
                    encodeVision: .ed2, additionalOutputURLs: metadataURL.map { [$0] } ?? [], clippedSamples: clipped)
            }
            if let saved, saved.complete, finals.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let locations = zip(finals, partials).map { FileManager.default.fileExists(atPath: $0.0.path) ? $0.0 : $0.1 }
                let info = try DolbyEMediaWriter.inspect(locations[0], format: request.format)
                guard info.channelCount == channels, info.dataBytes == saved.writer.dataBytes else { throw DolbyEError.malformed("published ED2 PCM disagrees with its checkpoint") }
                if let checkpoint = saved.sceneWriter { try DolbyED2SceneWriter.validate(locations[1], checkpoint: checkpoint) }
                guard try identity() == sourceIdentity else { throw DolbyEError.invalidArgument("ED2 input changed during export finalization") }
                for (from, to) in zip(partials, finals) where !FileManager.default.fileExists(atPath: to.path) { try FileManager.default.moveItem(at: from, to: to) }
                try store.update(active, status: "completed")
                return result(info)
            }
            let writer: DolbyEMediaWriter
            let sceneWriter: DolbyED2SceneWriter?
            if let saved {
                writer = try DolbyEMediaWriter(resuming: partial, checkpoint: saved.writer, recoveringFinalization: saved.complete)
                if let checkpoint = saved.sceneWriter, let scenePartial { sceneWriter = try DolbyED2SceneWriter(resuming: scenePartial, checkpoint: checkpoint) }
                else { sceneWriter = nil }
            } else {
                for url in partials where FileManager.default.fileExists(atPath: url.path) {
                    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard bytes <= 32768 else { throw DolbyEError.malformed("uncheckpointed ED2 PCM output contains media") }
                    try FileManager.default.removeItem(at: url)
                }
                writer = try DolbyEMediaWriter(url: partial, format: request.format, rate: rate, channels: channels,
                    dolbyE: false, description: request.decodeSelection == .all ? "Dolby ED2 sixteen bed/object signals; metadata in companion JSONL"
                        : "Dolby ED2 rendered \(layout.rawValue); \(layout.speakers.map(\.rawValue).joined(separator: " "))", channelMask: channels == 2 ? 3 : 0)
                sceneWriter = try scenePartial.map { try DolbyED2SceneWriter(url: $0, frameRate: rate) }
            }
            func checkpoint(_ complete: Bool) throws {
                try store.save(ED2DecodingCheckpoint(codec: codec, renderer: renderer, limiter: limiter, writer: writer.checkpoint(),
                    sceneWriter: sceneWriter?.checkpoint(), firstWord: reader.first.wordPosition, secondWord: reader.second.wordPosition,
                    firstBoundaries: reader.first.boundaryInfo, secondBoundaries: reader.second.boundaryInfo,
                    discardedLeadingFrames: reader.discardedLeadingFrames, secondaryBookmark: secondary?.bookmark ?? Data(),
                    videoFrames: frames, outputSamples: samples, clippedSamples: clipped, complete: complete), job: active, complete: complete)
            }
            if saved == nil { try checkpoint(false) }
            if saved?.complete != true {
                while try autoreleasepool(invoking: {
                    try Task.checkCancellation()
                    guard let frame = try reader.readFrame() else { return false }
                    let decoded = try codec.decode(frame)
                    var pcm: [Double]
                    if var current = renderer {
                        pcm = try current.render(decoded.samples, scene: decoded.scene)
                        renderer = current
                    } else { pcm = decoded.samples }
                    if var current = limiter {
                        // Decode/render the bounded512-sample preview in value copies.
                        // Restoring the two logical cursors never touches the
                        // files; the next real frame sees identical DSP input.
                        let one = reader.first.wordPosition, two = reader.second.wordPosition
                        let a = reader.first.boundaryInfo, b = reader.second.boundaryInfo
                        let discarded = reader.discardedLeadingFrames
                        var preview = [Double](repeating: 0, count: DolbyETruePeakLimiter.previewFrames * 2)
                        do {
                            defer { try? reader.seek(firstWord: one, secondWord: two, firstBoundaries: a, secondBoundaries: b, discardedLeadingFrames: discarded) }
                            if let next = try reader.readFrame(), var render = renderer {
                                var temporary = codec
                                let future = try temporary.decode(next)
                                preview = try render.render(Array(future.samples.prefix(DolbyETruePeakLimiter.previewFrames * 16)), scene: future.scene)
                            }
                        }
                        try current.process(&pcm, preview: &preview)
                        limiter = current
                    }
                    clipped += UInt64(pcm.lazy.filter { $0 < -1 || $0 >= 1 }.count)
                    try writer.appendPCM(pcm)
                    try sceneWriter?.append(scene: decoded.scene, at: samples, frameNumber: frame.frameNumber)
                    samples += UInt64(pcm.count / channels); frames += 1
                    if frames % 25 == 0 { try checkpoint(false) }
                    return true
                }) {}
                try checkpoint(true)
            }
            guard try identity() == sourceIdentity else { throw DolbyEError.invalidArgument("ED2 substream changed while decoding") }
            try writer.finish(); try sceneWriter?.finish()
            try store.update(active, status: "ready")
            let info = try DolbyEMediaWriter.inspect(partial, format: request.format)
            guard info.channelCount == channels, info.dataBytes == writer.dataBytes else { throw DolbyEError.malformed("ED2 PCM final validation failed") }
            for (from, to) in zip(partials, finals) { try FileManager.default.moveItem(at: from, to: to) }
            try store.update(active, status: "completed")
            return result(info)
        } catch {
            if let job {
                let status = error is CancellationError ? "cancelled" :
                    (sources.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) || !FileManager.default.fileExists(atPath: destination.url.path) ? "waitingForStorage" : "failed")
                try? store.update(job, status: status, error: error.localizedDescription)
            }
            throw error
        }
    }
}
