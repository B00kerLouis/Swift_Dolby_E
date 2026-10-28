// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

/// AVAudioTime can express either clock domain. A stale/invalid timestamp does
/// not prove an I/O cycle, and a valid sample-only virtual device is sufficient.
struct DolbyEAudioRenderClock: Sendable {
    private var sample: AVAudioFramePosition?
    private var host: UInt64?
    mutating func advanced(_ time: AVAudioTime?) -> Bool {
        guard let time else { return false }
        let advancedSample = time.isSampleTimeValid && sample.map { time.sampleTime > $0 } == true
        let advancedHost = time.isHostTimeValid && host.map { time.hostTime > $0 } == true
        if time.isSampleTimeValid { sample = time.sampleTime }
        if time.isHostTimeValid { host = time.hostTime }
        return advancedSample || advancedHost
    }
}

public struct DolbyEPlaybackSnapshot: Sendable {
    public let file: URL?
    public let status: String
    public let playing: Bool
    public let seconds: Double
    public let duration: Double
    public let program: DolbyEProgram?
    public let frameRate: DolbyEFrameRate?
    public let layout: DolbyEPlaybackLayout
    public let programIndex: Int
    public let meters: [Float]
    public let clipping: Bool
    public let metadata: [DolbyEAC3ProgramInfo]
    public let device: DolbyEAudioDevice?
    public let mute: Bool
    public let monitorDB: Float
    public let normalized: Bool
    public let encodeVision: DolbyEEncodeVision
    public let secondaryFile: URL?
    public let scene: DolbyED2SceneMetadata?
    public let monitorMode: DolbyEMonitorMode
    public let seeking: Bool
    public let playbackRequested: Bool
}

/// Latest rendered-frame meter data. This value feed is independent of the
/// larger transport/metadata snapshot and never contains PCM or audio handles.
public struct DolbyEPlaybackMeterSnapshot: Sendable {
    public let generation: UUID
    public let sequence: UInt64
    public let playing: Bool
    public let layout: DolbyEPlaybackLayout
    public let levels: [Float]
    public let sourceSeconds: Double
    public let hostSeconds: Double
}

public struct DolbyEPlaybackBufferTiming: Codable, Sendable {
    public let sourceSeconds: Double
    public let frames: Int
    public let decodeRenderSeconds: Double
    public let monitorScheduleSeconds: Double
    public let queuedBuffers: Int
    public let prefill: Bool
}

/// Opt-in bounded timing counters. No PCM or reader handle crosses the actor.
public struct DolbyEPlaybackDiagnostics: Codable, Sendable {
    public var buffers: [DolbyEPlaybackBufferTiming] = []
    public var renderedBuffers: [DolbyEPlaybackRenderTiming] = []
    public var depletedQueues = 0
    public var lookaheadCacheHits = 0
    public var outputChannelMap: [Int32] = []
}
public struct DolbyEPlaybackRenderTiming: Codable, Sendable {
    public let sourceEndSeconds: Double
    public let callbackHostSeconds: Double
}

/// One bounded native decoder and eight scheduled audio buffers. File I/O and
/// decoding execute on this actor; AVAudioEngine owns the hardware callback.
/// Seeking replays from at most 128 coarsened codec-state checkpoints.
public actor DolbyEPlaybackSession {
    private enum ReplayState {
        case e(codec: DolbyEPCMFrameDecoder, word: UInt64, boundaries: DolbyEStreamBoundaryInfo)
        case ed2(codec: DolbyED2PCMFrameDecoder, renderer: DolbyED2PresentationRenderer, limiter: DolbyETruePeakLimiter?,
                 firstWord: UInt64, secondWord: UInt64, firstBoundaries: DolbyEStreamBoundaryInfo,
                 secondBoundaries: DolbyEStreamBoundaryInfo, discarded: [UInt64], scene: DolbyED2SceneMetadata?)
    }
    private struct Checkpoint {
        let sample: UInt64
        let frame: UInt64
        let state: ReplayState
        let metadata: [DolbyEAC3ProgramInfo]
    }
    private var url: URL?
    private var accesses: [DolbyESecurityAccess] = []
    private var sourceURLs: [URL] = []
    private var source: DolbyEWaveCarrierReader?
    private var codec: DolbyEPCMFrameDecoder?
    private var ed2Source: DolbyED2CarrierReader?
    private var ed2Codec: DolbyED2PCMFrameDecoder?
    private var ed2Renderer: DolbyED2PresentationRenderer?
    private var presentationLimiter: DolbyETruePeakLimiter?
    private var encodeVision: DolbyEEncodeVision = .e
    private var scene: DolbyED2SceneMetadata?
    private var initialScene: DolbyED2SceneMetadata?
    private var initialMetadata: [DolbyEAC3ProgramInfo] = []
    private var downmixMode: DolbyEDownmixMode = .ltrt
    private var program: DolbyEProgram?
    private var rate: DolbyEFrameRate?
    private var metadata: [DolbyEAC3ProgramInfo] = []
    private var sourceIdentity = ""
    private var firstBurstWords: [UInt64] = []
    private var firstFrameNumber: UInt16 = 0
    private var navigationID = UUID()
    private var seekTarget: Double?
    private var playbackRequested = false
    private var checkpoints: [Checkpoint] = []
    private var checkpointStride: UInt64 = 25
    private var videoFrames: UInt64 = 0
    private var decodedSamples: UInt64 = 0
    private var playedSamples: UInt64 = 0
    private var pending: [Double]?
    private var meterPending: PreparedPCM?
    private var status = "Open a Dolby E or ED2 WAVE/MXF file"
    private var running = false
    private var eof = false
    private var playbackFailure: String?
    private var replayTarget: Double?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var queued = 0
    private var pausedRenderedSamples: UInt64 = 0
    private var pausedRenderedLevels: [Float]?
    private var layout: DolbyEPlaybackLayout = .fiveOne
    private var programIndex = 0
    private var normalized = false
    private var solo: Int?
    private var meters: [Float] = []
    private var clipping = false
    private var duration = 0.0
    private var mute = false
    private var monitorDB: Float = 0
    private var monitorMode: DolbyEMonitorMode = .direct
    private var device: DolbyEAudioDevice?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var outputFormat: AVAudioFormat?
    private var outputLock: DolbyEOutputLock?
    private var endpointSpeakers: [DolbyESpeaker]?
    private var endpointIndices: [Int]?
    private var monitorLimiter: DolbyETruePeakLimiter?
    private var audioStartupToken: UUID?
    private var meterContinuation: AsyncStream<DolbyEPlaybackMeterSnapshot>.Continuation?
    private var meterSubscription: UUID?
    private var meterSequence: UInt64 = 0
    private var diagnosticsEnabled = false
    private var runtimeDiagnostics = DolbyEPlaybackDiagnostics()
    private struct ED2Lookahead {
        let generation: UUID
        let parentFrame: UInt64
        let parentSample: UInt64
        let firstWord: UInt64
        let secondWord: UInt64
        let frame: DolbyED2CarrierFrame
        let samples: [Double]
        let decoder: DolbyED2PCMFrameDecoder
        let renderer: DolbyED2PresentationRenderer
        func matches(_ other: DolbyED2CarrierFrame) -> Bool {
            frame.first.coreWords == other.first.coreWords && frame.second.coreWords == other.second.coreWords
                && frame.first.evolutionWords == other.first.evolutionWords && frame.second.evolutionWords == other.second.evolutionWords
        }
    }
    /// At most one authenticated, completely decoded/rendered future frame.
    /// Reader cursors remain at the committed frame until a real read validates
    /// the cached packet again. Codec checkpoints therefore need no media cache.
    private var ed2Lookahead: ED2Lookahead?

    public init() {}
    /// One newest-value subscription per session. Replacing a subscriber
    /// finishes the old stream; slow consumers cannot build a display backlog.
    public func meterUpdates() -> AsyncStream<DolbyEPlaybackMeterSnapshot> {
        meterContinuation?.finish()
        let id = UUID()
        meterSubscription = id
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            meterContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.endMeterUpdates(id) }
            }
            publishMeters()
        }
    }
    private func endMeterUpdates(_ id: UUID) {
        guard meterSubscription == id else { return }
        meterContinuation = nil; meterSubscription = nil
    }
    private func publishMeters() {
        guard let meterContinuation else { return }
        if meterSequence < UInt64.max { meterSequence += 1 }
        meterContinuation.yield(.init(generation: generation, sequence: meterSequence, playing: running,
            layout: layout, levels: running ? meters : Array(repeating: -96, count: layout.speakers.count),
            sourceSeconds: Double(playedSamples) / 48000, hostSeconds: ProcessInfo.processInfo.systemUptime))
    }
    public func enableDiagnostics(_ enabled: Bool) {
        let channelMap = runtimeDiagnostics.outputChannelMap
        diagnosticsEnabled = enabled; runtimeDiagnostics = DolbyEPlaybackDiagnostics()
        runtimeDiagnostics.outputChannelMap = channelMap
    }
    public func diagnostics() -> DolbyEPlaybackDiagnostics { runtimeDiagnostics }
    private func recordBufferTiming(start: Double, decoded: Double, pcm: [Double], prefill: Bool) {
        guard diagnosticsEnabled else { return }
        let frames = pcm.count / (encodeVision == .ed2 ? layout.speakers.count : 8)
        if runtimeDiagnostics.buffers.count >= 256 { runtimeDiagnostics.buffers.removeFirst() }
        runtimeDiagnostics.buffers.append(DolbyEPlaybackBufferTiming(
            sourceSeconds: Double(decodedSamples - UInt64(frames)) / 48000, frames: frames,
            decodeRenderSeconds: decoded - start, monitorScheduleSeconds: ProcessInfo.processInfo.systemUptime - decoded,
            queuedBuffers: queued, prefill: prefill))
    }
    public func open(_ file: URL, secondaryURL: URL? = nil) throws {
        stopPlayback()
        for access in accesses { access.stop() }; accesses = []
        source = nil; codec = nil; ed2Source = nil; ed2Codec = nil; ed2Renderer = nil
        presentationLimiter = nil
        scene = nil; initialScene = nil; sourceURLs = []; url = nil; checkpoints = []; pending = nil; meterPending = nil
        let token = DolbyESecurityAccess(url: file, bookmark: Data(), createBookmark: false)
        let resolvedURL = token.url
        var openedAccesses = [token]
        do {
            let reader = try DolbyEWaveCarrierReader(url: resolvedURL)
            guard let first = try reader.readFrame() else { throw DolbyEError.malformed("source has no complete Dolby E frame") }
            let isED2 = secondaryURL != nil || reader.info.channelCount == 4
                || first.program == .eightMono && !first.evolutionWords.isEmpty
            if isED2 {
                let peer: URL?
                if let secondaryURL { peer = secondaryURL }
                else { peer = companion(for: resolvedURL) }
                var peerAccess: DolbyESecurityAccess?
                if let peer {
                    let access = DolbyESecurityAccess(url: peer, bookmark: Data(), createBookmark: false)
                    openedAccesses.append(access); peerAccess = access
                }
                var primary = resolvedURL, secondary = peerAccess?.url
                if reader.info.channelCount == 2, let peerAccess {
                    let packet = try DolbyED2MetadataContainer.parse(words: first.evolutionWords).verifying(coreWords: first.coreWords)
                    if try packet.scene() == nil {
                        let other = try DolbyEWaveCarrierReader(url: peerAccess.url)
                        guard let frame = try other.readFrame() else { throw DolbyEError.malformed("secondary input has no complete Dolby E frame") }
                        let metadata = try DolbyED2MetadataContainer.parse(words: frame.evolutionWords).verifying(coreWords: frame.coreWords)
                        guard try metadata.scene() != nil else { throw DolbyEError.malformed("neither ED2 input contains presentation topology") }
                        primary = peerAccess.url; secondary = resolvedURL
                    }
                }
                let paired = try DolbyED2CarrierReader(url: primary, secondaryURL: secondary)
                guard let frame = try paired.readFrame() else { throw DolbyEError.malformed("source has no complete ED2 frame pair") }
                let decoder = try DolbyED2PCMFrameDecoder(frameRate: frame.frameRate)
                try paired.seek(firstWord: 0, secondWord: 0)
                self.encodeVision = .ed2; self.ed2Source = paired; self.ed2Codec = decoder
                self.layout = .nineOneSix
                self.ed2Renderer = DolbyED2PresentationRenderer(layout: layout, downmixMode: downmixMode)
                self.scene = frame.scene; self.initialScene = frame.scene
                self.url = primary; self.sourceURLs = paired.sourceURLs
                self.program = .eightMono; self.rate = frame.frameRate
                self.metadata = frame.first.ac3Metadata + frame.second.ac3Metadata
                self.duration = Double(min(paired.first.info.frameCount, paired.second.info.frameCount)) / 48000
                self.firstBurstWords = [paired.first.lastFrameStartWord, paired.second.lastFrameStartWord]
                self.firstFrameNumber = frame.frameNumber
            } else {
                let decoder = try DolbyEPCMFrameDecoder(program: first.program, frameRate: first.frameRate)
                try reader.seek(toWord: 0)
                self.encodeVision = .e; self.source = reader; self.codec = decoder
                self.url = resolvedURL; self.sourceURLs = [resolvedURL]
                self.program = first.program; self.rate = first.frameRate; self.metadata = first.ac3Metadata
                self.duration = Double(reader.info.frameCount) / 48000
                self.firstBurstWords = [reader.lastFrameStartWord]; self.firstFrameNumber = first.frameNumber
            }
            self.sourceIdentity = try identity()
            self.accesses = openedAccesses; self.initialMetadata = metadata
            self.decodedSamples = 0; self.playedSamples = 0; self.videoFrames = 0; self.pending = nil
            self.programIndex = 0; self.eof = false; self.clipping = false; self.meters = Array(repeating: -96, count: layout.speakers.count)
            self.playbackFailure = nil; self.replayTarget = nil
            self.checkpoints = [try captureCheckpoint()]
            self.checkpointStride = 25; self.status = "Ready · \(encodeVision == .ed2 ? "ED2" : first.program.rawValue) · \(first.frameRate.rawValue) fps"
            publishMeters()
        } catch {
            for access in openedAccesses { access.stop() }
            accesses = []; source = nil; codec = nil; ed2Source = nil; ed2Codec = nil; ed2Renderer = nil
            sourceURLs = []; url = nil; scene = nil; initialScene = nil
            status = error.localizedDescription; throw error
        }
    }
    public func play() async throws {
        guard source != nil || ed2Source != nil else { throw DolbyEError.invalidArgument("open a Dolby E or ED2 file first") }
        if let playbackFailure { throw DolbyEError.invalidArgument("Playback failed: \(playbackFailure)") }
        playbackRequested = true
        if audioStartupToken == generation { return }
        if seekTarget != nil { return }
        if let replayTarget { try await seekInternal(seconds: replayTarget) }
        if let engine, !engine.isRunning, queued > 0 {
            let position = playedSamples
            stopPlayback(); playbackRequested = true; try await seekInternal(seconds: Double(position) / 48000)
        }
        if eof, queued == 0 { try await seekInternal(seconds: 0) }
        guard playbackRequested else { return }
        guard !running else { return }
        // Audio already rendered before pause may report completion afterwards.
        // Keep the paused cursor stable, then settle that progress exactly once
        // on resume. Seek/stop discard it with the old buffer generation.
        playedSamples += pausedRenderedSamples; pausedRenderedSamples = 0
        if let pausedRenderedLevels { meters = pausedRenderedLevels; self.pausedRenderedLevels = nil }
        let token = generation
        if monitorMode == .meters {
            running = true; status = "Playing · QC meters only"
            publishMeters()
            task = Task { await self.pumpMeters(token) }
            return
        }
        if engine == nil {
            do { try configureAudio(deviceID: device?.id ?? DolbyEAudioDevices.defaultOutput()) }
            catch { recoverAudioOutput(error.localizedDescription, token: token); throw error }
        }
        // Own startup before the first cooperative prefill yield. Concurrent
        // play requests must not create competing pumps for one generation.
        audioStartupToken = token
        defer { if audioStartupToken == token { audioStartupToken = nil } }
        do {
            while queued < 4, !eof {
                try Task.checkCancellation()
                guard generation == token, playbackRequested else { throw CancellationError() }
                let start = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
                guard let pcm = try autoreleasepool(invoking: { try nextPCM() }) else { eof = true; break }
                let decoded = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
                try schedule(pcm, token: token)
                recordBufferTiming(start: start, decoded: decoded, pcm: pcm, prefill: true)
                await Task.yield()
            }
            try Task.checkCancellation()
            guard generation == token, playbackRequested else { throw CancellationError() }
        } catch {
            if error is CancellationError || Task.isCancelled {
                cancelPendingPlayback(token)
                throw CancellationError()
            }
            playbackFailure = error.localizedDescription; playbackRequested = false
            status = error.localizedDescription; throw error
        }
        guard queued > 0 else { status = "Completed"; return }
        status = "Starting audio"
        do {
            if engine?.isRunning != true { try engine?.start() }
            try await waitForAudioClock(token)
            // AVAudioPlayerNode.play raises an Objective-C exception when the
            // engine reports running but has never received an I/O cycle.
            // Require a genuinely advancing node timestamp first. No await
            // separates the final generation check from starting this node.
            try Task.checkCancellation()
            guard generation == token, playbackRequested else { throw CancellationError() }
            player?.play()
        } catch {
            if error is CancellationError || Task.isCancelled { cancelPendingPlayback(token) }
            else { recoverAudioOutput(error.localizedDescription, token: token) }
            throw error
        }
        running = true; status = "Playing"
        publishMeters()
        task = Task { await self.pump(token) }
    }
    public func pause() {
        playbackRequested = false
        suspendPlayback()
    }
    private func suspendPlayback() {
        running = false; task?.cancel(); task = nil; player?.pause(); status = "Paused"
        meters = Array(repeating: -96, count: layout.speakers.count)
        publishMeters()
    }
    public func stop() async throws {
        pause(); try await seekInternal(seconds: 0); status = "Stopped"
    }
    public func close() {
        stopPlayback(); source = nil; codec = nil; checkpoints = []; pending = nil; meterPending = nil
        ed2Source = nil; ed2Codec = nil; ed2Renderer = nil; presentationLimiter = nil; scene = nil; initialScene = nil
        for access in accesses { access.stop() }; accesses = []
        sourceURLs = []; sourceIdentity = ""; url = nil; status = "Closed"
        metadata = []; initialMetadata = []; duration = 0; decodedSamples = 0; playedSamples = 0
        playbackFailure = nil; replayTarget = nil
        publishMeters(); meterContinuation?.finish(); meterContinuation = nil; meterSubscription = nil
    }
    public func seek(seconds: Double) async throws {
        try await seekInternal(seconds: seconds)
        if playbackRequested { try await play() }
    }
    public func configure(layout: DolbyEPlaybackLayout, programIndex: Int, deviceID: UInt32?, normalized: Bool, solo: Int?,
                          deviceSpeakers: [DolbyESpeaker]? = nil, deviceChannelIndices: [Int]? = nil,
                          downmixMode: DolbyEDownmixMode = .ltrt, monitorMode: DolbyEMonitorMode = .direct) async throws {
        guard (0...1).contains(programIndex), encodeVision == .ed2 || program == nil || program!.programChannelCounts.indices.contains(programIndex) else {
            throw DolbyEError.invalidArgument("the Dolby E stream does not contain that program")
        }
        if encodeVision == .ed2, normalized, Set(metadata.map(\.dialogueLevel)).count > 1 {
            throw DolbyEError.unsupported("ED2 monitor normalization needs one common dialogue level across the carried signals")
        }
        let layout = encodeVision == .ed2 && programIndex == 1 ? DolbyEPlaybackLayout.stereo : layout
        let renderChanged = self.layout != layout || self.programIndex != programIndex || self.downmixMode != downmixMode
        let resume = playbackRequested, time = seekTarget ?? Double(playedSamples) / 48000
        let mappingChanged = endpointSpeakers != deviceSpeakers || endpointIndices != deviceChannelIndices
        let monitorChanged = self.monitorMode != monitorMode
        endpointSpeakers = deviceSpeakers; endpointIndices = deviceChannelIndices
        suspendPlayback(); generation = UUID(); player?.stop(); queued = 0
        self.layout = layout; self.programIndex = programIndex
        self.downmixMode = downmixMode
        self.monitorMode = monitorMode
        self.normalized = normalized; self.solo = solo.flatMap { layout.speakers.indices.contains($0) ? $0 : nil }
        self.meters = Array(repeating: -96, count: layout.speakers.count)
        publishMeters()
        if monitorChanged || deviceID != nil && deviceID != device?.id || mappingChanged {
            engine?.stop(); engine = nil; player = nil; outputFormat = nil; outputLock = nil
            if monitorMode != .meters { try configureAudio(deviceID: deviceID ?? device?.id ?? DolbyEAudioDevices.defaultOutput()) }
        }
        if encodeVision == .ed2, ed2Source != nil, renderChanged { try resetED2Replay() }
        if source != nil || ed2Source != nil { try await seekInternal(seconds: time) }
        if resume && playbackRequested { try await play() }
    }
    public func monitor(db: Float, muted: Bool) {
        monitorDB = max(-60, min(6, db)); mute = muted
        player?.volume = mute ? 0 : pow(10, monitorDB / 20)
    }
    public func snapshot() -> DolbyEPlaybackSnapshot {
        DolbyEPlaybackSnapshot(file: url, status: status, playing: running, seconds: seekTarget ?? Double(playedSamples) / 48000,
            duration: duration, program: program, frameRate: rate, layout: layout, programIndex: programIndex,
            meters: running ? meters : Array(repeating: -96, count: layout.speakers.count), clipping: clipping, metadata: metadata, device: device, mute: mute, monitorDB: monitorDB, normalized: normalized,
            encodeVision: encodeVision, secondaryFile: sourceURLs.count == 2 ? sourceURLs[1] : nil, scene: scene, monitorMode: monitorMode,
            seeking: seekTarget != nil, playbackRequested: playbackRequested)
    }

    private func stopPlayback() {
        navigationID = UUID(); seekTarget = nil; playbackRequested = false
        replayTarget = nil
        generation = UUID(); running = false; task?.cancel(); task = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil; outputFormat = nil; outputLock = nil; queued = 0
        monitorLimiter = nil
        pausedRenderedSamples = 0; pausedRenderedLevels = nil
        audioStartupToken = nil
        ed2Lookahead = nil
        publishMeters()
    }
    /// Cancellation can land between the two AES reads or during prefill.
    /// Both cursors and codec histories must be reconstructed together before
    /// the next play; this is not a malformed-media/integrity failure.
    private func cancelPendingPlayback(_ token: UUID) {
        guard generation == token else { return }
        replayTarget = Double(playedSamples) / 48000
        generation = UUID(); player?.stop(); queued = 0; running = false; task = nil
        monitorLimiter = nil
        pausedRenderedSamples = 0; pausedRenderedLevels = nil; status = "Paused"
        audioStartupToken = nil
        ed2Lookahead = nil
        publishMeters()
    }
    private func recoverAudioOutput(_ reason: String, token: UUID) {
        guard generation == token else { return }
        let position = Double(playedSamples) / 48000
        stopPlayback()
        // Output readiness is independent of carrier/codec integrity. A retry
        // reconstructs the exact cursor and buffers without reopening media.
        replayTarget = position; status = reason
    }
    private func waitForAudioClock(_ token: UUID) async throws {
        let deadline = DolbyEMonotonicTime.now + 2_000_000_000
        var marker = DolbyEAudioRenderClock()
        while DolbyEMonotonicTime.now < deadline {
            try Task.checkCancellation()
            guard generation == token, playbackRequested else { throw CancellationError() }
            guard let engine, engine.isRunning, let player else {
                throw DolbyEError.outputUnavailable("CoreAudio stopped before playback")
            }
            if marker.advanced(player.lastRenderTime) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try Task.checkCancellation()
        guard generation == token, playbackRequested else { throw CancellationError() }
        throw DolbyEError.outputUnavailable("CoreAudio has no I/O clock; retry or select an available output")
    }
    private func companion(for file: URL) -> URL? {
        let stem = file.deletingPathExtension(), name = stem.lastPathComponent
        let ext = file.pathExtension
        var candidates = [DolbyED2CompanionFile.url(for: file), stem.appendingPathExtension("AES2.\(ext)")]
        if let existing = DolbyED2CompanionFile.existingURL(for: file) { candidates.insert(existing, at: 0) }
        if name.lowercased().hasSuffix(".aes2") {
            candidates.insert(stem.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(5))).appendingPathExtension(ext), at: 0)
        } else if name.range(of: "AES1", options: .caseInsensitive) != nil {
            candidates.append(stem.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "AES1", with: "AES2", options: .caseInsensitive)).appendingPathExtension(ext))
        } else if name.range(of: "AES2", options: .caseInsensitive) != nil {
            candidates.append(stem.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "AES2", with: "AES1", options: .caseInsensitive)).appendingPathExtension(ext))
        }
        return candidates.first {
            $0.standardizedFileURL.resolvingSymlinksInPath() != file.standardizedFileURL.resolvingSymlinksInPath()
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }
    private func identity() throws -> String {
        try DolbyEFileJobStore.hash(Data(sourceURLs.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path + "|" + (try DolbyEFileJobStore.identity($0))
        }.joined(separator: "\n").utf8))
    }
    private func captureCheckpoint() throws -> Checkpoint {
        let state: ReplayState
        if let source, let codec {
            state = .e(codec: codec, word: source.wordPosition, boundaries: source.boundaryInfo)
        } else if let source = ed2Source, let codec = ed2Codec, let renderer = ed2Renderer {
            state = .ed2(codec: codec, renderer: renderer, limiter: presentationLimiter, firstWord: source.first.wordPosition,
                secondWord: source.second.wordPosition, firstBoundaries: source.first.boundaryInfo,
                secondBoundaries: source.second.boundaryInfo, discarded: source.discardedLeadingFrames, scene: scene)
        } else { throw DolbyEError.malformed("playback decoder state is unavailable") }
        return Checkpoint(sample: decodedSamples, frame: videoFrames, state: state, metadata: metadata)
    }
    private func resetED2Replay() throws {
        guard let source = ed2Source, let rate else { throw DolbyEError.malformed("ED2 replay source disappeared") }
        try source.seek(firstWord: 0, secondWord: 0)
        ed2Codec = try DolbyED2PCMFrameDecoder(frameRate: rate)
        ed2Renderer = DolbyED2PresentationRenderer(layout: layout, downmixMode: downmixMode)
        presentationLimiter = try layout == .stereo ? DolbyETruePeakLimiter(groups: [[0, 1]], channelCount: 2) : nil
        scene = initialScene; metadata = initialMetadata
        decodedSamples = 0; videoFrames = 0; pending = nil; meterPending = nil; checkpointStride = 25
        checkpoints = [try captureCheckpoint()]
    }
    private func configureAudio(deviceID: UInt32?) throws {
        guard let id = deviceID, let discovered = try DolbyEAudioDevices.outputs().first(where: { $0.id == id }) else {
            throw DolbyEError.outputUnavailable("CoreAudio device is unavailable")
        }
        guard discovered.usable else { throw DolbyEError.outputUnavailable("CoreAudio device has no output channels") }
        let selected: DolbyEAudioDevice
        if monitorMode == .direct { selected = discovered }
        else if let endpointSpeakers { selected = try discovered.assigning(speakers: endpointSpeakers, channelIndices: endpointIndices) }
        else if discovered.hasSpeakerLabels { selected = discovered }
        else {
            guard discovered.outputChannels >= 2 else { throw DolbyEError.unsupported("stereo downmix requires two output channels") }
            selected = try discovered.assigning(speakers: [.left, .right])
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftDolbyE/Playback", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock: DolbyEOutputLock
        do { lock = try DolbyEOutputLock(output: directory.appendingPathComponent("device-\(id)"), directory: directory) }
        catch DolbyEError.invalidArgument {
            throw DolbyEError.outputUnavailable("\(selected.name) is already open in another QC instance")
        }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        try engine.outputNode.auAudioUnit.setDeviceID(id)
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(selected.outputChannels)
        guard let channelLayout = AVAudioChannelLayout(layoutTag: tag) else {
            throw DolbyEError.unsupported("CoreAudio cannot construct \(selected.outputChannels) discrete output channels")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            interleaved: false, channelLayout: channelLayout)
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        let hardwareFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: selected.sampleRate,
            interleaved: false, channelLayout: channelLayout)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        // HAL output channel-map destinations are physical driver lanes.
        // Keep all lanes above the supported first sixteen explicitly silent.
        guard let unit = engine.outputNode.audioUnit else { throw DolbyEError.outputUnavailable("CoreAudio output unit is unavailable") }
        var channelMap = (0..<selected.physicalChannels).map { $0 < selected.outputChannels ? Int32($0) : -1 }
        let mapBytes = UInt32(channelMap.count * MemoryLayout<Int32>.size)
        let mapStatus = channelMap.withUnsafeMutableBytes {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, $0.baseAddress!, mapBytes)
        }
        guard mapStatus == noErr else { throw DolbyEError.outputUnavailable("CoreAudio channel map failed (\(mapStatus))") }
        var confirmed = [Int32](repeating: -1, count: channelMap.count), confirmedBytes = mapBytes
        let readStatus = confirmed.withUnsafeMutableBytes {
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0, $0.baseAddress!, &confirmedBytes)
        }
        guard readStatus == noErr, confirmedBytes == mapBytes, confirmed == channelMap else {
            throw DolbyEError.outputUnavailable("CoreAudio did not retain the discrete output channel map")
        }
        runtimeDiagnostics.outputChannelMap = confirmed
        engine.prepare()
        node.volume = mute ? 0 : pow(10, monitorDB / 20)
        self.device = selected; self.outputLock = lock; self.engine = engine; self.player = node; self.outputFormat = format
        try resetMonitorLimiter()
    }
    private func resetMonitorLimiter() throws {
        monitorLimiter = try monitorMode == .downmix && device?.speakers.count == 2 && !(encodeVision == .ed2 && layout == .stereo)
            ? DolbyETruePeakLimiter(groups: [[0, 1]], channelCount: 2) : nil
    }
    /// Reacquire the target's real carrier neighborhood and decode a bounded
    /// four-frame pre-roll when metadata proves independence, otherwise64.
    /// Rational phase is restored from the absolute frame
    /// index; overlap, FIR, LFE and object ramps are filled by actual audio and
    /// metadata. Counter/cadence disagreement falls back to checkpoint replay.
    private func primeSeek(near sample: UInt64) throws -> Bool {
        guard let rate, let program, let origin = firstBurstWords.first else { return false }
        let p = DolbyEDecodingRateTables.profiles[rate.referenceCode - 1]
        let target = sample / UInt64(1792 * p.interpolation) * UInt64(p.decimation)
            + sample % UInt64(1792 * p.interpolation) * UInt64(p.decimation) / UInt64(1792 * p.interpolation)
        let shortFrames: UInt64 = layout == .stereo && encodeVision == .ed2 ? 8 : 4
        guard target > shortFrames else { return false }
        var start = target - shortFrames
        func locate(_ reader: DolbyEWaveCarrierReader, origin: UInt64, frameIndex: UInt64) throws -> UInt64? {
            let scaled = frameIndex.multipliedReportingOverflow(by: UInt64(48000 * rate.denominator))
            guard !scaled.overflow else { return nil }
            let carrierSamples = scaled.partialValue / UInt64(rate.numerator)
            let expected = firstFrameNumber &+ UInt16(truncatingIfNeeded: frameIndex)
            let doubled = carrierSamples.multipliedReportingOverflow(by: 2)
            let address = doubled.partialValue.addingReportingOverflow(origin)
            guard !doubled.overflow, !address.overflow else { return nil }
            let estimate = address.partialValue
            guard estimate < reader.info.frameCount * 2 else { return nil }
            let position = estimate > 8 ? estimate - 8 : 0
            guard let frame = try reader.locateFrame(nearWord: position), frame.frameNumber == expected,
                  frame.frameRate == rate, frame.program == program else { return nil }
            return reader.lastFrameStartWord
        }
        if let source {
            let boundaries = source.boundaryInfo
            guard let word = try locate(source, origin: origin, frameIndex: start) else { return false }
            try source.seek(toWord: word, restoring: boundaries)
            codec = try DolbyEPCMFrameDecoder(program: program, frameRate: rate, startingAtFrame: start)
        } else if let source = ed2Source, firstBurstWords.count == 2 {
            let a = source.first.boundaryInfo, b = source.second.boundaryInfo
            let discarded = source.discardedLeadingFrames
            guard var first = try locate(source.first, origin: origin, frameIndex: start),
                  var second = try locate(source.second, origin: firstBurstWords[1], frameIndex: start) else { return false }
            try source.seek(firstWord: first, secondWord: second, firstBoundaries: a,
                secondBoundaries: b, discardedLeadingFrames: discarded)
            var scenes: [(scene: DolbyED2SceneMetadata, samples: Int)] = []
            for index in start..<target {
                guard let frame = try source.readFrame() else { return false }
                let before = try DolbyESynthesisResampler.samplePosition(beforeFrame: index, frameRate: rate)
                let after = try DolbyESynthesisResampler.samplePosition(beforeFrame: index + 1, frameRate: rate)
                scenes.append((frame.scene, Int(after - before)))
            }
            if try !DolbyED2PresentationRenderer.permitsShortSeek(scenes, layout: layout) {
                start = target > 64 ? target - 64 : 0
                guard let a = try locate(source.first, origin: origin, frameIndex: start),
                      let b = try locate(source.second, origin: firstBurstWords[1], frameIndex: start) else { return false }
                first = a; second = b
            }
            try source.seek(firstWord: first, secondWord: second, firstBoundaries: a,
                secondBoundaries: b, discardedLeadingFrames: discarded)
            ed2Codec = try DolbyED2PCMFrameDecoder(frameRate: rate, startingAtFrame: start)
            ed2Renderer = DolbyED2PresentationRenderer(layout: layout, downmixMode: downmixMode)
            presentationLimiter = try layout == .stereo ? DolbyETruePeakLimiter(groups: [[0, 1]], channelCount: 2) : nil
        } else { return false }
        decodedSamples = try DolbyESynthesisResampler.samplePosition(beforeFrame: start, frameRate: rate)
        videoFrames = start
        return true
    }
    private func seekInternal(seconds: Double) async throws {
        guard seconds.isFinite, url != nil, source != nil || ed2Source != nil else { throw DolbyEError.invalidArgument("invalid playback seek") }
        guard try identity() == sourceIdentity else { throw DolbyEError.invalidArgument("a source substream changed while the player was open") }
        let navigation = UUID(); navigationID = navigation
        seekTarget = max(0, min(duration, seconds)); running = false; status = "Seeking"
        replayTarget = seekTarget
        defer { if navigationID == navigation { seekTarget = nil } }
        generation = UUID(); task?.cancel(); task = nil; player?.stop(); queued = 0; eof = false; pending = nil; meterPending = nil
        try resetMonitorLimiter()
        pausedRenderedSamples = 0; pausedRenderedLevels = nil
        publishMeters()
        let wanted = UInt64(max(0, min(duration, seconds)) * 48000)
        guard let saved = checkpoints.last(where: { $0.sample <= wanted }) else { throw DolbyEError.malformed("missing initial decoder checkpoint") }
        let fast = wanted - saved.sample > 8 * 2002 ? try primeSeek(near: wanted) : false
        if !fast { switch saved.state {
        case .e(let decoder, let word, let boundaries):
            guard let source else { throw DolbyEError.malformed("E checkpoint does not match the open source") }
            try source.seek(toWord: word, restoring: boundaries); codec = decoder
        case .ed2(let decoder, let renderer, let limiter, let firstWord, let secondWord, let firstBoundaries, let secondBoundaries, let discarded, let savedScene):
            guard let source = ed2Source, renderer.layout == layout, renderer.downmixMode == downmixMode else {
                throw DolbyEError.malformed("ED2 replay checkpoint does not match the presentation")
            }
            try source.seek(firstWord: firstWord, secondWord: secondWord, firstBoundaries: firstBoundaries,
                secondBoundaries: secondBoundaries, discardedLeadingFrames: discarded)
            ed2Codec = decoder; ed2Renderer = renderer; scene = savedScene
            presentationLimiter = limiter
        }
        metadata = saved.metadata; decodedSamples = saved.sample; videoFrames = saved.frame
        }
        let channels = encodeVision == .ed2 ? layout.speakers.count : 8
        while decodedSamples < wanted {
            try Task.checkCancellation()
            guard navigationID == navigation else { throw CancellationError() }
            let before = decodedSamples
            guard let pcm = try nextPCM() else { eof = true; break }
            if wanted < decodedSamples {
                let skip = Int(wanted - before) * channels
                pending = Array(pcm.dropFirst(skip)); break
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        guard navigationID == navigation else { throw CancellationError() }
        playedSamples = min(wanted, decodedSamples); status = eof ? "End of stream" : "Ready"
        replayTarget = nil
        meters = Array(repeating: -96, count: layout.speakers.count)
    }
    func nextPCM() throws -> [Double]? {
        if let pending { self.pending = nil; return pending }
        let pcm: [Double], channels: Int
        if let source, var decoder = codec {
            guard let frame = try source.readFrame() else { return nil }
            pcm = try decoder.decode(frame); channels = 8
            codec = decoder; metadata = frame.ac3Metadata
        } else if let source = ed2Source, var decoder = ed2Codec, var renderer = ed2Renderer {
            let firstWord = source.first.wordPosition, secondWord = source.second.wordPosition
            guard let frame = try source.readFrame() else { return nil }
            var rendered: [Double]
            if let cached = ed2Lookahead, cached.generation == generation,
               cached.parentFrame == videoFrames, cached.parentSample == decodedSamples,
               cached.firstWord == firstWord, cached.secondWord == secondWord,
               cached.renderer.layout == renderer.layout, cached.renderer.downmixMode == renderer.downmixMode,
               cached.matches(frame) {
                decoder = cached.decoder; renderer = cached.renderer; rendered = cached.samples
                if diagnosticsEnabled { runtimeDiagnostics.lookaheadCacheHits += 1 }
            } else {
                let decoded = try decoder.decode(frame)
                rendered = try renderer.render(decoded.samples, scene: decoded.scene)
            }
            ed2Lookahead = nil
            if var limiter = presentationLimiter {
                var preview = try peekED2Presentation(source: source, decoder: decoder, renderer: renderer,
                    parentFrame: videoFrames + 1, parentSample: decodedSamples + UInt64(rendered.count / renderer.outputChannelCount))?.samples
                    ?? [Double](repeating: 0, count: DolbyETruePeakLimiter.previewFrames * 2)
                try limiter.process(&rendered, preview: &preview)
                presentationLimiter = limiter
            }
            pcm = rendered
            channels = renderer.outputChannelCount
            ed2Codec = decoder; ed2Renderer = renderer; scene = frame.scene
            metadata = frame.first.ac3Metadata + frame.second.ac3Metadata
        } else { return nil }
        decodedSamples += UInt64(pcm.count / channels); videoFrames += 1
        if videoFrames % checkpointStride == 0 {
            if checkpoints.count >= 128 {
                checkpoints = checkpoints.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                checkpointStride *= 2
            }
            if checkpoints.last?.sample ?? 0 < decodedSamples {
                checkpoints.append(try captureCheckpoint())
            }
        }
        return pcm
    }
    private func pump(_ token: UUID) async {
        var marker = DolbyEAudioRenderClock()
        _ = marker.advanced(player?.lastRenderTime)
        var deadline = DolbyEMonotonicTime.now + 2_000_000_000
        while running, generation == token, !Task.isCancelled {
            guard engine?.isRunning == true else {
                recoverAudioOutput("Audio output stopped; retry or select an available output",token: token); return
            }
            if marker.advanced(player?.lastRenderTime) {
                deadline = DolbyEMonotonicTime.now + 2_000_000_000
            } else if DolbyEMonotonicTime.now >= deadline {
                recoverAudioOutput("CoreAudio I/O clock stopped; retry or select an available output",token: token); return
            }
            // Keep the output-clock watchdog alive while the final scheduled
            // buffers drain. EOF alone does not mean hardware rendered them.
            if eof { try? await Task.sleep(nanoseconds: 5_000_000); continue }
            if queued >= 8 { try? await Task.sleep(nanoseconds: 5_000_000); continue }
            do {
                let scheduled = try autoreleasepool { () throws -> Bool in
                    let start = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
                    guard let pcm = try nextPCM() else { return false }
                    let decoded = diagnosticsEnabled ? ProcessInfo.processInfo.systemUptime : 0
                    try schedule(pcm, token: token)
                    recordBufferTiming(start: start, decoded: decoded, pcm: pcm, prefill: false)
                    return true
                }
                if !scheduled {
                    eof = true
                    if queued == 0 { running = false; playbackRequested = false; status = "Completed"; duration = Double(decodedSamples) / 48000; meters = Array(repeating: -96, count: layout.speakers.count); publishMeters() }
                    if queued == 0 { break }
                }
            } catch {
                guard generation == token else { return }
                if error is CancellationError || Task.isCancelled {
                    cancelPendingPlayback(token); return
                }
                running = false; playbackRequested = false; playbackFailure = error.localizedDescription
                status = error.localizedDescription; player?.pause(); publishMeters(); break
            }
            await Task.yield()
        }
    }
    /// Meters-only playback advances on a monotonic sample clock without
    /// opening or locking an audio output device. Cancellation/seek invalidates the
    /// generation before the suspended task can publish stale meters or time.
    private func pumpMeters(_ token: UUID) async {
        var deadline = DolbyEMonotonicTime.now
        while running, generation == token, !Task.isCancelled {
            do {
                guard let prepared = try autoreleasepool(invoking: { () throws -> PreparedPCM? in
                    if let meterPending { return meterPending }
                    guard let pcm = try nextPCM() else { return nil }
                    return try prepare(pcm)
                }) else {
                    eof = true; running = false; playbackRequested = false; status = "Completed"
                    duration = Double(decodedSamples) / 48000
                    meters = Array(repeating: -96, count: layout.speakers.count)
                    publishMeters()
                    return
                }
                meterPending = prepared
                deadline += UInt64(prepared.frames) * 1_000_000_000 / 48000
                try await DolbyEMonotonicTime.sleep(until: deadline)
                guard running, generation == token, !Task.isCancelled else { return }
                meterPending = nil
                playedSamples += UInt64(prepared.frames); meters = prepared.levels
                publishMeters()
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                running = false; playbackRequested = false; playbackFailure = error.localizedDescription; status = error.localizedDescription; publishMeters(); return
            }
        }
    }
    private struct PreparedPCM {
        let samples: [Float]
        let frames: Int
        let levels: [Float]
        let center: Double
        let surround: Double
    }
    private func prepare(_ pcm: [Double], metadata override: [DolbyEAC3ProgramInfo]? = nil) throws -> PreparedPCM {
        guard let program else { throw DolbyEError.malformed("playback program disappeared") }
        let metadata = override ?? self.metadata
        let frames = pcm.count / (encodeVision == .ed2 ? layout.speakers.count : 8)
        let information = encodeVision == .ed2 ? metadata.first : (metadata.indices.contains(programIndex) ? metadata[programIndex] : nil)
        func mixLevel(_ code: UInt16) -> Double { code == 7 ? 0 : pow(10, [3.0, 1.5, 0, -1.5, -3, -4.5, -6][Int(code)] / 20) }
        let center = information.map { mixLevel(($0.extendedMix >> 3) & 7) } ?? sqrt(0.5)
        let surround = information.map { mixLevel($0.extendedMix & 7) } ?? sqrt(0.5)
        var virtual: [Float]
        if encodeVision == .ed2 { virtual = pcm.map(Float.init) }
        else {
            let selected = try DolbyEPlaybackRouting.selectProgram(pcm, configuration: program, index: programIndex)
            virtual = try DolbyEPlaybackRouting.render(selected.samples, source: selected.speakers, destination: layout.speakers,
                centerLevel: center, surroundLevel: surround)
        }
        if normalized, let information {
            let gain = Float(pow(10, Double((information.dialogueLevel == 0 ? 31 : abs(information.dialogueLevel)) - 31) / 20))
            for index in virtual.indices { virtual[index] *= gain }
        }
        let channels = layout.speakers.count
        var levels = [Float](repeating: -96, count: channels)
        for channel in 0..<channels {
            var peak: Float = 0
            for frame in 0..<frames { peak = max(peak, abs(virtual[frame * channels + channel])) }
            levels[channel] = max(-96, 20 * log10(max(1e-9, peak)))
            if peak > 1 { clipping = true }
        }
        return PreparedPCM(samples: virtual, frames: frames, levels: levels, center: center, surround: surround)
    }
    private func routeMonitor(_ prepared: PreparedPCM, device: DolbyEAudioDevice) throws -> [Double] {
        let frames = prepared.frames, channels = layout.speakers.count
        if monitorMode == .direct {
            return try DolbyEPlaybackRouting.direct(prepared.samples, inputChannels: channels,
                outputChannels: device.outputChannels, solo: solo).map(Double.init)
        }
        var monitored = prepared.samples.map(Double.init)
        if let solo { for frame in 0..<frames { for channel in 0..<channels where channel != solo { monitored[frame * channels + channel] = 0 } } }
        return try DolbyEPlaybackRouting.render(monitored, source: layout.speakers, destination: device.speakers,
            centerLevel: prepared.center, surroundLevel: prepared.surround, monitorMode: monitorMode).map(Double.init)
    }
    private func peekED2Presentation(source: DolbyED2CarrierReader, decoder: DolbyED2PCMFrameDecoder,
                                     renderer: DolbyED2PresentationRenderer, parentFrame: UInt64,
                                     parentSample: UInt64) throws -> (samples: [Double], metadata: [DolbyEAC3ProgramInfo])? {
        let first = source.first.wordPosition, second = source.second.wordPosition
        if let cached = ed2Lookahead, cached.generation == generation,
           cached.parentFrame == parentFrame, cached.parentSample == parentSample,
           cached.firstWord == first, cached.secondWord == second,
           cached.renderer.layout == renderer.layout, cached.renderer.downmixMode == renderer.downmixMode {
            return (Array(cached.samples.prefix(DolbyETruePeakLimiter.previewFrames * renderer.outputChannelCount)),
                cached.frame.first.ac3Metadata + cached.frame.second.ac3Metadata)
        }
        let a = source.first.boundaryInfo, b = source.second.boundaryInfo, discarded = source.discardedLeadingFrames
        func restore() throws {
            try source.seek(firstWord: first, secondWord: second, firstBoundaries: a,
                secondBoundaries: b, discardedLeadingFrames: discarded)
        }
        do {
            guard let frame = try source.readFrame() else { try restore(); return nil }
            var decoder = decoder, renderer = renderer
            let decoded = try decoder.decode(frame)
            let pcm = try renderer.render(decoded.samples, scene: decoded.scene)
            try restore()
            ed2Lookahead = ED2Lookahead(generation: generation, parentFrame: parentFrame, parentSample: parentSample,
                firstWord: first, secondWord: second, frame: frame, samples: pcm, decoder: decoder, renderer: renderer)
            return (Array(pcm.prefix(DolbyETruePeakLimiter.previewFrames * renderer.outputChannelCount)),
                frame.first.ac3Metadata + frame.second.ac3Metadata)
        } catch {
            try? restore(); throw error
        }
    }
    /// Preview512 physical samples in codec/renderer copies. Both real cursor
    /// positions are restored, so look-ahead never advances actual playback or
    /// changes its checkpoint. The limiter retains preview gains internally.
    func monitorPreview(device: DolbyEAudioDevice) throws -> [Double] {
        if let source, var decoder = codec {
            let word = source.wordPosition, boundaries = source.boundaryInfo
            defer { try? source.seek(toWord: word, restoring: boundaries) }
            guard let frame = try source.readFrame() else { return [Double](repeating: 0, count: DolbyETruePeakLimiter.previewFrames * 2) }
            let pcm = Array(try decoder.decode(frame).prefix(DolbyETruePeakLimiter.previewFrames * 8))
            return try routeMonitor(prepare(pcm, metadata: frame.ac3Metadata), device: device)
        }
        if let source = ed2Source, let decoder = ed2Codec, let renderer = ed2Renderer {
            guard let next = try peekED2Presentation(source: source, decoder: decoder, renderer: renderer,
                parentFrame: videoFrames, parentSample: decodedSamples) else {
                return [Double](repeating: 0, count: DolbyETruePeakLimiter.previewFrames * 2)
            }
            return try routeMonitor(prepare(next.samples, metadata: next.metadata), device: device)
        }
        throw DolbyEError.malformed("monitor preview source disappeared")
    }
    private func schedule(_ pcm: [Double], token: UUID) throws {
        guard let device, let format = outputFormat, let player else { throw DolbyEError.malformed("playback output disappeared") }
        let prepared = try prepare(pcm)
        let frames = prepared.frames
        let levels = prepared.levels
        let direct = monitorMode == .direct
        var directPCM: [Float] = []
        var physical: [Double] = []
        if direct {
            directPCM = try DolbyEPlaybackRouting.direct(prepared.samples, inputChannels: layout.speakers.count,
                outputChannels: device.outputChannels, solo: solo)
        } else { physical = try routeMonitor(prepared, device: device) }
        if var limiter = monitorLimiter {
            let count = physical.count
            // A seek can leave fewer than six samples before EOF. Detector
            // padding is never scheduled as extra programme audio.
            if frames < 6 { physical += [Double](repeating: 0, count: (6 - frames) * 2) }
            var preview = try monitorPreview(device: device)
            try limiter.process(&physical, preview: &preview)
            if physical.count != count { physical = Array(physical.prefix(count)) }
            monitorLimiter = limiter
        }
        if direct ? directPCM.contains(where: { abs($0) > 1 }) : physical.contains(where: { abs($0) > 1 }) { clipping = true }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let pointers = buffer.floatChannelData else {
            throw DolbyEError.unsupported("CoreAudio PCM buffer allocation")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if direct {
            for channel in 0..<device.outputChannels {
                for frame in 0..<frames { pointers[channel][frame] = directPCM[frame * device.outputChannels + channel] }
            }
        } else {
            for channel in 0..<device.outputChannels { pointers[channel].initialize(repeating: 0, count: frames) }
            for (index, physicalIndex) in device.channelIndices.enumerated() {
                for frame in 0..<frames { pointers[physicalIndex][frame] = Float(physical[frame * device.speakers.count + index]) }
            }
        }
        queued += 1
        let meterValues = levels
        let timingEnabled = diagnosticsEnabled, sourceEnd = decodedSamples
        // Render completion means PCM has entered the configured output graph.
        // Virtual inter-application bridges need not expose acoustic device
        // presentation completion; using it for backpressure stalls their FIFO.
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            // A scalar clock read separates callback timing from actor/DSP
            // scheduling delay. No lock, PCM copy or file I/O runs here.
            let hostTime = timingEnabled ? mach_absolute_time() : 0
            Task { await self?.completed(token, frames: frames, levels: meterValues, sourceEnd: sourceEnd, hostTime: hostTime) }
        }
    }
    private func completed(_ token: UUID, frames: Int, levels: [Float], sourceEnd: UInt64, hostTime: UInt64) {
        guard token == generation else { return }
        if hostTime != 0, diagnosticsEnabled {
            if runtimeDiagnostics.renderedBuffers.count >= 256 { runtimeDiagnostics.renderedBuffers.removeFirst() }
            runtimeDiagnostics.renderedBuffers.append(DolbyEPlaybackRenderTiming(sourceEndSeconds: Double(sourceEnd)/48000,
                callbackHostSeconds: AVAudioTime.seconds(forHostTime: hostTime)))
        }
        queued = max(0, queued - 1)
        if diagnosticsEnabled, running, queued == 0, !eof, Double(decodedSamples) / 48000 < duration - 1 {
            runtimeDiagnostics.depletedQueues += 1
        }
        if !running {
            pausedRenderedSamples += UInt64(frames); pausedRenderedLevels = levels
            return
        }
        playedSamples += UInt64(frames); meters = levels
        publishMeters()
        if eof, queued == 0 { running = false; playbackRequested = false; status = "Completed"; duration = Double(decodedSamples) / 48000; meters = Array(repeating: -96, count: layout.speakers.count); publishMeters() }
    }
}
