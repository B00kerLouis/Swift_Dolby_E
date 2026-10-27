// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Owns DC rejection, LFE filtering, overlap history and frame meter integration
/// for one channel. Call with alternating first/second halves of 896 samples.
public struct DolbyEChannelAnalysis: Codable, Sendable {
    public let lfe: Bool
    private var history = [Double](repeating: 0, count: 448)
    private var previousInput = 0.0
    private var previousOutput = 0.0
    private var filters = Array(repeating: [Double](repeating: 0, count: 4), count: 4)
    private var energy = 0.0
    private var peak = 0.0

    public init(lfe: Bool) { self.lfe = lfe }

    public mutating func prepare(_ input: [Double], secondHalf: Bool)
        throws -> (samples: [Double], meters: (peak: UInt16, rms: UInt16)?) {
        guard isValidState, input.count == 896, input.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("channel analysis requires 896 finite samples")
        }
        var filtered = [Double](repeating: 0, count: 896)
        for (index, sample) in input.enumerated() {
            let value = sample * 0.49997711181641 - previousOutput * -0.99990844726563
                + previousInput * -0.49997711181641
            filtered[index] = value
            previousInput = sample
            previousOutput = value
        }
        if lfe {
            for stage in 0..<4 {
                let c = Self.lowPass[stage]
                for index in 0..<filtered.count {
                    let inputSample = filtered[index]
                    let twice = filters[stage][2] * c[3]
                    let value = filters[stage][0] * c[0] * -2 - filters[stage][1] * c[1]
                        + inputSample * c[2] + twice + twice + filters[stage][3] * c[4]
                    filters[stage][3] = filters[stage][2]
                    filters[stage][2] = inputSample
                    filters[stage][1] = filters[stage][0]
                    filters[stage][0] = value
                    filtered[index] = value
                }
            }
        }
        var samples = history + filtered
        history = Array(samples[896..<1344])
        if lfe { samples = Array(samples[80..<1232]) }
        if !secondHalf { energy = 0; peak = 0 }
        let range = secondHalf ? 448..<(lfe ? 1088 : 896) : 0..<(lfe ? 1152 : 1344)
        for index in range {
            let magnitude = min(abs(samples[index]) * 2, 0.9999999899999999)
            peak = max(peak, magnitude)
            energy += magnitude * magnitude * Double(bitPattern: 0x3f42492492492492)
        }
        for stage in 0..<4 {
            for state in 0..<4 where abs(filters[stage][state]) < 1e-10 { filters[stage][state] = 0 }
        }
        if abs(previousInput) < 1e-10 { previousInput = 0 }
        if abs(previousOutput) < 1e-10 { previousOutput = 0 }
        guard samples.allSatisfy(\.isFinite), energy.isFinite else { throw DolbyEError.malformed("channel analysis overflow") }
        let meters: (peak: UInt16, rms: UInt16)? = secondHalf
            ? (try DolbyEMeterCoding.code(amplitude: peak * 0.5), try DolbyEMeterCoding.code(amplitude: sqrt(energy) * 0.5))
            : nil
        return (samples, meters)
    }

    var isValidState: Bool {
        history.count == 448 && history.allSatisfy(\.isFinite) && filters.count == 4
            && filters.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite) }
            && previousInput.isFinite && previousOutput.isFinite && energy.isFinite && peak.isFinite
    }

    private static let lowPass: [[Double]] = [
        [-0.94664097262804, 0.89658908894326, 0.013225294014, -0.01157172217042, 0.01322529401404],
        [-0.96077051994467, 0.92614995126833, 0.13147994112744, -0.12917548540762, 0.1314799410668],
        [-0.97721406188832, 0.96040654124388, 0.34480841459818, -0.34181920626658, 0.34480841540222],
        [-0.99058611568151, 0.98791591534736, 0.50590449764959, -0.50253297448059, 0.50590449670177],
    ]
}
