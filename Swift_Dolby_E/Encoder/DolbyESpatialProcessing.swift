// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Nested all-pass network for the diffuse IAB bus. Delay storage and phase
/// belong to one stream and are included in its recoverable DSP checkpoint.
struct DolbyEDecorrelator: Codable, Sendable {
    private let outerGain: Double
    private let innerGain: Double
    private var outer: [Double]
    private var inner: [Double]
    private var a = 0
    private var b = 0
    init(channel: Int) {
        let sign = channel % 2 == 0 ? 1.0 : -1.0
        outerGain = Double(Float(0.32)) * sign; innerGain = Double(Float(0.10)) * sign
        outer = Array(repeating: 0, count: channel % 4 < 2 ? 107 : 73)
        inner = Array(repeating: 0, count: channel % 4 < 2 ? 29 : 41)
    }
    mutating func process(_ input: Double) throws -> Double {
        guard [73, 107].contains(outer.count), [29, 41].contains(inner.count),
              outer.indices.contains(a), inner.indices.contains(b), abs(outerGain) < 1, abs(innerGain) < 1 else {
            throw DolbyEError.malformed("invalid decorrelation checkpoint")
        }
        let delayedInner = inner[b]
        let nextInner = outer[a] + innerGain * delayedInner
        let nested = delayedInner - innerGain * nextInner
        inner[b] = nextInner; b = (b + 1) % inner.count
        let nextOuter = input + outerGain * nested
        let output = nested - outerGain * nextOuter
        outer[a] = nextOuter; a = (a + 1) % outer.count
        guard output.isFinite else { throw DolbyEError.malformed("decorrelation state overflow") }
        return output
    }
}

extension DolbyEAtmosRenderer {
    /// Numerical integration of a finite angular object, using equal solid-angle
    /// samples. The zero-spread path is the exact point graph; no random source,
    /// canned coefficient vector or ignored metadata is used for diffuse objects.
    func spatialGains(_ pan: DolbyEIABPan) throws -> [Double] {
        guard (0...1).contains(pan.spread), (0...1).contains(pan.decorrelation),
              pan.zones == nil || (pan.zones!.count == 9 && pan.zones!.allSatisfy({ $0.isFinite && (0...1).contains($0) })) else {
            throw DolbyEError.malformed("invalid IAB spatial parameters")
        }
        if let tolerance = pan.snap, tolerance > 0, pan.spread == 0 {
            let anchors: [(Double, Double, DolbyEAtmosBed)] = [(-1, 1, .left), (0, 1, .center), (1, 1, .right),
                (-1, -1, .leftSide), (1, -1, .rightSide)]
                + (program == .sevenOneScreen ? [(-0.5, 1, .leftExtra), (0.5, 1, .rightExtra)] : [])
            let nearest = anchors.min { lhs, rhs in
                pow(lhs.0 - pan.value.x, 2) + pow(lhs.1 - pan.value.y, 2) < pow(rhs.0 - pan.value.x, 2) + pow(rhs.1 - pan.value.y, 2)
            }!
            let distance = sqrt(pow(nearest.0 - pan.value.x, 2) + pow(nearest.1 - pan.value.y, 2) + pow(pan.value.z, 2)) / 2
            if distance <= tolerance { return gains(DolbyEAtmosValue(gain: pan.value.gain), bed: nearest.2, zones: pan.zones) }
        }
        if pan.spread == 0 { return gains(pan.value, bed: nil, zones: pan.zones) }
        let p = SIMD3<Double>(pan.value.x, pan.value.y, max(0, pan.value.z))
        let norm = sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
        let axis = norm > 1e-12 ? p / norm : SIMD3<Double>(0, 1, 0)
        let seed = abs(axis.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        var horizontal = cross(seed, axis)
        horizontal /= sqrt(horizontal.x * horizontal.x + horizontal.y * horizontal.y + horizontal.z * horizontal.z)
        let vertical = cross(axis, horizontal)
        let aperture = pan.spread < 0.5 ? pan.spread * .pi / 2 : (1.5 * pan.spread - 0.5) * .pi
        let minimumCosine = cos(aperture), goldenAngle = .pi * (3 - sqrt(5.0))
        // Match the point graph continuously as spread approaches zero for
        // interior room positions, including the generated2.0programme.
        let pointRadius = max(abs(p.x), abs(p.y), abs(p.z))
        let extentRadius = pointRadius + (1 - pointRadius) * pan.spread
        let count = 64
        var powers = [Double](repeating: 0, count: 8)
        var signed = [Double](repeating: 0, count: 8)
        for index in 0..<count {
            let cosine = 1 - (1 - minimumCosine) * (Double(index) + 0.5) / Double(count)
            let sine = sqrt(max(0, 1 - cosine * cosine)), angle = Double(index) * goldenAngle
            let direction = axis * cosine + (horizontal * cos(angle) + vertical * sin(angle)) * sine
            let radius = max(abs(direction.x), abs(direction.y), abs(direction.z), 1e-12)
            let point = DolbyEAtmosValue(x: direction.x / radius * extentRadius, y: direction.y / radius * extentRadius,
                z: max(0, direction.z / radius * extentRadius), gain: pan.value.gain)
            let weights = gains(point, bed: nil, zones: pan.zones)
            for channel in 0..<8 {
                powers[channel] += weights[channel] * weights[channel] / Double(count)
                signed[channel] += weights[channel] / Double(count)
            }
        }
        var result = powers.map(sqrt)
        if downmixMode == .ltrt, program == .fiveOnePlusTwo {
            // The phase matrix is signed. Taking an independent square root of
            // its two powers would erase Lt/Rt polarity for extended objects.
            let energy = signed[6] * signed[6] + signed[7] * signed[7]
            let scale = energy > 0 ? sqrt((powers[6] + powers[7]) / energy) : 0
            result[6] = signed[6] * scale; result[7] = signed[7] * scale
        }
        return result
    }
}
