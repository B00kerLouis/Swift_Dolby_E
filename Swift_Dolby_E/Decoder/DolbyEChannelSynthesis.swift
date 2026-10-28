// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyEChannelSynthesis: Codable, Sendable {
    public let lfe: Bool
    private var overlap = [Double](repeating: 0, count: 256)
    private var filters = Array(repeating: [Double](repeating: 0, count: 4), count: 3)
    private var previousCounter: UInt16 = 0
    private var gain = 0.0
    private var increment = 0.0

    public init(lfe: Bool) { self.lfe = lfe }

    public mutating func render(_ samples: [Double], secondHalf: Bool, frameNumber: UInt16,
                               firstGain: UInt16 = 960, secondGain: UInt16 = 960) throws -> [Double] {
        guard isValidState, samples.count == 1152, samples.allSatisfy(\.isFinite), firstGain < 1024, secondGain < 1024 else {
            throw DolbyEError.invalidArgument("synthesis sample count or gain code")
        }
        func linear(_ code: UInt16) -> Double {
            if code == 0 { return 0 }
            return DolbyESynthesisGains.linear[Int(code & 63)] * pow(0.5, Double(15 - Int((code >> 6) & 15)))
        }
        func clipped(_ value: Double) -> Double { max(-1, min(0.9999999899999999, value)) }
        let oldGain = gain
        // Sign-extend the current 16-bit counter and zero-extend the saved
        // counter before adding one, including the high-counter crossfade path.
        let continuous = secondHalf || Int(Int16(bitPattern: frameNumber)) == Int(previousCounter) + 1
        if !secondHalf {
            gain = linear(firstGain)
            increment = (linear(secondGain) - gain) * Double(bitPattern: 0x3f42492492492492)
            previousCounter = frameNumber
        }
        var output = [Double](repeating: 0, count: 896)
        for index in 0..<896 {
            if index >= 256 {
                output[index] = clipped(samples[index] * gain * 4)
            } else if continuous {
                output[index] = clipped((samples[index] + overlap[index]) * gain * 4)
            } else {
                let previous = oldGain * overlap[index] * DolbyESynthesisGains.fade[255 - index]
                let current = gain * samples[index] * DolbyESynthesisGains.fade[index]
                output[index] = clipped((current + previous) * 32)
            }
            gain += increment
        }
        overlap = Array(samples[896..<1152])
        if lfe {
            for stage in 0..<3 {
                let c = Self.lowPass[stage]
                for index in 0..<output.count {
                    let input = output[index]
                    let twice = filters[stage][2] * c[3]
                    let value = filters[stage][0] * c[0] * -2 - filters[stage][1] * c[1]
                        + input * c[2] + twice + twice + filters[stage][3] * c[4]
                    filters[stage][3] = filters[stage][2]
                    filters[stage][2] = input
                    filters[stage][1] = filters[stage][0]
                    filters[stage][0] = value
                    output[index] = value
                }
            }
            for stage in 0..<3 {
                for state in 0..<4 where abs(filters[stage][state]) < 1e-10 { filters[stage][state] = 0 }
            }
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("synthesis channel overflow") }
        return output
    }

    var isValidState: Bool {
        overlap.count == 256 && overlap.allSatisfy(\.isFinite) && filters.count == 3
            && filters.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite) }
            && gain.isFinite && increment.isFinite
    }

    private static let lowPass: [[Double]] = [
        [-0.92574021754536, 0.85831356385062, 0.04712148159151, -0.04370491721156, 0.0471214815915],
        [-0.96052366187786, 0.92854845154636, 0.33323123811939, -0.32948067422453, 0.3332312381203],
        [-0.98634650434182, 0.9806239781871, 0.58802185753162, -0.58405682919497, 0.58802185753011],
    ]
}
