// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyESynthesisResampler: Sendable {
    public let channelCount: Int
    public let frameRate: DolbyEFrameRate
    private let interpolation: Int
    private let decimation: Int
    private let coefficients: [Double]
    private let ringMask: Int
    private var ring: [[Double]]
    private var ringPosition = 0
    private var phase = 0

    public init(channelCount: Int, frameRate: DolbyEFrameRate, startingAtFrame: UInt64 = 0) throws {
        guard (1...8).contains(channelCount) else { throw DolbyEError.invalidArgument("synthesis sample-rate channel count") }
        let profile = DolbyEDecodingRateTables.profiles[frameRate.referenceCode - 1]
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
        let input = startingAtFrame.multipliedReportingOverflow(by: 1792)
        guard !input.overflow else { throw DolbyEError.invalidArgument("resampler frame clock overflow") }
        // Recover the rational clock independently of sample history. The
        // following real pre-roll supplies the FIR ring and synthesis overlap.
        let remainder = Int(input.partialValue % UInt64(profile.decimation)) * profile.interpolation % profile.decimation
        self.phase = remainder == 0 ? 0 : profile.decimation - remainder
        self.ringPosition = Int(input.partialValue & UInt64(capacity - 1))
    }

    public static func samplePosition(beforeFrame frame: UInt64, frameRate: DolbyEFrameRate) throws -> UInt64 {
        let p = DolbyEDecodingRateTables.profiles[frameRate.referenceCode - 1]
        let input = frame.multipliedReportingOverflow(by: UInt64(1792 * p.interpolation))
        guard !input.overflow, input.partialValue <= UInt64.max - UInt64(p.decimation - 1) else {
            throw DolbyEError.invalidArgument("resampler sample clock overflow")
        }
        return (input.partialValue + UInt64(p.decimation - 1)) / UInt64(p.decimation)
    }

    public mutating func convert(_ input: [Double]) throws -> [Double] {
        guard input.count == 896 * channelCount || input.count == 1792 * channelCount,
              input.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("inverse sample-rate conversion requires complete 896-sample channel blocks")
        }
        let frames = input.count / channelCount
        let channels = channelCount
        var consumed = 0
        func insert(_ position: Int, into ring: inout [[Double]], at index: Int) {
            for channel in 0..<channels { ring[channel][index] = input[position * channels + channel] }
        }
        while phase >= interpolation {
            phase -= interpolation
            ringPosition = (ringPosition + 1) & ringMask
            insert(consumed, into: &ring, at: ringPosition)
            consumed += 1
        }
        var output: [Double] = []
        output.reserveCapacity((frames * interpolation / decimation + 2) * channelCount)
        repeat {
            for channel in 0..<channelCount {
                var tap = phase
                var position = ringPosition
                var value = 0.0
                while tap < coefficients.count {
                    value += ring[channel][position] * coefficients[tap]
                    position = (position - 1) & ringMask
                    tap += interpolation
                }
                output.append(value)
            }
            phase += decimation
            while phase >= interpolation && consumed < frames {
                phase -= interpolation
                ringPosition = (ringPosition + 1) & ringMask
                insert(consumed, into: &ring, at: ringPosition)
                consumed += 1
            }
        } while consumed < frames
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("inverse sample-rate overflow") }
        return output
    }
}


extension DolbyESynthesisResampler: Codable {
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
              (0...ringMask).contains(position), (0..<(interpolation + decimation)).contains(phase) else {
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
