// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Stateful polyphase conversion from 48 kHz PCM to the Dolby E analysis cadence.
/// The state is owned by one stream. No floating-point position accumulator is used.
public struct DolbyEResampler: Sendable {
    public let channelCount: Int
    public let frameRate: DolbyEFrameRate
    private let interpolation: Int
    private let decimation: Int
    private let coefficients: [Double]
    private let ringMask: Int
    private var ring: [[Double]]
    private var ringPosition = 0
    private var phase = 0

    public init(channelCount: Int, frameRate: DolbyEFrameRate) throws {
        guard (1...8).contains(channelCount) else { throw DolbyEError.invalidArgument("resampler channel count must be 1...8") }
        let profile = DolbyEResamplingTables.profiles[frameRate.referenceCode - 1]
        self.channelCount = channelCount
        self.frameRate = frameRate
        self.interpolation = profile.interpolation
        self.decimation = profile.decimation
        self.coefficients = profile.coefficients
        let depth = (profile.coefficients.count + profile.interpolation - 1) / profile.interpolation
        var capacity = 1
        while capacity < depth { capacity *= 2 }
        self.ringMask = capacity - 1
        self.ring = Array(repeating: Array(repeating: 0, count: capacity), count: channelCount)
    }

    public func requiredInputFrames(outputFrames: Int = 896) throws -> Int {
        guard (1...1792).contains(outputFrames) else { throw DolbyEError.invalidArgument("invalid resampler output block") }
        return (phase + outputFrames * decimation) / interpolation
    }

    public mutating func convert(_ interleaved: [Double], outputFrames: Int = 896) throws -> [Double] {
        let inputFrames = try requiredInputFrames(outputFrames: outputFrames)
        guard interleaved.count == inputFrames * channelCount, interleaved.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("resampler input length must match its current rational phase")
        }
        var output = [Double](repeating: 0, count: outputFrames * channelCount)
        var consumed = 0
        for frame in 0..<outputFrames {
            for channel in 0..<channelCount {
                var tap = phase
                var position = ringPosition
                var value = 0.0
                while tap < coefficients.count {
                    value += coefficients[tap] * ring[channel][position]
                    position = (position - 1) & ringMask
                    tap += interpolation
                }
                output[frame * channelCount + channel] = value
            }
            phase += decimation
            while phase >= interpolation {
                phase -= interpolation
                ringPosition = (ringPosition + 1) & ringMask
                for channel in 0..<channelCount { ring[channel][ringPosition] = interleaved[consumed * channelCount + channel] }
                consumed += 1
            }
        }
        guard consumed == inputFrames, output.allSatisfy(\.isFinite) else {
            throw DolbyEError.malformed("resampler phase or numeric overflow")
        }
        return output
    }
}


extension DolbyEResampler: Codable {
    private enum CodingKeys: String, CodingKey { case channelCount, frameRate, ring, ringPosition, phase }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let channels = try values.decode(Int.self, forKey: .channelCount)
        let rate = try values.decode(DolbyEFrameRate.self, forKey: .frameRate)
        try self.init(channelCount: channels, frameRate: rate)
        let history = try values.decode([[Double]].self, forKey: .ring)
        let position = try values.decode(Int.self, forKey: .ringPosition)
        let phase = try values.decode(Int.self, forKey: .phase)
        guard history.count == channels, history.allSatisfy({ $0.count == ringMask + 1 && $0.allSatisfy(\.isFinite) }),
              (0...ringMask).contains(position), (0..<(interpolation)).contains(phase) else {
            throw DolbyEError.malformed("invalid sample-rate checkpoint state")
        }
        self.ring = history
        self.ringPosition = position
        self.phase = phase
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(channelCount, forKey: .channelCount)
        try values.encode(frameRate, forKey: .frameRate)
        try values.encode(ring, forKey: .ring)
        try values.encode(ringPosition, forKey: .ringPosition)
        try values.encode(phase, forKey: .phase)
    }
}
