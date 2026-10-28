// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyEError: Error, LocalizedError, Sendable {
    case invalidArgument(String)
    case malformed(String)
    case unsupported(String)
    case unverified(String)
    case outputUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): "Invalid argument: \(message)"
        case .malformed(let message): "Malformed input: \(message)"
        case .unsupported(let message): "Unsupported input: \(message)"
        case .unverified(let message): "Not yet reference-verified: \(message)"
        case .outputUnavailable(let message): "Audio output unavailable: \(message)"
        }
    }
}

public struct DolbyEStreamBoundaryInfo: Codable, Sendable {
    public var leadingWords: UInt64
    public var truncatedTailWords: UInt64

    public init(leadingWords: UInt64 = 0, truncatedTailWords: UInt64 = 0) {
        self.leadingWords = leadingWords
        self.truncatedTailWords = truncatedTailWords
    }
}

public enum DolbyEProgram: String, CaseIterable, Codable, Sendable {
    case fiveOnePlusTwo = "5.1+2"
    case sevenOneScreen = "7.1-scrn"
    /// Eight independent full-band signals, used by an ED2 substream.
    case eightMono = "8x1"

    public init(argument: String) throws {
        switch argument.lowercased() {
        case "5.1+2": self = .fiveOnePlusTwo
        case "7.1-scrn", "7.1 scrn", "7.1-screen": self = .sevenOneScreen
        case "8x1": self = .eightMono
        default: throw DolbyEError.invalidArgument("program must be 5.1+2, 7.1-scrn or 8x1")
        }
    }

    /// Channel semantics for the corresponding wire configurations.
    public var channels: [String] {
        switch self {
        case .fiveOnePlusTwo: ["L", "R", "C", "LFE", "Ls", "Rs", "L2", "R2"]
        case .sevenOneScreen: ["L", "R", "C", "LFE", "Ls", "Rs", "Le", "Re"]
        case .eightMono: (1...8).map { "Signal \($0)" }
        }
    }

    public var referenceTableIndex: Int {
        switch self { case .fiveOnePlusTwo: 0; case .sevenOneScreen: 23; case .eightMono: 10 }
    }
    public var programChannelCounts: [Int] {
        switch self { case .fiveOnePlusTwo: [6, 2]; case .sevenOneScreen: [8]; case .eightMono: Array(repeating: 1, count: 8) }
    }
    public var lfeChannel: Int? { self == .eightMono ? nil : 3 }
}

public enum DolbyEEncodeVision: String, Codable, Sendable {
    case e, ed2
    public init(argument: String) throws {
        guard let value = Self(rawValue: argument.lowercased()) else { throw DolbyEError.invalidArgument("--encode-vision must be e or ed2") }
        self = value
    }
}

public enum DolbyEDialogueSource: String, Codable, Sendable {
    case none, bedCenter = "bed-c"
}

/// A paired file keeps the requested primary filename. Explicit AES1 suffixes
/// are replaced, so OUTPUT.AES1.wav has the companion OUTPUT.AES2.wav.
public enum DolbyED2CompanionFile {
    public static func url(for primary: URL) -> URL {
        let stem = primary.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        let marked = [".aes1", "_aes1", "-aes1"].contains { lower.hasSuffix($0) } || lower == "aes1"
        let name = marked ? String(stem.dropLast(4)) + "AES2" : stem + ".AES2"
        let base = primary.deletingLastPathComponent().appendingPathComponent(name)
        return primary.pathExtension.isEmpty ? base : base.appendingPathExtension(primary.pathExtension)
    }
}

public enum DolbyEInputLayout: String, Codable, Sendable {
    case automatic = "auto"
    case fiveOne = "5.1"
    case fiveOneTwo = "5.1.2"
    case sevenOneHome = "7.1"
    case sevenOneScreen = "7.1-scrn"
    case fiveOnePlusTwo = "5.1+2"

    public init(argument: String) throws {
        switch argument.lowercased() {
        case "auto": self = .automatic
        case "5.1": self = .fiveOne
        case "5.1.2": self = .fiveOneTwo
        case "7.1", "7.1-home": self = .sevenOneHome
        case "7.1-scrn", "7.1-screen": self = .sevenOneScreen
        case "5.1+2": self = .fiveOnePlusTwo
        default: throw DolbyEError.invalidArgument("input layout must be auto, 5.1, 5.1.2, 7.1, 7.1-scrn or 5.1+2")
        }
    }
}

public enum DolbyEOutputFormat: String, Codable, Sendable {
    /// 48 kHz two-channel, packed 24-bit WAVE carrier; Dolby E occupies 20 significant bits.
    case pcm
    case mxfOP1A = "mxf-op1a"
    case mxfOPAtom = "mxf-opatom"

    public init(argument: String) throws {
        switch argument.lowercased() {
        case "pcm", "wav", "wave": self = .pcm
        case "mxf", "mxf-op1a", "op-1a": self = .mxfOP1A
        case "mxf-opatom", "op-atom": self = .mxfOPAtom
        default: throw DolbyEError.invalidArgument("format must be pcm, mxf-op1a or mxf-opatom")
        }
    }
}

public enum DolbyEDecodeSelection: String, Codable, Sendable {
    case all, main, stereo
}

public enum DolbyEDownmixMode: String, Codable, Sendable {
    case ltrt, loro
}

public enum DolbyEFrameRate: String, CaseIterable, Codable, Sendable {
    case fps23976 = "24000/1001"
    case fps24 = "24"
    case fps25 = "25"
    case fps2997 = "30000/1001"
    case fps30 = "30"

    public init(argument: String) throws {
        switch argument {
        case "23.98", "23.976", "24000/1001": self = .fps23976
        case "24": self = .fps24
        case "25": self = .fps25
        case "29.97", "30000/1001": self = .fps2997
        case "30": self = .fps30
        default: throw DolbyEError.invalidArgument("frame rate must be 24000/1001, 24, 25, 30000/1001 or 30")
        }
    }

    public var referenceCode: Int {
        switch self {
        case .fps23976: 1
        case .fps24: 2
        case .fps25: 3
        case .fps2997: 4
        case .fps30: 5
        }
    }

    public var numerator: Int64 {
        switch self {
        case .fps23976: 24000
        case .fps24: 24
        case .fps25: 25
        case .fps2997: 30000
        case .fps30: 30
        }
    }

    public var denominator: Int64 {
        switch self {
        case .fps23976, .fps2997: 1001
        default: 1
        }
    }
}

/// 48 kHz carrier placement relative to the associated video-frame boundary.
/// RDD 33 Tables 4/5 specify the acceptable reference position and total null
/// interval. Physical output hosts must preserve the edit-unit video epoch;
/// packed carrier words do not include AES3 channel-status or parity bits.
public struct DolbyECarrierTiming: Sendable {
    public let frameRate: DolbyEFrameRate
    public var referenceOffsetFrames: Int {
        switch frameRate { case .fps23976, .fps24: 47; case .fps25: 35; case .fps2997, .fps30: 33 }
    }
    public var guardBandFrames: Int {
        switch frameRate { case .fps23976, .fps24: 100; case .fps25: 96; case .fps2997, .fps30: 80 }
    }
    public init(frameRate: DolbyEFrameRate) { self.frameRate = frameRate }

    /// Capacity excludes all four preamble words. Fractional cadence uses the
    /// actual edit-unit length, rather than rounding every frame to 1602.
    public func maximumPayloadWords(carrierFrames: Int) throws -> Int {
        let minimum = Int(48000 * frameRate.denominator / frameRate.numerator)
        let maximum = Int((48000 * frameRate.denominator + frameRate.numerator - 1) / frameRate.numerator)
        guard (minimum...maximum).contains(carrierFrames) else {
            throw DolbyEError.invalidArgument("carrier length does not match its video cadence")
        }
        return (carrierFrames - guardBandFrames) * 2 - 4
    }
}

/// Exact rational PCM cadence, with bounded state and no floating-point drift.
/// Burst placement and guard-band length are separate codec operations.
public struct DolbyEFrameClock: Sendable {
    public let rate: DolbyEFrameRate
    public private(set) var frameIndex: Int64 = 0
    public private(set) var samplePosition: Int64 = 0
    private var remainder: Int64 = 0

    public init(rate: DolbyEFrameRate) { self.rate = rate }

    public mutating func nextSampleCount() throws -> Int {
        let scaledSamples = 48000 * rate.denominator
        let accumulated = scaledSamples + remainder
        let count = accumulated / rate.numerator
        let next = samplePosition.addingReportingOverflow(count)
        guard !next.overflow, frameIndex < Int64.max else {
            throw DolbyEError.invalidArgument("frame clock overflow")
        }
        remainder = accumulated % rate.numerator
        samplePosition = next.partialValue
        frameIndex += 1
        return Int(count)
    }
}

public struct DolbyERequest: Sendable {
    public var inputURL: URL
    public var outputURL: URL
    public var format: DolbyEOutputFormat
    public var program: DolbyEProgram
    public var frameRate: DolbyEFrameRate?
    public var inputLayout: DolbyEInputLayout
    public var ac3Metadata: [DolbyEAC3Metadata]?
    public var decodeSelection: DolbyEDecodeSelection
    public var downmixMode: DolbyEDownmixMode
    public var encodeVision: DolbyEEncodeVision
    public var dialogueSource: DolbyEDialogueSource
    public var secondaryInputURL: URL?
    /// Performance policy only:0 chooses a bounded automatic budget;1 is serial.
    /// It is deliberately excluded from the encoded format/recovery signature.
    public var maximumParallelism: Int
    /// Optional explicit programme measurement/normalization. Nil preserves the
    /// existing PCM and recovery profile; normalization is never implicit.
    /// Encoder-only. Decoder requests reject this option explicitly.
    public var loudness: DolbyEOfflineLoudnessConfiguration?
    /// Explicit speaker rendering for ED2 file exports. Nil retains the
    /// established Main5.1.2, Stereo2 or raw sixteen-signal export contract.
    public var decodeLayout: DolbyEPlaybackLayout?

    public init(inputURL: URL, outputURL: URL, format: DolbyEOutputFormat = .pcm,
                program: DolbyEProgram = .fiveOnePlusTwo, frameRate: DolbyEFrameRate? = nil,
                inputLayout: DolbyEInputLayout = .automatic, ac3Metadata: [DolbyEAC3Metadata]? = nil,
                decodeSelection: DolbyEDecodeSelection = .all, downmixMode: DolbyEDownmixMode = .ltrt,
                encodeVision: DolbyEEncodeVision = .e, dialogueSource: DolbyEDialogueSource = .none,
                secondaryInputURL: URL? = nil, decodeLayout: DolbyEPlaybackLayout? = nil,maximumParallelism: Int = 0,
                loudness: DolbyEOfflineLoudnessConfiguration? = nil) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.format = format
        self.program = program
        self.frameRate = frameRate
        self.inputLayout = inputLayout
        self.ac3Metadata = ac3Metadata
        self.decodeSelection = decodeSelection
        self.downmixMode = downmixMode
        self.encodeVision = encodeVision
        self.dialogueSource = dialogueSource
        self.secondaryInputURL = secondaryInputURL
        self.decodeLayout = decodeLayout
        self.maximumParallelism = maximumParallelism
        self.loudness = loudness
    }
}
