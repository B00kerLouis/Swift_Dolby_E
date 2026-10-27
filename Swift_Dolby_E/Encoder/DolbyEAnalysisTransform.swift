// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Scalar reference implementation of the recovered unshifted cosine-analysis primitive.
/// Verified sizes are 256 and 2048 input samples. This is one stage of the codec;
/// transition windows, overlapping state and transient block selection belong to its caller.
public enum DolbyEAnalysisTransform {
    public static func coefficients(for samples: [Double]) throws -> [Double] {
        guard [256, 2048].contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("analysis primitive requires 256 or 2048 finite Double samples")
        }
        let count = samples.count / 2
        var folded = [Double](repeating: 0, count: count)
        for index in 0..<count {
            folded[index] = samples[count - 1 - index] + samples[count + index]
        }
        guard folded.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("analysis fold overflow")
        }
        let scale = 2.0 / Double(count)
        var result = [Double](repeating: 0, count: count)
        // Keep the direct formula as the auditable CPU baseline. Replacing it with
        // FFT/vector acceleration requires matching the retained reference vectors.
        for coefficient in 0..<count {
            let frequency = Double.pi / Double(count) * (Double(coefficient) + 0.5)
            var sum = 0.0
            for index in 0..<count {
                sum += folded[index] * cos(frequency * (Double(index) + 0.5))
            }
            result[coefficient] = sum * scale
        }
        guard result.allSatisfy(\.isFinite) else { throw DolbyEError.invalidArgument("analysis sum overflow") }
        return result
    }
}
