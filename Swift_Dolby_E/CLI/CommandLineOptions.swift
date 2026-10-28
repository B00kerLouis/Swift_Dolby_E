// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
#if ENCODER_CLI
import DolbyEEncoder
#else
import DolbyEDecoder
#endif

struct CommandLineOptions {
    let input: URL?
    let output: URL?
    let format: DolbyEOutputFormat
    let program: DolbyEProgram
    let rate: DolbyEFrameRate?
    let inputLayout: DolbyEInputLayout
    let jsonResult: Bool
    let probe: Bool
    let play: Bool
    let muted: Bool
    let playbackLayout: String
    let monitorMode: String
    let plan: Bool
    let metadata: [DolbyEAC3Metadata]?
    let decodeSelection: DolbyEDecodeSelection
    let downmixMode: DolbyEDownmixMode
    let encodeVision: DolbyEEncodeVision
    let dialogueSource: DolbyEDialogueSource
    let secondaryInput: URL?
    let encoderWorkers: Int
    let loudness: DolbyEOfflineLoudnessConfiguration?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        let aliases = ["-i": "--input", "-o": "--output", "-f": "--format", "-p": "--program", "--progam": "--program"]
        let valued: Set<String> = ["--input", "--input-pri", "--input-exp", "--output", "--format", "--program", "--frame-rate", "--input-layout", "--metadata", "--dialnorm", "--rf-profile", "--line-profile", "--ac3-bitrate", "--layout", "--monitor", "--presentation", "--downmix-mode", "--encode-vision", "--dialogue-source", "--secondary-input"]
        #if ENCODER_CLI
        let switches: Set<String> = ["--probe", "--plan", "--play", "--mute", "--json"]
        #else
        let switches: Set<String> = ["--probe", "--plan", "--play", "--mute"]
        #endif
        let loudnessOptions:Set<String>=["--loudness","--loudness-target","--loudness-ceiling","--loudness-layout","--loudness-version","--loudness-tolerance"]
        let valuedOptions = valued.union(["--workers"]).union(loudnessOptions)
        var index = 0
        while index < arguments.count {
            let raw = arguments[index]
            let option = aliases[raw] ?? raw
            if switches.contains(option) {
                guard flags.insert(option).inserted else { throw DolbyEError.invalidArgument("duplicate \(option)") }
            } else {
                guard valuedOptions.contains(option), index + 1 < arguments.count else {
                    throw DolbyEError.invalidArgument("unknown option or missing value: \(raw)")
                }
                guard values[option] == nil else { throw DolbyEError.invalidArgument("duplicate \(option)") }
                index += 1
                guard !arguments[index].hasPrefix("--") else { throw DolbyEError.invalidArgument("missing value: \(raw)") }
                values[option] = arguments[index]
            }
            index += 1
        }
        #if ENCODER_CLI
        guard values["--input-pri"] == nil, values["--input-exp"] == nil, values["--secondary-input"] == nil else {
            throw DolbyEError.invalidArgument("--input-pri/--input-exp are decoder options; encoding uses --input")
        }
        #endif
        guard values["--input"] == nil || values["--input-pri"] == nil else {
            throw DolbyEError.invalidArgument("choose --input for Dolby E or --input-pri/--input-exp for an ED2 pair")
        }
        guard values["--input-exp"] == nil || values["--secondary-input"] == nil else {
            throw DolbyEError.invalidArgument("choose --input-exp or the legacy --secondary-input option")
        }
        if values["--input-pri"] != nil || values["--input-exp"] != nil {
            guard values["--input-pri"] != nil, values["--input-exp"] != nil else {
                throw DolbyEError.invalidArgument("ED2 requires both --input-pri and --input-exp")
            }
        }
        for option in ["--input", "--input-pri", "--input-exp", "--secondary-input"] where values[option] != nil {
            guard !values[option]!.isEmpty else { throw DolbyEError.invalidArgument("empty path: \(option)") }
        }
        self.jsonResult = flags.contains("--json")
        let input = values["--input-pri"] ?? values["--input"]
        guard input != nil || flags.contains("--play") else {
            throw DolbyEError.invalidArgument("--input or the ED2 --input-pri/--input-exp pair is required")
        }
        guard values["--secondary-input"] == nil || values["--input"] != nil else {
            throw DolbyEError.invalidArgument("legacy --secondary-input requires --input; use --input-pri/--input-exp for ED2")
        }
        if !flags.contains("--probe"), !flags.contains("--plan"), !flags.contains("--play"), values["--output"] == nil {
            throw DolbyEError.invalidArgument("-o / --output is required")
        }
        guard !(flags.contains("--probe") && flags.contains("--plan")) else {
            throw DolbyEError.invalidArgument("choose --probe or --plan")
        }
        self.input = input.map { URL(fileURLWithPath: $0) }
        self.output = values["--output"].map { URL(fileURLWithPath: $0) }
        self.format = try DolbyEOutputFormat(argument: values["--format"] ?? "pcm")
        self.program = try DolbyEProgram(argument: values["--program"] ?? "5.1+2")
        self.rate = try values["--frame-rate"].flatMap { $0 == "auto" ? nil : try DolbyEFrameRate(argument: $0) }
        self.inputLayout = try DolbyEInputLayout(argument: values["--input-layout"] ?? "auto")
        self.play = flags.contains("--play")
        self.muted = flags.contains("--mute")
        self.playbackLayout = values["--layout"] ?? "auto"
        self.monitorMode = values["--monitor"] ?? "direct"
        guard ["direct", "downmix", "meters"].contains(monitorMode), values["--monitor"] == nil || play else {
            throw DolbyEError.invalidArgument("--monitor direct|downmix|meters requires --play")
        }
        guard let selection = DolbyEDecodeSelection(rawValue: values["--presentation"] ?? (play ? "main" : "all")) else {
            throw DolbyEError.invalidArgument("--presentation must be all, main or stereo")
        }
        self.decodeSelection = selection
        if playbackLayout != "auto" {
            guard DolbyEPlaybackLayout(rawValue: playbackLayout) != nil else { throw DolbyEError.invalidArgument("unknown speaker layout") }
            if !play {
                guard !flags.contains("--probe"), !flags.contains("--plan"), selection == .main
                    || selection == .stereo && playbackLayout == "2.0" else {
                    throw DolbyEError.invalidArgument("file --layout requires --presentation main; raw signals keep their transport order")
                }
            }
        }
        guard let downmix = DolbyEDownmixMode(rawValue: (values["--downmix-mode"] ?? "ltrt").lowercased()) else {
            throw DolbyEError.invalidArgument("--downmix-mode must be ltrt or loro")
        }
        self.downmixMode = downmix
        self.encodeVision = try DolbyEEncodeVision(argument: values["--encode-vision"] ?? "e")
        guard let workers = Int(values["--workers"] ?? "0"),(0...16).contains(workers) else { throw DolbyEError.invalidArgument("--workers must be0(auto)...16") }
        self.encoderWorkers = workers
        if let mode=values["--loudness"],mode != "off" {
            guard let kind=DolbyEOfflineLoudnessMode(rawValue:mode),let target=Double(values["--loudness-target"] ?? "-23"),let ceiling=Double(values["--loudness-ceiling"] ?? "-2.5"),let tolerance=Double(values["--loudness-tolerance"] ?? "0.2"),let layout=DolbyEPlaybackLayout(rawValue:values["--loudness-layout"] ?? "5.1"),let version=Int(values["--loudness-version"] ?? "1").flatMap(DolbyELoudnessPayloadVersion.init(rawValue:)) else{throw DolbyEError.invalidArgument("invalid loudness mode/target/ceiling/layout/version")}
            let configuration=DolbyEOfflineLoudnessConfiguration(mode:kind,targetLUFS:target,maximumTruePeakDBTP:ceiling,toleranceLU:tolerance,ed2Layout:layout,payloadVersion:version)
            try configuration.validate();self.loudness=configuration
            guard values["--dialnorm"]==nil else{throw DolbyEError.invalidArgument("loudness processing derives programme dialnorm; select --loudness-target instead")}
        }else{
            guard !loudnessOptions.subtracting(["--loudness"]).contains(where:{values[$0] != nil}) else{throw DolbyEError.invalidArgument("loudness settings require --loudness measure|normalize")}
            self.loudness=nil
        }
        guard let dialogue = DolbyEDialogueSource(rawValue: values["--dialogue-source"] ?? "none") else {
            throw DolbyEError.invalidArgument("--dialogue-source must be none or bed-c")
        }
        self.dialogueSource = dialogue
        self.secondaryInput = (values["--input-exp"] ?? values["--secondary-input"]).map { URL(fileURLWithPath: $0) }
        if let primary = self.input, let expansion = self.secondaryInput {
            guard primary.standardizedFileURL.resolvingSymlinksInPath() != expansion.standardizedFileURL.resolvingSymlinksInPath() else {
                throw DolbyEError.invalidArgument("ED2 primary and expansion inputs must be distinct files")
            }
        }
        #if ENCODER_CLI
        guard !play, !muted, values["--layout"] == nil, values["--presentation"] == nil else { throw DolbyEError.invalidArgument("--play/--mute/--layout are decoder options") }
        guard secondaryInput == nil else { throw DolbyEError.invalidArgument("--secondary-input is a decoder option") }
        guard encodeVision == .ed2 || dialogue == .none else { throw DolbyEError.invalidArgument("--dialogue-source requires --encode-vision ed2") }
        #else
        guard !loudnessOptions.contains(where:{values[$0] != nil}) else{throw DolbyEError.invalidArgument("loudness encoding controls require dolbye-encode")}
        guard values["--metadata"] == nil, values["--dialnorm"] == nil, values["--rf-profile"] == nil,
              values["--line-profile"] == nil, values["--ac3-bitrate"] == nil, values["--downmix-mode"] == nil,
              values["--encode-vision"] == nil, values["--dialogue-source"] == nil,values["--workers"] == nil else { throw DolbyEError.invalidArgument("encoding vision, AC-3 metadata and downmix controls are encoder options") }
        #endif
        guard !play || (values["--output"] == nil && !flags.contains("--probe") && !flags.contains("--plan")) else {
            throw DolbyEError.invalidArgument("choose playback or file export/probe")
        }
        guard !play || decodeSelection != .all else { throw DolbyEError.invalidArgument("QC selects main or stereo separately") }
        self.probe = flags.contains("--probe")
        self.plan = flags.contains("--plan")
        // Global ED2 options describe independent mono signals. Use one shared
        // record instead of the unrelated legacy 5.1+2 two-program cardinality.
        let metadataProgram: DolbyEProgram = encodeVision == .ed2 ? .eightMono : self.program
        if let path = values["--metadata"] {
            guard !["--dialnorm", "--rf-profile", "--line-profile", "--ac3-bitrate"].contains(where: { values[$0] != nil }) else {
                throw DolbyEError.invalidArgument("set AC-3 metadata in the JSON array or with individual options")
            }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            guard try file.seekToEnd() <= 16 * 1024 * 1024 else { throw DolbyEError.invalidArgument("metadata JSON exceeds 16 MiB") }
            try file.seek(toOffset: 0)
            self.metadata = try JSONDecoder().decode([DolbyEAC3Metadata].self, from: file.readToEnd() ?? Data())
        } else if ["--dialnorm", "--rf-profile", "--line-profile", "--ac3-bitrate"].contains(where: { values[$0] != nil }) {
            let indices = encodeVision == .ed2 ? [0] : Array(metadataProgram.programChannelCounts.indices)
            var settings = indices.map { DolbyEAC3Metadata.defaults(program: metadataProgram, index: $0) }
            settings[0].preferredDownmix = downmix == .ltrt ? 1 : 2
            for index in settings.indices {
                if let value = values["--dialnorm"] {
                    guard let number = Int(value) else { throw DolbyEError.invalidArgument("--dialnorm must be -31...-1") }
                    settings[index].dialogueLevel = number
                }
                if let value = values["--rf-profile"] {
                    guard let profile = DolbyECompressionProfile(argument: value), [.filmStandard, .filmLight, .musicLight, .musicStandard].contains(profile) else { throw DolbyEError.invalidArgument("--rf-profile supports film standard, film light, music light or music standard") }
                    settings[index].rfProfile = profile
                }
                if let value = values["--line-profile"] {
                    guard let profile = DolbyECompressionProfile(argument: value) else { throw DolbyEError.invalidArgument("invalid --line-profile") }
                    settings[index].lineProfile = profile
                }
                if let value = values["--ac3-bitrate"] {
                    let fields = value.split(separator: ",")
                    guard fields.count == 1 || fields.count == settings.count,
                          let number = Int(fields[fields.count == 1 ? 0 : index]) else { throw DolbyEError.invalidArgument("--ac3-bitrate expects one kbps value per program") }
                    settings[index].bitRateKbps = number
                }
                try settings[index].validate()
            }
            self.metadata = settings
        } else { self.metadata = nil }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

func reportFailure(_ error: Error) {
    let message = "error: \(error.localizedDescription)\n"
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
}

/// Keep Release terminal output focused on progress and actionable failures.
/// Core Data diagnostics remain available through the system unified log;
/// thrown persistence errors still reach reportFailure. No defaults are persisted.
func configureCLIDiagnostics() {
    #if !DEBUG
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["com.apple.CoreData.Logging.stderr"] = false
    arguments["com.apple.CoreData.Logging.oslog"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    #endif
}
