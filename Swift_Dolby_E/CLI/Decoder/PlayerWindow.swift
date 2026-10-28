// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import DolbyEDecoder

@MainActor
final class DolbyEPlayerModel: ObservableObject {
    let session = DolbyEPlaybackSession()
    let meterDisplay = DolbyEMeterDisplayModel()
    @Published var snapshot: DolbyEPlaybackSnapshot?
    @Published var devices: [DolbyEAudioDevice] = []
    @Published var layout: DolbyEPlaybackLayout = .fiveOne
    @Published var mainLayout: DolbyEPlaybackLayout = .fiveOne
    @Published var program = 0
    @Published var deviceID: UInt32 = DolbyEAudioDevices.defaultOutput() ?? 0
    @Published var endpointLayout = "auto"
    @Published var normalized = false
    @Published var downmixMode: DolbyEDownmixMode = .ltrt
    @Published var monitorMode: DolbyEMonitorMode = .direct
    @Published var mute = false
    @Published var monitorDB: Float = 0
    @Published var solo: Int?
    @Published var error: String?
    @Published var inputMode: DolbyEEncodeVision = .e
    @Published var primaryInput: URL?
    @Published var expansionInput: URL?
    @Published var opening = false
    @Published var requestedSeek: Double?
    private var seekTask: Task<Void, Never>?
    private var seekID = UUID()
    private var polling: Task<Void, Never>?
    private var meterUpdates: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?
    private var sourceGeneration = UUID()
    @Published private var openPanel: NSOpenPanel?
    private var filePanelTask: Task<Void, Never>?
    private var lastDirectory: URL?
    var choosingFile: Bool { openPanel != nil }
    private let initialLayout: DolbyEPlaybackLayout?
    private let initialSelection: DolbyEDecodeSelection

    init(input: URL?, muted: Bool, layout: DolbyEPlaybackLayout?, selection: DolbyEDecodeSelection, secondaryURL: URL? = nil,
         monitorMode: DolbyEMonitorMode = .direct) {
        self.mute = muted; self.layout = layout ?? .fiveOne; self.initialLayout = layout; self.initialSelection = selection
        self.primaryInput = input; self.expansionInput = secondaryURL
        self.inputMode = secondaryURL == nil ? .e : .ed2
        self.monitorMode = monitorMode
        self.devices = (try? DolbyEAudioDevices.outputs()) ?? []
        meterDisplay.reset(channels: self.layout.speakers.count)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A file sheet owns native navigation. Avoid repeatedly
                // rebuilding its presenting view while it is open.
                if !choosingFile && !opening {
                    let generation = sourceGeneration
                    let current = await session.snapshot()
                    if generation == sourceGeneration && !opening { self.snapshot = current }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        Task {
            await session.monitor(db: monitorDB, muted: mute)
            if let input { await open(input, secondaryURL: secondaryURL) }
            else { await configure() }
        }
    }
    func open(_ url: URL, secondaryURL: URL? = nil) async {
        guard !opening else { return }
        opening = true
        sourceGeneration = UUID()
        let generation = sourceGeneration
        meterUpdates?.cancel(); meterUpdates = nil
        seekTask?.cancel(); seekTask = nil; seekID = UUID(); requestedSeek = nil
        meterDisplay.reset(channels: layout.speakers.count)
        snapshot = nil
        defer { if generation == sourceGeneration { opening = false } }
        do {
            await pendingClose?.value; pendingClose = nil
            error = nil; try await session.open(url, secondaryURL: secondaryURL)
            guard generation == sourceGeneration else { return }
            let opened = await session.snapshot()
            snapshot = opened
            inputMode = opened.encodeVision
            primaryInput = opened.file; expansionInput = opened.secondaryFile
            program = initialSelection == .stereo ? 1 : 0
            guard program == 0 || opened.program == .fiveOnePlusTwo || opened.encodeVision == .ed2 else { throw DolbyEError.invalidArgument("this stream has no independent Stereo program") }
            mainLayout = initialLayout ?? (opened.encodeVision == .ed2 ? .nineOneSix : (opened.program == .sevenOneScreen ? .sevenOneScreen : .fiveOne))
            nativeProgramLayout()
            solo = nil; await configure()
            startMeterUpdates(generation: generation)
        }
        catch is CancellationError { }
        catch { if generation == sourceGeneration { self.error = error.localizedDescription } }
    }
    private func startMeterUpdates(generation: UUID) {
        meterUpdates?.cancel()
        meterUpdates = Task { [weak self, session] in
            let stream = await session.meterUpdates()
            for await update in stream {
                guard !Task.isCancelled, let self, generation == self.sourceGeneration else { return }
                if update.layout == self.layout { self.meterDisplay.receive(update) }
                if update.playing != self.snapshot?.playing {
                    let current = await session.snapshot()
                    if generation == self.sourceGeneration && !self.opening { self.snapshot = current }
                }
            }
        }
    }
    func clearInputs() {
        sourceGeneration = UUID()
        let generation = sourceGeneration
        seekTask?.cancel(); seekTask = nil; seekID = UUID(); requestedSeek = nil
        meterUpdates?.cancel(); meterUpdates = nil
        primaryInput = nil; expansionInput = nil; snapshot = nil; error = nil
        meterDisplay.reset(channels: layout.speakers.count)
        opening = true
        pendingClose = Task { [weak self, session] in
            await session.close()
            if self?.sourceGeneration == generation { self?.opening = false }
        }
    }
    func nativeProgramLayout() {
        layout = program == 1 ? .stereo : mainLayout
        meterDisplay.reset(channels: layout.speakers.count)
    }
    func chooseFile(expansion: Bool = false) {
        guard !opening, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav, UTType(filenameExtension: "mxf") ?? .data]
        panel.title = inputMode == .e ? "Open Dolby E" : (expansion ? "Open ED2 expansion stream" : "Open ED2 primary stream")
        if let directory = lastDirectory ?? (expansion ? expansionInput ?? primaryInput : primaryInput)?.deletingLastPathComponent() {
            panel.directoryURL = directory
        }
        let mode = inputMode
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        openPanel = panel
        // A nested runModal inside a view action blocks the main actor.
        // Suspending for a native sheet lets directory/file-provider callbacks
        // and the app event loop continue normally, including external drives.
        filePanelTask = Task { [weak self] in
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard let self else { return }
            defer { self.openPanel = nil; self.filePanelTask = nil }
            self.lastDirectory = panel.directoryURL
            guard !Task.isCancelled, response == .OK, let url = panel.url else { return }
            self.error = nil
            if mode == .e { await self.open(url) }
            else if expansion { self.expansionInput = url }
            else { self.primaryInput = url }
        }
    }
    func openPair() {
        guard let primaryInput else {
            error = "Select the ED2 primary stream."; return
        }
        // A multiplexed two-track MXF already contains both AES substreams.
        // Separate files retain explicit paths or the reader's companion lookup.
        let generation = sourceGeneration, expansion = expansionInput
        Task {
            guard generation == sourceGeneration else { return }
            await open(primaryInput, secondaryURL: expansion)
        }
    }
    func togglePlayback() {
        let generation = sourceGeneration
        Task {
            guard generation == sourceGeneration else { return }
            do {
                error = nil
                if snapshot?.playbackRequested == true { await session.pause() }
                else { try await session.play() }
            } catch is CancellationError { }
            catch { if generation == sourceGeneration { self.error = error.localizedDescription } }
            let current = await session.snapshot()
            if generation == sourceGeneration { snapshot = current }
        }
    }
    func seek(_ seconds: Double, coalescing: Bool = false) {
        seekTask?.cancel()
        let request = UUID(), generation = sourceGeneration
        seekID = request; requestedSeek = seconds
        seekTask = Task {
            do {
                if coalescing { try await Task.sleep(nanoseconds: 50_000_000) }
                try Task.checkCancellation()
                guard generation == sourceGeneration else { return }
                error = nil
                try await session.seek(seconds: seconds)
                try Task.checkCancellation()
                let current = await session.snapshot()
                guard seekID == request, generation == sourceGeneration else { return }
                snapshot = current; requestedSeek = nil
            } catch is CancellationError { }
            catch { if seekID == request && generation == sourceGeneration { self.error = error.localizedDescription; requestedSeek = nil } }
        }
    }
    func configure() async {
        let generation = sourceGeneration
        if meterDisplay.frame.target.count != layout.speakers.count { meterDisplay.reset(channels: layout.speakers.count) }
        do {
            if snapshot?.encodeVision == .ed2, program == 1 { layout = .stereo }
            try await session.configure(layout: layout, programIndex: program, deviceID: deviceID == 0 ? nil : deviceID,
                normalized: normalized, solo: solo, deviceSpeakers: monitorMode == .downmix ? DolbyEPlaybackLayout(rawValue: endpointLayout)?.physicalOrder : nil,
                downmixMode: downmixMode, monitorMode: monitorMode)
        }
        catch is CancellationError { }
        catch { if generation == sourceGeneration { self.error = error.localizedDescription } }
    }
    func monitor() { Task { await session.monitor(db: monitorDB, muted: mute) } }
    func toggleSolo(_ channel: Int) { solo = solo == channel ? nil : channel; Task { await configure() } }
    func shutdown() async {
        openPanel?.cancel(nil); filePanelTask?.cancel(); seekTask?.cancel()
        polling?.cancel(); polling = nil; meterUpdates?.cancel(); meterUpdates = nil
        await pendingClose?.value; pendingClose = nil
        await session.close(); meterDisplay.reset(channels: layout.speakers.count)
    }
}

private struct DolbyEPlayerView: View {
    @ObservedObject var model: DolbyEPlayerModel
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    private func profile(_ code: UInt8) -> String {
        DolbyECompressionProfile.allCases.first(where: { $0.code == code })?.displayName ?? "Code \(code)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            inputs
            meters
            timeline
            transport
            settings
            statusBar
            metadataView
        }.padding(24).frame(minWidth: 1080, minHeight: 650).preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dolby E / ED2 QC").font(.system(size: 27, weight: .semibold))
                Text(model.snapshot?.file?.lastPathComponent ?? "Open a Dolby E or ED2 carrier").foregroundStyle(.secondary).lineLimit(1)
                if let secondary = model.snapshot?.secondaryFile { Text(secondary.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let snapshot = model.snapshot, let program = snapshot.program, let rate = snapshot.frameRate {
                Text("\(snapshot.encodeVision == .ed2 ? "ED2" : program.rawValue)  ·  \(rate.rawValue) fps\n48 kHz  ·  20-bit carrier")
                    .font(.system(.caption, design: .monospaced)).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
            }
    }
    }
    private var inputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Input", selection: $model.inputMode) {
                    Text("Dolby E").tag(DolbyEEncodeVision.e)
                    Text("ED2").tag(DolbyEEncodeVision.ed2)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                if model.opening { ProgressView().controlSize(.small) }
                if model.inputMode == .ed2 {
                    Button("Load ED2", action: model.openPair)
                        .disabled(model.primaryInput == nil)
                        .help("Load the selected pair, or one multiplexed WAVE/MXF containing both substreams.")
                }
            }
            inputPath(model.inputMode == .ed2 ? "Primary" : "Input", url: model.primaryInput) {
                model.chooseFile()
            }.keyboardShortcut("o")
            if model.inputMode == .ed2 {
                HStack(spacing: 8) {
                    inputPath("Expansion", url: model.expansionInput) { model.chooseFile(expansion: true) }
                    Button("Clear Pair", action: model.clearInputs)
                        .disabled(model.primaryInput == nil && model.expansionInput == nil).help("Unload both ED2 inputs and stop playback")
                }
            }
        }.disabled(model.opening || model.choosingFile)
    }
    private func inputPath(_ label: String, url: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(url?.path ?? "No file selected")
                .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .help(url?.path ?? label).accessibilityLabel("\(label) path")
                .accessibilityValue(url?.path ?? "No file selected")
            Button("Open…", action: choose).accessibilityLabel("Open \(label.lowercased()) file")
        }
    }
    private var meters: some View {
        VStack(spacing: 7) {
            DolbyEMeterCanvas(model: model.meterDisplay)
            HStack(spacing: 8) {
                ForEach(Array(model.layout.speakers.enumerated()), id: \.offset) { index, speaker in
                    Button(speaker.monitorName(in: model.layout.speakers)) { model.toggleSolo(index) }
                        .buttonStyle(.bordered).tint(model.solo == index ? .orange : .gray)
                        .help("Solo \(speaker.monitorName(in: model.layout.speakers))")
                        .frame(maxWidth: .infinity)
                }
            }
        }.padding(14).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
    private var timeline: some View {
        HStack {
            Text(time(model.requestedSeek ?? model.snapshot?.seconds ?? 0)).monospacedDigit()
            Slider(value: Binding(get: { model.requestedSeek ?? model.snapshot?.seconds ?? 0 }, set: { model.seek($0, coalescing: true) }),
                in: 0...max(1, model.snapshot?.duration ?? 1), onEditingChanged: { editing in
                    if !editing, let target = model.requestedSeek { model.seek(target) }
                }).disabled(model.snapshot?.file == nil)
            Text(time(model.snapshot?.duration ?? 0)).monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(.caption, design: .monospaced))
    }
    private var transport: some View {
        HStack(spacing: 14) {
            Button(action: model.togglePlayback) { Label(model.snapshot?.playbackRequested == true ? "Pause" : "Play", systemImage: model.snapshot?.playbackRequested == true ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: []).disabled(model.snapshot?.file == nil)
            Spacer()
            Toggle("Mute monitor", isOn: $model.mute).onChange(of: model.mute) { _ in model.monitor() }
            Slider(value: $model.monitorDB, in: -60...6).frame(width: 130).onChange(of: model.monitorDB) { _ in model.monitor() }
            Text(String(format: "%+.1f dB", model.monitorDB)).font(.system(.caption, design: .monospaced)).frame(width: 65)
    }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                Text("Render layout").font(.caption).foregroundStyle(.secondary)
                Picker("Render layout", selection: $model.layout) {
                    ForEach(DolbyEPlaybackLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 140).disabled(model.snapshot?.encodeVision == .ed2 && model.program == 1)
                    .onChange(of: model.layout) { _ in
                        if model.program == 0 { model.mainLayout = model.layout }
                        Task { model.solo = nil; await model.configure() }
                    }
            }
            VStack(alignment: .leading) {
                Text("Program").font(.caption).foregroundStyle(.secondary)
                Picker("Program", selection: $model.program) {
                    Text(model.snapshot?.encodeVision == .ed2 ? "1 · Main + Objects" : (model.snapshot?.program == .sevenOneScreen ? "1 · 7.1 Scrn" : "1 · 5.1 Main")).tag(0)
                    if model.snapshot?.program == .fiveOnePlusTwo || model.snapshot?.encodeVision == .ed2 { Text("2 · Stereo").tag(1) }
                }.labelsHidden().frame(width: 145).onChange(of: model.program) { _ in Task { model.nativeProgramLayout(); await model.configure() } }
            }
            VStack(alignment: .leading) {
                Text("Monitoring").font(.caption).foregroundStyle(.secondary)
                Picker("Monitoring", selection: $model.monitorMode) {
                    ForEach(DolbyEMonitorMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 160).onChange(of: model.monitorMode) { _ in Task { await model.configure() } }
            }
            VStack(alignment: .leading) {
                Text("CoreAudio output").font(.caption).foregroundStyle(.secondary)
                Picker("CoreAudio output", selection: $model.deviceID) {
                    ForEach(model.devices) { device in Text(device.name + " · \(device.outputChannels) ch").tag(device.id) }
                }.labelsHidden().frame(minWidth: 160).disabled(model.monitorMode == .meters).onChange(of: model.deviceID) { _ in Task { await model.configure() } }
            }
          }
          HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                Text("Monitor levels").font(.caption).foregroundStyle(.secondary)
                Picker("Monitor levels", selection: $model.normalized) {
                    Text("Encoded PCM").tag(false); Text("Dialogue-normalized").tag(true)
                }.labelsHidden().onChange(of: model.normalized) { _ in Task { await model.configure() } }
            }
            if model.monitorMode == .downmix { VStack(alignment: .leading) {
                Text("Downmix output layout").font(.caption).foregroundStyle(.secondary)
                Picker("Downmix output layout", selection: $model.endpointLayout) {
                    Text("Device layout / Stereo").tag("auto")
                    ForEach(DolbyEPlaybackLayout.allCases, id: \.self) { Text($0.rawValue + " · WAVE order").tag($0.rawValue) }
                }.labelsHidden().frame(width: 165).onChange(of: model.endpointLayout) { _ in Task { await model.configure() } }
            } }
            if model.snapshot?.encodeVision == .ed2 {
                VStack(alignment: .leading) {
                    Text("Stereo matrix").font(.caption).foregroundStyle(.secondary)
                    Picker("Stereo matrix", selection: $model.downmixMode) {
                        Text("Lt/Rt").tag(DolbyEDownmixMode.ltrt); Text("Lo/Ro").tag(DolbyEDownmixMode.loro)
                    }.labelsHidden().frame(width: 85).onChange(of: model.downmixMode) { _ in Task { await model.configure() } }
                }
            }
          }
    }
    }
    private var statusBar: some View {
        HStack {
            Circle().fill(model.snapshot?.clipping == true ? .red : .green).frame(width: 7, height: 7)
            Text(model.error ?? model.snapshot?.status ?? "Ready").font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.red)
            Spacer()
            if model.snapshot?.clipping == true { Text("PCM clipping detected").font(.caption).foregroundStyle(.red) }
            if model.monitorMode == .meters { Text("QC clock · no audio output").font(.caption2).foregroundStyle(.secondary) }
            else if let device = model.snapshot?.device {
                if model.monitorMode == .direct {
                    Text("Renderer 1–\(min(model.layout.speakers.count, device.outputChannels)) → Output 1–\(min(model.layout.speakers.count, device.outputChannels))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Downmix: \(device.speakers.map { $0.monitorName(in: device.speakers) }.joined(separator: " "))").font(.caption2).foregroundStyle(.secondary)
                }
            }
    }
    }
    private var metadataView: some View {
        Group {
            if let snapshot = model.snapshot, snapshot.encodeVision == .ed2, let scene = snapshot.scene {
                DisclosureGroup("ED2 presentation metadata") {
                    HStack(alignment: .top, spacing: 36) {
                        Text("Beds: \(scene.beds.count)\nChannels: \(scene.beds.flatMap(\.channels).map(\.rawValue).joined(separator: " "))")
                        Text("Objects: \(scene.objects.count)\nDialogue objects: \(scene.objects.filter(\.isDialogue).count)\nPresentations: \(scene.presentations.count)")
                    }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.caption)
            } else {
                DisclosureGroup("AC-3 program metadata") {
                    if let info = model.snapshot?.metadata, info.indices.contains(model.program) {
                        let data = info[model.program]
                        HStack(alignment: .top, spacing: 36) {
                            Text("Target: \(data.bitRateKbps.map(String.init) ?? "unspecified") kbps\nDialnorm: \(data.dialogueLevel) dB\nRF: \(data.rfIsGainWord ? "Encoded gain" : profile(data.rfCode))\nLine: \(data.lineIsGainWord ? "Encoded gain" : profile(data.lineCodes.first ?? 0))")
                            Text("High-pass: \(data.highPassFilter ? "Yes" : "No")\nBandwidth LPF: \(data.bandwidthLowPassFilter ? "Yes" : "No")\nLFE LPF: \(data.lfeLowPassFilter ? "Yes" : "No")\nSurround 90°: \(data.surroundPhase90 ? "Yes" : "No")")
                        }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }.font(.caption)
            }
        }
    }
}

@MainActor
private final class DolbyEPlayerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: DolbyEPlayerModel
    var window: NSWindow?
    init(input: URL?, muted: Bool, layout: DolbyEPlaybackLayout?, selection: DolbyEDecodeSelection, secondaryURL: URL?, monitorMode: DolbyEMonitorMode) {
        model = DolbyEPlayerModel(input: input, muted: muted, layout: layout, selection: selection, secondaryURL: secondaryURL, monitorMode: monitorMode)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Dolby E / ED2 QC"; window.delegate = self
        window.contentView = NSHostingView(rootView: DolbyEPlayerView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        if #available(macOS 14, *) { NSApplication.shared.activate() }
        else { NSApplication.shared.activate(ignoringOtherApps: true) }
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Dolby E QC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; NSApplication.shared.mainMenu = menu
    }
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count <= 2 else { model.error = "Select one carrier or two ED2 substreams."; return }
        if let url = urls.first {
            let second = urls.count > 1 ? urls[1] : nil
            Task { await model.open(url, secondaryURL: second) }
        }
    }
}

@MainActor
func runDolbyEPlayer(input: URL?, muted: Bool, layout: DolbyEPlaybackLayout?, selection: DolbyEDecodeSelection, secondaryURL: URL? = nil,
                    monitorMode: DolbyEMonitorMode = .direct) {
    let app = NSApplication.shared
    let controller = DolbyEPlayerController(input: input, muted: muted, layout: layout, selection: selection, secondaryURL: secondaryURL, monitorMode: monitorMode)
    app.setActivationPolicy(.regular); app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}
