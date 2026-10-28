// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyEEncodingPlan: Codable, Sendable {
    public let source: DolbyEMasterInfo
    public let program: DolbyEProgram
    public let format: DolbyEOutputFormat
    public let frameRate: DolbyEFrameRate
    public let carrierSampleRate: Int
    public let carrierChannels: Int
    public let significantBits: Int
    public let outputChannels: [String]
    public let pendingVerification: [String]
    public let readyToEncode: Bool
    public let ac3Metadata: [DolbyEAC3Metadata]
    public let downmixMode: DolbyEDownmixMode
    public let encodeVision: DolbyEEncodeVision
    public let dialogueSource: DolbyEDialogueSource
    public let outputFiles: [URL]
}

public enum DolbyEEncoding {
    /// Performs bounded input/output inspection using the same source-layout
    /// validation as the file encoder.
    public static func prepare(_ request: DolbyERequest) throws -> DolbyEEncodingPlan {
        let input = request.inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let output = request.outputURL.standardizedFileURL.resolvingSymlinksInPath()
        guard input != output else { throw DolbyEError.invalidArgument("input and output must be different files") }
        let source = try DolbyEMasterProbe.inspect(input)
        if request.encodeVision == .ed2 {
            let opened = try DolbyEInputSource(url: input, program: .eightMono)
            let rate = request.frameRate ?? opened.embeddedFrameRate ?? .fps25
            let router = DolbyED2SceneRouter(dialogueSource: request.dialogueSource, inputLayout: request.inputLayout)
            _ = try opened.peekED2(maxFrames: 256, router: router)
            let paired = request.format == .mxfOPAtom || request.format == .pcm
            let output = paired ? DolbyED2CompanionFile.primaryURL(for: output) : output
            let outputs = [output] + (paired ? [DolbyED2CompanionFile.url(for: output)] : [])
            guard !outputs.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == input }) else {
                throw DolbyEError.invalidArgument("input and output must be different files")
            }
            var pending: [String] = []
            if FileManager.default.fileExists(atPath: output.path) { pending.append("output already exists") }
            let companion = DolbyED2CompanionFile.url(for: output)
            if paired, FileManager.default.fileExists(atPath: companion.path) {
                pending.append("AES2 companion already exists")
            }
            return DolbyEEncodingPlan(source: source, program: .eightMono, format: request.format,
                frameRate: rate, carrierSampleRate: 48000, carrierChannels: 4, significantBits: 20,
                outputChannels: DolbyED2Speaker.fiveOneTwo.map(\.rawValue) + (1...8).map { "Object \($0)" },
                pendingVerification: pending, readyToEncode: pending.isEmpty,
                ac3Metadata: try DolbyED2PCMFrameEncoder.monoMetadata(request.ac3Metadata).compactMap(\.ac3),
                downmixMode: request.downmixMode, encodeVision: .ed2, dialogueSource: request.dialogueSource,
                outputFiles: [output] + (paired ? [companion] : []))
        }
        var pending: [String] = []
        if source.family == .pcm {
            guard let wave = source.wave, [6, 8].contains(wave.channelCount), wave.frameCount > 0 else {
                throw DolbyEError.unsupported("plain PCM imports require 5.1 (6 channels) or 7.1 (8 channels)")
            }
            guard wave.sampleRate == 48000 else {
                throw DolbyEError.unsupported("reference encoder requires 48 kHz PCM")
            }
            _ = try DolbyEPCMRouter(info: wave, layout: request.inputLayout, program: request.program)
        }
        let opened = try DolbyEInputSource(url: input, program: request.program)
        let rate = request.frameRate ?? opened.embeddedFrameRate ?? .fps25
        let router = try DolbyEEncodingRouter(source: opened, request: request)
        let metadata = try programMetadata(request, stereoMode: router.stereoMode)
        if FileManager.default.fileExists(atPath: output.path) { pending.append("output already exists") }
        return DolbyEEncodingPlan(source: source, program: request.program, format: request.format,
                                  frameRate: rate, carrierSampleRate: 48000, carrierChannels: 2,
                                  significantBits: 20, outputChannels: request.program.channels,
                                  pendingVerification: pending, readyToEncode: pending.isEmpty,
                                  ac3Metadata: metadata.compactMap(\.ac3), downmixMode: request.downmixMode,
                                  encodeVision: .e, dialogueSource: .none, outputFiles: [output])
    }

    static func programMetadata(_ request: DolbyERequest, stereoMode: UInt16) throws -> [DolbyEProgramMetadata] {
        let counts = request.program.programChannelCounts
        var settings = request.ac3Metadata ?? counts.indices.map { DolbyEAC3Metadata.defaults(program: request.program, index: $0) }
        guard settings.count == counts.count else { throw DolbyEError.invalidArgument("AC-3 metadata must have one entry per Dolby E program") }
        if request.ac3Metadata == nil {
            settings[0].preferredDownmix = request.downmixMode == .ltrt ? 1 : 2
            if settings.count == 2 { settings[1].dolbySurroundMode = Int((stereoMode >> 1) & 3) }
        } else if settings[0].preferredDownmix != 0,
                  settings[0].preferredDownmix != (request.downmixMode == .ltrt ? 1 : 2) {
            throw DolbyEError.invalidArgument("metadata preferredDownmix must agree with --downmix-mode")
        }
        if settings.count == 2, stereoMode != 256 { settings[1].dolbySurroundMode = Int((stereoMode >> 1) & 3) }
        for (index, setting) in settings.enumerated() {
            try setting.validate()
            let mode = counts[index] == 1 ? 1 : (counts[index] == 2 ? 2 : 7)
            guard setting.audioCodingMode == mode, setting.lfe == (counts[index] > 2) else {
                throw DolbyEError.invalidArgument("AC-3 channel mode/LFE must describe the selected Dolby E program")
            }
        }
        return try settings.map { try DolbyEProgramMetadata(ac3: $0) }
    }
}
