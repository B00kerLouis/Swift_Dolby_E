// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyECompressionProfile: String, Codable, CaseIterable, Sendable {
    case none, filmStandard = "film-standard", filmLight = "film-light"
    case musicStandard = "music-standard", musicLight = "music-light", speech
    public var code: UInt8 { UInt8(Self.allCases.firstIndex(of: self)!) }
    public init?(argument: String) {
        let key = argument.lowercased().filter { $0.isLetter || $0.isNumber }
        guard let value = Self.allCases.first(where: { $0.rawValue.filter { $0.isLetter || $0.isNumber } == key }) else { return nil }
        self = value
    }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .filmStandard: "Film Standard"
        case .filmLight: "Film Light"
        case .musicStandard: "Music Standard"
        case .musicLight: "Music Light"
        case .speech: "Speech"
        }
    }
}

/// Instructions for the downstream AC-3 encoder, carried with each Dolby E
/// program. AC-3's target bitrate and DRC profiles do not change Dolby E's
/// transport bitrate or apply a second AC-3 preprocessing pass to its PCM.
public struct DolbyEAC3Metadata: Codable, Equatable, Sendable {
    public var bitRateKbps = 384
    public var serviceMode = 0
    public var audioCodingMode = 7
    public var lfe = true
    public var dolbySurroundMode = 0
    public var dialogueLevel = -24
    public var productionInformation = true
    public var mixingLevel = 105
    /// 0: unspecified, 1: large room, 2: small room.
    public var roomType = 1
    public var copyright = true
    public var originalBitstream = true
    /// 0: unspecified, 1: Lt/Rt, 2: Lo/Ro.
    public var preferredDownmix = 1
    /// Extended mix codes: +3, +1.5, 0, -1.5, -3, -4.5, -6 dB, mute.
    public var ltRtCenterLevel = 4
    public var ltRtSurroundLevel = 6
    public var loRoCenterLevel = 4
    public var loRoSurroundLevel = 6
    public var extendedBitstreamInformation: UInt16 = 0
    public var highPassFilter = true
    public var bandwidthLowPassFilter = true
    public var lfeLowPassFilter = true
    public var surroundPhase90 = true
    public var surroundAttenuation = false
    public var rfPreEmphasis = false
    public var rfProfile: DolbyECompressionProfile = .filmStandard
    public var lineProfile: DolbyECompressionProfile = .filmStandard

    public init() {}
    public static func defaults(program: DolbyEProgram, index: Int) -> Self {
        var value = Self()
        if program == .eightMono {
            value.bitRateKbps = 192; value.audioCodingMode = 1; value.lfe = false
            value.surroundPhase90 = false; value.lfeLowPassFilter = false; value.preferredDownmix = 0
        }
        if program == .fiveOnePlusTwo && index == 1 {
            value.bitRateKbps = 192; value.audioCodingMode = 2; value.lfe = false
            value.dolbySurroundMode = 0; value.productionInformation = false
            value.mixingLevel = 80; value.roomType = 0
            value.preferredDownmix = 0; value.ltRtSurroundLevel = 4; value.loRoSurroundLevel = 4
        }
        return value
    }
    public func validate() throws {
        guard Self.bitrates.contains(bitRateKbps), (0...7).contains(serviceMode), (0...7).contains(audioCodingMode),
              (0...3).contains(dolbySurroundMode), (-31 ... -1).contains(dialogueLevel),
              (80...111).contains(mixingLevel), (0...2).contains(roomType), (0...2).contains(preferredDownmix),
              [ltRtCenterLevel, ltRtSurroundLevel, loRoCenterLevel, loRoSurroundLevel].allSatisfy({ (0...7).contains($0) }),
              extendedBitstreamInformation < 16384 else { throw DolbyEError.invalidArgument("invalid AC-3 program metadata") }
    }
    public static let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    public var bitRateCode: UInt8 { UInt8(Self.bitrates.firstIndex(of: bitRateKbps) ?? 31) }
    var referenceWords: [UInt16] {
        let mode = serviceMode << 10 | audioCodingMode << 7 | dolbySurroundMode << 1 | (lfe ? 1 : 0)
        let production = (productionInformation ? 512 : 0) | (mixingLevel - 80) << 4 | roomType << 2
            | (copyright ? 2 : 0) | (originalBitstream ? 1 : 0)
        let mix = preferredDownmix << 12 | ltRtCenterLevel << 9 | ltRtSurroundLevel << 6 | loRoCenterLevel << 3 | loRoSurroundLevel
        let filters = (highPassFilter ? 16384 : 0) | (bandwidthLowPassFilter ? 8192 : 0)
            | (lfeLowPassFilter ? 4096 : 0) | (surroundPhase90 ? 2048 : 0) | (surroundAttenuation ? 1024 : 0)
            | (rfPreEmphasis ? 512 : 0) | Int(rfProfile.code)
        return [UInt16(mode), UInt16(-dialogueLevel << 9), UInt16(production), UInt16(mix),
                extendedBitstreamInformation, UInt16(filters), UInt16(lineProfile.code)]
    }
}

/// Wire fields retain raw DRC words and profile codes even when values
/// fall outside the public encoder presets.
public struct DolbyEAC3ProgramInfo: Codable, Sendable {
    public let bitRateCode: UInt8
    public let serviceMode: UInt8
    public let audioCodingMode: UInt8
    public let centerMixLevel: UInt8
    public let surroundMixLevel: UInt8
    public let dolbySurroundMode: UInt8
    public let lfe: Bool
    public let dialogueLevel: Int
    public let languagePresent: Bool
    public let languageCode: UInt8
    public let productionInformation: Bool
    public let mixingLevel: Int
    public let roomType: UInt8
    public let copyright: Bool
    public let originalBitstream: Bool
    public let extendedMixPresent: Bool
    public let extendedMix: UInt16
    public let extendedBitstreamPresent: Bool
    public let extendedBitstream: UInt16
    public let highPassFilter: Bool
    public let bandwidthLowPassFilter: Bool
    public let lfeLowPassFilter: Bool
    public let surroundPhase90: Bool
    public let surroundAttenuation: Bool
    public let rfPreEmphasis: Bool
    public let rfIsGainWord: Bool
    public let rfCode: UInt8
    public let lineIsGainWord: Bool
    public let lineCodes: [UInt8]
    public var bitRateKbps: Int? { Int(bitRateCode) < DolbyEAC3Metadata.bitrates.count ? DolbyEAC3Metadata.bitrates[Int(bitRateCode)] : nil }
}
