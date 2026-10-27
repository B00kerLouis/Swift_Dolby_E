// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// The two file APIs use the same output and recovery implementation. Encoded
/// words never pass through floating-point PCM when selecting an MXF wrapper.
final class DolbyEMediaWriter {
    enum Checkpoint: Codable, Sendable {
        case wave(DolbyEWaveWriter.Checkpoint)
        case mxf(DolbyEMXFWriter.Checkpoint)
        case ed2Atoms(DolbyED2MediaWriter.Checkpoint)
        case ed2Waves(DolbyED2WavePairWriter.Checkpoint)
        var dataBytes: UInt64 {
            switch self {
            case .wave(let value): value.dataBytes
            case .mxf(let value): value.dataBytes
            case .ed2Atoms(let value): value.dataBytes
            case .ed2Waves(let value): value.dataBytes
            }
        }
    }
    private let wave: DolbyEWaveWriter?
    private let mxf: DolbyEMXFWriter?
    private let ed2Atoms: DolbyED2MediaWriter?
    private let ed2Waves: DolbyED2WavePairWriter?
    var dataBytes: UInt64 { wave?.dataBytes ?? mxf?.dataBytes ?? ed2Atoms?.dataBytes ?? ed2Waves!.dataBytes }
    var additionalOutputURLs: [URL] { (ed2Atoms?.companionURL ?? ed2Waves?.companionURL).map { [$0] } ?? [] }

    init(url: URL, format: DolbyEOutputFormat, rate: DolbyEFrameRate, channels: Int, dolbyE: Bool,
         description: String, channelMask: UInt32 = 0, companionURL: URL? = nil) throws {
        if format == .pcm, dolbyE, channels == 4 {
            wave = nil; mxf = nil; ed2Atoms = nil
            ed2Waves = try DolbyED2WavePairWriter(url: url, companionURL: companionURL, description: description)
        } else if format == .pcm {
            wave = try DolbyEWaveWriter(url: url, channelCount: channels, dolbyE: dolbyE,
                description: description, channelMask: channelMask)
            mxf = nil; ed2Atoms = nil; ed2Waves = nil
        } else if format == .mxfOPAtom, dolbyE, channels == 4 {
            wave = nil; mxf = nil; ed2Waves = nil
            ed2Atoms = try DolbyED2MediaWriter(url: url, companionURL: companionURL, rate: rate)
        } else {
            wave = nil; ed2Atoms = nil; ed2Waves = nil
            mxf = try DolbyEMXFWriter(url: url, format: format, frameRate: rate, channelCount: channels, dolbyE: dolbyE)
        }
    }
    init(resuming url: URL, checkpoint: Checkpoint, recoveringFinalization: Bool, companionURL: URL? = nil) throws {
        switch checkpoint {
        case .wave(let value):
            wave = try DolbyEWaveWriter(resuming: url, checkpoint: value, recoveringFinalization: recoveringFinalization)
            mxf = nil; ed2Atoms = nil; ed2Waves = nil
        case .mxf(let value):
            mxf = try DolbyEMXFWriter(resuming: url, checkpoint: value, recoveringFinalization: recoveringFinalization)
            wave = nil; ed2Atoms = nil; ed2Waves = nil
        case .ed2Atoms(let value):
            ed2Atoms = try DolbyED2MediaWriter(resuming: url, companionURL: companionURL, checkpoint: value,
                recoveringFinalization: recoveringFinalization)
            wave = nil; mxf = nil; ed2Waves = nil
        case .ed2Waves(let value):
            ed2Waves = try DolbyED2WavePairWriter(resuming: url, companionURL: companionURL, checkpoint: value,
                recoveringFinalization: recoveringFinalization)
            wave = nil; mxf = nil; ed2Atoms = nil
        }
    }
    func appendCarrier(_ words: [UInt32]) throws {
        if let wave { try wave.appendCarrier(words) }
        else if let mxf { try mxf.appendCarrier(words) }
        else if let ed2Atoms { try ed2Atoms.appendCarrier(words) }
        else { try ed2Waves!.appendCarrier(words) }
    }
    func appendPCM(_ samples: [Double]) throws {
        if let wave { try wave.appendPCM(samples) }
        else if let mxf { try mxf.appendPCM(samples) }
        else { throw DolbyEError.invalidArgument("ED2 carrier writer does not accept decoded PCM") }
    }
    func checkpoint() throws -> Checkpoint {
        if let wave { return .wave(try wave.checkpoint()) }
        if let mxf { return .mxf(try mxf.checkpoint()) }
        if let ed2Atoms { return .ed2Atoms(try ed2Atoms.checkpoint()) }
        return .ed2Waves(try ed2Waves!.checkpoint())
    }
    func finish() throws {
        if let wave { try wave.finish() }
        else if let mxf { try mxf.finish() }
        else if let ed2Atoms { try ed2Atoms.finish() }
        else { try ed2Waves!.finish() }
    }

    static func inspect(_ url: URL, format: DolbyEOutputFormat) throws -> WavePCMInfo {
        if format == .pcm { return try WavePCMReader(url: url).info }
        return try DolbyEMXFReader(url: url).info
    }

    static func inspectED2(_ url: URL, companionURL: URL? = nil, format: DolbyEOutputFormat) throws -> WavePCMInfo {
        if format == .pcm, let companionURL {
            guard url.standardizedFileURL.resolvingSymlinksInPath() != companionURL.standardizedFileURL.resolvingSymlinksInPath() else {
                throw DolbyEError.invalidArgument("ED2 WAV inspection requires two distinct substream files")
            }
            let a = try WavePCMReader(url: url).info, b = try WavePCMReader(url: companionURL).info
            guard a.channelCount == 2, b.channelCount == 2, a.sampleRate == 48000, b.sampleRate == 48000,
                  a.containerBits == b.containerBits, a.validBits == b.validBits, a.frameCount == b.frameCount,
                  a.dataBytes == b.dataBytes, a.floatingPoint == b.floatingPoint else { throw DolbyEError.malformed("ED2 WAV substream files disagree") }
            return WavePCMInfo(sampleRate: a.sampleRate, channelCount: 4, containerBits: a.containerBits,
                validBits: a.validBits, channelMask: 0, floatingPoint: a.floatingPoint, frameCount: a.frameCount,
                hasADM: false, hasChannelAssignment: false, hasDolbyMetadata: true, dataOffset: 0, dataBytes: a.dataBytes + b.dataBytes)
        }
        if format != .mxfOPAtom {
            let info = try inspect(url, format: format)
            guard info.channelCount == 4 else { throw DolbyEError.malformed("ED2 output requires two carrier pairs") }
            return info
        }
        guard let companionURL else { throw DolbyEError.invalidArgument("ED2 OP-Atom inspection requires its companion file") }
        guard url.standardizedFileURL.resolvingSymlinksInPath() != companionURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw DolbyEError.invalidArgument("ED2 OP-Atom companion must be a distinct file")
        }
        let first = try DolbyEMXFReader(url: url), second = try DolbyEMXFReader(url: companionURL)
        let a = first.info, b = second.info
        guard first.compressed, second.compressed, a.channelCount == 2, b.channelCount == 2,
              a.sampleRate == b.sampleRate, a.containerBits == b.containerBits, a.frameCount == b.frameCount,
              a.dataBytes == b.dataBytes else { throw DolbyEError.malformed("ED2 OP-Atom companion files disagree") }
        return WavePCMInfo(sampleRate: a.sampleRate, channelCount: 4, containerBits: a.containerBits,
            validBits: a.validBits, channelMask: 0, floatingPoint: false, frameCount: a.frameCount,
            hasADM: false, hasChannelAssignment: false, hasDolbyMetadata: true,
            dataOffset: 0, dataBytes: a.dataBytes + b.dataBytes)
    }
}
