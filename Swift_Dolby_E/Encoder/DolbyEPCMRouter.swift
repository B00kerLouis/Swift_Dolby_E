// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Routes discrete PCM by speaker semantics. Home stereo uses the reference
/// Lo/Ro center/surround levels and its two-phase all-pass output network.
public struct DolbyEPCMRouter: Codable, Sendable {
    public let layout: DolbyEInputLayout
    public let program: DolbyEProgram
    public let channelCount: Int
    public let downmixMode: DolbyEDownmixMode
    private let surroundIsBack: Bool
    private var filters = Array(repeating: [Float](repeating: 0, count: 8), count: 2)
    private var parity = 0

    public init(info: WavePCMInfo, layout requested: DolbyEInputLayout, program: DolbyEProgram, downmixMode: DolbyEDownmixMode = .loro) throws {
        guard requested != .fiveOneTwo else { throw DolbyEError.invalidArgument("5.1.2 imports use --encode-vision ed2") }
        guard info.sampleRate == 48000, [6, 8].contains(info.channelCount) else {
            throw DolbyEError.unsupported("PCM import must be 48 kHz 5.1 or 7.1")
        }
        guard program != .eightMono || info.channelCount == 8 else { throw DolbyEError.invalidArgument("8x1 requires eight discrete signals") }
        let layout: DolbyEInputLayout
        if requested == .automatic {
            guard info.channelMask == 0 || (info.channelCount == 6 && [0x3f, 0x60f].contains(info.channelMask))
                    || (info.channelCount == 8 && [0x63f, 0xff].contains(info.channelMask)) else {
                throw DolbyEError.unsupported("speaker mask is not a discrete 5.1/7.1 layout")
            }
            if info.channelCount == 6 { layout = .fiveOne }
            else if info.channelMask == 0xff { layout = .sevenOneScreen }
            else { layout = .sevenOneHome }
        } else { layout = requested }
        guard (layout == .fiveOne && info.channelCount == 6)
                || (layout != .fiveOne && layout != .automatic && info.channelCount == 8) else {
            throw DolbyEError.invalidArgument("channel count does not match the selected input layout")
        }
        guard layout != .fiveOnePlusTwo || program == .fiveOnePlusTwo else {
            throw DolbyEError.invalidArgument("a separate stereo program is not a Screen front pair")
        }
        self.layout = layout
        self.program = program
        self.channelCount = info.channelCount
        self.downmixMode = downmixMode
        self.surroundIsBack = info.channelMask & 0x30 != 0 && info.channelCount == 6
    }

    public mutating func route(_ pcm: [Float]) throws -> [Double] {
        guard [6, 8].contains(channelCount), layout != .automatic,
              (layout == .fiveOne ? channelCount == 6 : channelCount == 8),
              filters.count == 2, filters.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isFinite) }),
              (0...1).contains(parity), pcm.count % channelCount == 0,
              pcm.count <= 8192 * channelCount, pcm.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("invalid discrete PCM routing block")
        }
        let frames = pcm.count / channelCount
        var result = [Double](repeating: 0, count: frames * 8)
        let rootHalf = Float(1 / sqrt(2.0))
        for frame in 0..<frames {
            let input = frame * channelCount
            let output = frame * 8
            if program == .eightMono || layout == .fiveOnePlusTwo || (layout == .sevenOneScreen && program == .sevenOneScreen) {
                for channel in 0..<8 { result[output + channel] = Double(pcm[input + channel]) }
                continue
            }
            var left = pcm[input], right = pcm[input + 1], center = pcm[input + 2]
            let lfe = pcm[input + 3]
            var surroundLeft = pcm[input + 4], surroundRight = pcm[input + 5]
            var stereoLeft: Float
            var stereoRight: Float
            var surroundStereoLeft: Float
            var surroundStereoRight: Float
            switch layout {
            case .sevenOneHome:
                surroundLeft = (pcm[input + 4] + pcm[input + 6]) * rootHalf
                surroundRight = (pcm[input + 5] + pcm[input + 7]) * rootHalf
                stereoLeft = left + center * 0.70800775; stereoRight = right + center * 0.70800775
                surroundStereoLeft = pcm[input + 4] * 0.5012322 + pcm[input + 6] * 0.53108376
                surroundStereoRight = pcm[input + 5] * 0.5012322 + pcm[input + 7] * 0.53108376
            case .sevenOneScreen:
                left += pcm[input + 6] * rootHalf
                right += pcm[input + 7] * rootHalf
                center += (pcm[input + 6] + pcm[input + 7]) * rootHalf
                stereoLeft = left + center * 0.70800775; stereoRight = right + center * 0.70800775
                surroundStereoLeft = surroundLeft * 0.53108376; surroundStereoRight = surroundRight * 0.53108376
            default:
                let gain: Float = surroundIsBack ? 0.5012322 : 0.53108376
                stereoLeft = left + center * 0.70800775; stereoRight = right + center * 0.70800775
                surroundStereoLeft = surroundLeft * gain; surroundStereoRight = surroundRight * gain
            }
            let primary = [left, right, center, lfe, surroundLeft, surroundRight]
            for channel in 0..<6 { result[output + channel] = Double(primary[channel]) }
            if program == .fiveOnePlusTwo {
                if downmixMode == .loro {
                    stereoLeft += surroundStereoLeft; stereoRight += surroundStereoRight
                } else {
                    let surround = (surroundStereoLeft + surroundStereoRight) * rootHalf
                    stereoLeft -= surround; stereoRight += surround
                }
                stereoLeft = home(stereoLeft, channel: 0)
                stereoRight = home(stereoRight, channel: 1)
                result[output + 6] = Double(stereoLeft)
                result[output + 7] = Double(stereoRight)
                parity ^= 1
            }
        }
        guard result.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("PCM routing overflow") }
        return result
    }

    private mutating func home(_ input: Float, channel: Int) -> Float {
        let offset = parity * 4
        let a = Float(bitPattern: 0xbf158aae)
        let b = Float(bitPattern: 0xbd858444)
        let value = b * input + a * filters[channel][offset] + filters[channel][offset + 1]
            - a * filters[channel][offset + 2] - b * filters[channel][offset + 3]
        filters[channel][offset + 1] = filters[channel][offset]
        filters[channel][offset] = input
        filters[channel][offset + 3] = filters[channel][offset + 2]
        filters[channel][offset + 2] = value
        return value
    }
}
