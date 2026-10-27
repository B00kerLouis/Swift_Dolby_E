// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Stateful complete carrier-frame-to-48-kHz PCM decoding. Corrupt sections fail
/// explicitly; there is no silence or canned-audio concealment path.
public struct DolbyEPCMFrameDecoder: Codable, Sendable {
    public let program: DolbyEProgram
    public let frameRate: DolbyEFrameRate
    private var channels: [DolbyEChannelSynthesis]
    private var resampler: DolbyESynthesisResampler

    public init(program: DolbyEProgram, frameRate: DolbyEFrameRate, startingAtFrame: UInt64 = 0) throws {
        self.program = program
        self.frameRate = frameRate
        self.channels = (0..<8).map { DolbyEChannelSynthesis(lfe: $0 == program.lfeChannel) }
        self.resampler = try DolbyESynthesisResampler(channelCount: 8, frameRate: frameRate, startingAtFrame: startingAtFrame)
    }

    public mutating func decode(_ frame: DolbyECarrierFrame) throws -> [Double] {
        guard channels.count == 8, channels.enumerated().allSatisfy({ $0.element.isValidState && $0.element.lfe == ($0.offset == program.lfeChannel) }),
              resampler.channelCount == 8, resampler.frameRate == frameRate,
              frame.program == program, frame.frameRate == frameRate else {
            throw DolbyEError.invalidArgument("frame program or cadence changed within a decoder stream")
        }
        let order = [0, 2, 4, 6, 1, 3, 5, 7]
        var output: [Double] = []
        for half in 0..<2 {
            var coded = [Double](repeating: 0, count: 896 * 8)
            for (wire, channel) in order.enumerated() {
                let spectrum = try DolbyEAudioSegmentDecoder.decode(words: frame.audioSegments[half * 8 + wire],
                    lfe: channel == program.lfeChannel, secondHalf: half == 1, rate: frameRate, highPrecision: frame.versions[wire] != 0)
                let windowed = try DolbyESynthesisBank.synthesize(spectrum.coefficients, blockType: spectrum.blockType)
                let values = try channels[channel].render(windowed, secondHalf: half == 1, frameNumber: frame.frameNumber,
                    firstGain: frame.firstGains[wire], secondGain: frame.secondGains[wire])
                for index in 0..<896 { coded[index * 8 + channel] = values[index] }
            }
            output += try resampler.convert(coded)
        }
        return output
    }
}
