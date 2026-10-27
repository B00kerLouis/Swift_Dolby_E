// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Linked streaming4x true-peak protection with a continuous gain envelope.
/// A512-sample real preview supports10ms attack and100ms release without
/// delaying programme samples. Only bounded raw/gain history is checkpointed.
struct DolbyETruePeakLimiter: Codable, Sendable {
    let groups: [[Int]]
    let channelCount: Int
    static let ceiling = pow(10.0, -2.5 / 20) - 2 / 8388608
    static let previewFrames = 512
    static let attackFrames = 480
    static let releaseFrames = 4800
    private var rawHistory: [Double]
    private var lastGains: [Double]
    private var carried: [[Double]]
    private var started = false
    private var revision = 2

    // ITU-R BS.1770 polyphase detector coefficients, four phases / 12 taps.
    static let taps: [[Double]] = [
        [0.001708984375, 0.010986328125, -0.0196533203125, 0.033203125, -0.0594482421875, 0.1373291015625, 0.97216796875, -0.102294921875, 0.047607421875, -0.026611328125, 0.014892578125, -0.00830078125],
        [-0.0291748046875, 0.029296875, -0.0517578125, 0.089111328125, -0.16650390625, 0.465087890625, 0.77978515625, -0.2003173828125, 0.1015625, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625, -0.2003173828125, 0.77978515625, 0.465087890625, -0.16650390625, 0.089111328125, -0.0517578125, 0.029296875, -0.0291748046875],
        [-0.00830078125, 0.014892578125, -0.026611328125, 0.047607421875, -0.102294921875, 0.97216796875, 0.1373291015625, -0.0594482421875, 0.033203125, -0.0196533203125, 0.010986328125, 0.001708984375]
    ]
    init(groups: [[Int]], channelCount: Int = 8) throws {
        let channels = groups.flatMap { $0 }
        guard (1...16).contains(channelCount), groups.count <= 2, groups.allSatisfy({ !$0.isEmpty }), channels.allSatisfy({ (0..<channelCount).contains($0) }),
              Set(channels).count == channels.count else { throw DolbyEError.invalidArgument("invalid linked limiter groups") }
        self.groups = groups; self.channelCount = channelCount
        self.rawHistory = Array(repeating: 0, count: 11 * channelCount)
        self.lastGains = Array(repeating: 1, count: groups.count)
        self.carried = Array(repeating: Array(repeating: 1, count: 6), count: groups.count)
    }

    mutating func process(_ current: inout [Double], preview: inout [Double]) throws {
        let mapped = groups.flatMap { $0 }
        guard revision == 2, (1...16).contains(channelCount), current.count % channelCount == 0,
              (1...8192).contains(current.count / channelCount), preview.count == Self.previewFrames * channelCount,
              groups.count <= 2, groups.allSatisfy({ !$0.isEmpty }), mapped.allSatisfy({ (0..<channelCount).contains($0) }),
              Set(mapped).count == mapped.count, current.allSatisfy(\.isFinite), preview.allSatisfy(\.isFinite),
              rawHistory.count == 11 * channelCount, rawHistory.allSatisfy(\.isFinite),
              lastGains.count == groups.count, lastGains.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              carried.count == groups.count, carried.allSatisfy({ $0.count == 6 }) else {
            throw DolbyEError.malformed("invalid smooth true-peak limiter checkpoint or input")
        }
        if groups.isEmpty { return }
        let frames = current.count / channelCount
        let original = current, future = preview
        let data = rawHistory + original + future
        let count = frames + Self.previewFrames - 6
        var output = original, previewOutput = future
        var nextLast = lastGains, nextCarry = carried
        let attack = 1.0 / Double(Self.attackFrames), release = 1.0 / Double(Self.releaseFrames)

        for (groupIndex, channels) in groups.enumerated() {
            var targets = [Double](repeating: 1, count: count)
            // Bound actual interpolated peaks plus the maximum contribution
            // introduced by a time-varying gain. For a reference tap r:
            // |sum(c*x*g)| <= g[r]*|sum(c*x)| + maxSlope*sum(|c*x|*|tap-r|).
            // This retains phase cancellation without allowing abrupt gain
            // pulses. Extreme inputs fall back to a sign-separated bound.
            func constrain(window: Int, reference: Int, target: Int) throws {
                for coefficients in Self.taps {
                    for channel in channels {
                        var value = 0.0, variation = 0.0, positive = 0.0, negative = 0.0
                        for tap in 0..<12 {
                            let contribution = coefficients[tap] * data[(window + tap) * channelCount + channel]
                            value += contribution
                            variation += abs(contribution) * Double(abs(tap - reference))
                            if contribution >= 0 { positive += contribution } else { negative -= contribution }
                        }
                        guard value.isFinite, variation.isFinite, positive.isFinite, negative.isFinite else {
                            throw DolbyEError.malformed("true-peak detector overflow")
                        }
                        let margin = attack * variation
                        if margin < Self.ceiling {
                            if value != 0 { targets[target] = min(targets[target], max(0, (Self.ceiling - margin) / abs(value))) }
                        } else {
                            let bound = max(positive, negative)
                            let gain = bound > 0 ? min(1, Self.ceiling / bound) : 1
                            for tap in 0..<12 {
                                let sample = window + tap - 11
                                if targets.indices.contains(sample) { targets[sample] = min(targets[sample], gain) }
                            }
                        }
                    }
                }
            }
            for sample in 0..<count {
                for channel in channels {
                    let peak = abs(data[(11 + sample) * channelCount + channel])
                    if peak > Self.ceiling { targets[sample] = min(targets[sample], Self.ceiling / peak) }
                }
                try constrain(window: sample + 6, reference: 5, target: sample)
            }
            if !started {
                // Startup windows include the zero history but can still
                // reconstruct a peak ahead of the first emitted sample.
                for window in 0..<6 { try constrain(window: window, reference: 11 - window, target: 0) }
            }
            // Backward attack and forward release form a deterministic
            // slope-limited upper envelope.512 real preview samples cover
            // the480-sample attack and all12detector taps without audio delay.
            if count > 1 {
                for sample in stride(from: count - 2, through: 0, by: -1) {
                    targets[sample] = min(targets[sample], targets[sample + 1] + attack)
                }
            }
            var gain = lastGains[groupIndex]
            for sample in 0..<(frames + 6) {
                let next = min(1, targets[sample], gain + release)
                if started || sample > 0 {
                    guard gain - next <= attack + 1e-9 else {
                        throw DolbyEError.malformed("limiter look-ahead cannot preserve its attack envelope")
                    }
                }
                if started, sample < 6 {
                    guard abs(next - carried[groupIndex][sample]) < 1e-8 else {
                        throw DolbyEError.malformed("limiter preview does not match the next source samples")
                    }
                }
                gain = next
                if sample < frames {
                    for channel in channels { output[sample * channelCount + channel] *= gain }
                    if sample == frames - 1 { nextLast[groupIndex] = gain }
                } else {
                    nextCarry[groupIndex][sample - frames] = gain
                    for channel in channels { previewOutput[(sample - frames) * channelCount + channel] *= gain }
                }
            }
        }
        rawHistory = Array((rawHistory + original).suffix(11 * channelCount))
        lastGains = nextLast; carried = nextCarry; started = true
        current = output; preview = previewOutput
    }

    static func measuredPeak(_ pcm: [Double], channels: [Int], channelCount: Int = 8) -> Double {
        let frames = pcm.count / channelCount
        let data = Array(repeating: 0.0, count: 6 * channelCount) + pcm + Array(repeating: 0.0, count: 12 * channelCount)
        var peak = channels.flatMap { channel in stride(from: channel, to: pcm.count, by: channelCount).map { abs(pcm[$0]) } }.max() ?? 0
        for center in 0..<(frames + 6) {
            for coefficients in taps {
                for channel in channels {
                    var value = 0.0
                    for tap in 0..<12 { value += coefficients[tap] * data[(center + tap) * channelCount + channel] }
                    peak = max(peak, abs(value))
                }
            }
        }
        return peak
    }
}
