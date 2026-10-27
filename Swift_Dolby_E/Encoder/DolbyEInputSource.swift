// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// One processing job owns every file handle. Sidecar identities participate in
/// recovery verification just like the primary master descriptor.
final class DolbyEInputSource {
    let info: WavePCMInfo
    let scene: DolbyEAtmosScene?
    let dependencies: [URL]
    private let wave: WavePCMReader?
    private let caf: DolbyECAFReader?
    private let iab: DolbyEIABReader?
    let embeddedFrameRate: DolbyEFrameRate?
    var isIAB: Bool { iab != nil }
    var position: UInt64 { wave?.position ?? caf?.position ?? iab!.position }

    init(url: URL, program: DolbyEProgram = .fiveOnePlusTwo) throws {
        if ["mxf", "imf", "iab"].contains(url.pathExtension.lowercased()) {
            let source = try DolbyEIABReader(url: url, program: program)
            self.iab = source; self.info = source.info; self.scene = nil; self.wave = nil; self.caf = nil
            self.dependencies = [url]; self.embeddedFrameRate = source.embeddedFrameRate
        } else if url.pathExtension.lowercased() == "atmos" {
            let descriptor = try DolbyEAtmosMetadata.descriptor(DolbyEAtmosMetadata.text(url))
            let audioURL = try DolbyEMasterProbe.resolveDAMFMember(descriptor: url, name: descriptor.audio, kind: "audio")
            let metadataURL = try DolbyEMasterProbe.resolveDAMFMember(descriptor: url, name: descriptor.metadata, kind: "metadata")
            let source = try DolbyECAFReader(url: audioURL)
            self.scene = try DolbyEAtmosMetadata.damf(DolbyEAtmosMetadata.text(metadataURL), beds: descriptor.beds,
                objects: descriptor.objects, channels: source.info.channelCount, channelOrder: descriptor.channelOrder)
            self.info = source.info; self.caf = source; self.wave = nil; self.iab = nil
            let descriptorText = try DolbyEAtmosMetadata.text(url)
            let fps = descriptorText.split(whereSeparator: \.isNewline).compactMap { DolbyEAtmosMetadata.scalar(String($0)) }.first { $0.0 == "fps" }?.1
            self.embeddedFrameRate = try fps.map { try DolbyEFrameRate(argument: $0) }
            self.dependencies = [url, audioURL, metadataURL]
        } else {
            let source = try WavePCMReader(url: url)
            self.info = source.info; self.wave = source; self.caf = nil; self.iab = nil; self.dependencies = [url]; self.embeddedFrameRate = nil
            if let xml = try source.metadataStream("axml"), source.info.hasADM {
                self.scene = try DolbyEAtmosMetadata.adm(stream: xml, chna: source.metadataChunk("chna"), channels: source.info.channelCount)
            } else { self.scene = nil }
        }
        guard info.sampleRate == 48000, info.frameCount > 0 else { throw DolbyEError.unsupported("master audio must be nonempty 48 kHz PCM") }
    }
    func readRouted(maxFrames: Int, router: inout DolbyEEncodingRouter) throws -> [Double] {
        if let iab {
            guard case .atmosphere(var renderer) = router else { throw DolbyEError.malformed("IAB renderer state changed") }
            let result = try iab.render(frames: maxFrames, renderer: &renderer)
            router = .atmosphere(renderer); return result
        }
        let start = position
        var samples = try wave?.read(maxFrames: maxFrames) ?? caf!.read(maxFrames: maxFrames)
        samples += repeatElement(Float(0), count: maxFrames * info.channelCount - samples.count)
        return try router.route(samples, source: self, at: start)
    }
    func peekRouted(maxFrames: Int, router: DolbyEEncodingRouter) throws -> [Double] {
        let sample = position, saved = iab?.captureCursor()
        defer {
            if let saved { iab?.restoreCursor(saved) }
            else { try? seek(toFrame: sample) }
        }
        var preview = router
        return try readRouted(maxFrames: maxFrames, router: &preview)
    }
    /// ED2 imports preserve raw bed/object sources until spatial aggregation.
    /// In particular, an IAB source never traverses the ordinary eight-channel
    /// E delivery renderer before reaching this path.
    func readED2(maxFrames: Int, router: inout DolbyED2SceneRouter) throws -> DolbyED2RoutedFrame {
        guard (1...2048).contains(maxFrames) else { throw DolbyEError.invalidArgument("ED2 source reads require one bounded video frame") }
        if let iab { return try iab.renderED2(frames: maxFrames, router: &router) }
        let start = position
        var pcm = try wave?.read(maxFrames: maxFrames) ?? caf!.read(maxFrames: maxFrames)
        pcm += repeatElement(Float(0), count: maxFrames * info.channelCount - pcm.count)
        let inputs: [DolbyED2SpatialInput]
        if let scene {
            let mapped = Set(scene.tracks.map(\.channel)).union(scene.ignoredChannels)
            for channel in 0..<info.channelCount where !mapped.contains(channel) {
                for frame in 0..<maxFrames where pcm[frame * info.channelCount + channel] != 0 {
                    throw DolbyEError.malformed("active Atmos channel \(channel + 1) has no ED2 bed/object assignment")
                }
            }
            inputs = scene.tracks.enumerated().map { index, track in
                DolbyED2SpatialInput(id: "A\(index).\(track.channel)", bed: track.bed,
                    samples: stride(from: track.channel, to: pcm.count, by: info.channelCount).map { pcm[$0] },
                    valueAt: { offset in track.value(at: start + UInt64(offset)) })
            }
        } else {
            let labels: [DolbyEAtmosBed]
            if info.channelCount == 6, [.automatic, .fiveOne].contains(router.inputLayout) {
                labels = [.left, .right, .center, .lfe, .leftSide, .rightSide]
            } else if info.channelCount == 8, router.inputLayout == .fiveOneTwo {
                labels = [.left, .right, .center, .lfe, .leftSide, .rightSide, .leftTop, .rightTop]
            } else {
                throw DolbyEError.invalidArgument("ED2 plain PCM requires six-channel 5.1 or explicit --input-layout 5.1.2 for eight channels")
            }
            inputs = labels.enumerated().map { channel, label in
                DolbyED2SpatialInput(id: "P\(channel)", bed: label,
                    samples: stride(from: channel, to: pcm.count, by: info.channelCount).map { pcm[$0] },
                    valueAt: { _ in DolbyEAtmosValue() })
            }
        }
        return try router.route(inputs, frames: maxFrames)
    }

    func peekED2(maxFrames: Int, router: DolbyED2SceneRouter) throws -> DolbyED2RoutedFrame {
        guard (1...2048).contains(maxFrames) else { throw DolbyEError.invalidArgument("ED2 preview requires one bounded video frame") }
        let sample = position, saved = iab?.captureCursor()
        defer {
            if let saved { iab?.restoreCursor(saved) }
            else { try? seek(toFrame: sample) }
        }
        var preview = router
        // Clustering needs the complete first analysis block. Keep this
        // bounded lookahead in copied DSP/cursor state, then return only the
        // requested samples; the subsequent real frame uses the same block.
        var result = try readED2(maxFrames: max(256, maxFrames), router: &preview)
        result.samples = Array(result.samples.prefix(maxFrames * 16))
        for index in result.metadata.objects.indices {
            result.metadata.objects[index].states = result.metadata.objects[index].states.filter { $0.sampleOffset < maxFrames }
        }
        return result
    }
    func seek(toFrame frame: UInt64) throws {
        if let wave { try wave.seek(toFrame: frame) } else if let caf { try caf.seek(toFrame: frame) } else { try iab!.seek(toFrame: frame) }
    }
    func identity() throws -> String {
        try DolbyEFileJobStore.hash(Data(dependencies.map { $0.standardizedFileURL.path + "|" + (try DolbyEFileJobStore.identity($0)) }.joined(separator: "\n").utf8))
    }
}

enum DolbyEEncodingRouter: Codable, Sendable {
    case pcm(DolbyEPCMRouter)
    case atmosphere(DolbyEAtmosRenderer)

    init(source: DolbyEInputSource, request: DolbyERequest) throws {
        if source.scene != nil || source.isIAB { self = .atmosphere(DolbyEAtmosRenderer(program: request.program, downmixMode: request.downmixMode)) }
        else { self = .pcm(try DolbyEPCMRouter(info: source.info, layout: request.inputLayout, program: request.program, downmixMode: request.downmixMode)) }
    }
    var stereoMode: UInt16 {
        if case .pcm(let router) = self, router.layout == .fiveOnePlusTwo { return 256 }
        switch self {
        case .pcm(let router): return router.downmixMode == .ltrt ? 260 : 258
        case .atmosphere(let renderer): return renderer.downmixMode == .ltrt ? 260 : 258
        }
    }
    var limitingGroups: [[Int]] {
        switch self {
        case .atmosphere(let renderer): return renderer.program == .fiveOnePlusTwo ? [Array(0..<6), [6, 7]] : [Array(0..<8)]
        case .pcm(let router):
            if router.layout == .fiveOnePlusTwo || (router.layout == .sevenOneScreen && router.program == .sevenOneScreen) { return [] }
            if router.layout == .fiveOne { return router.program == .fiveOnePlusTwo ? [[6, 7]] : [] }
            return router.program == .fiveOnePlusTwo ? [Array(0..<6), [6, 7]] : [Array(0..<8)]
        }
    }
    mutating func route(_ pcm: [Float], source: DolbyEInputSource, at position: UInt64) throws -> [Double] {
        switch self {
        case .pcm(var router):
            let result = try router.route(pcm); self = .pcm(router); return result
        case .atmosphere(var renderer):
            guard let scene = source.scene else { throw DolbyEError.malformed("Atmos metadata disappeared on resume") }
            let result = try renderer.render(pcm, scene: scene, at: position); self = .atmosphere(renderer); return result
        }
    }
}
