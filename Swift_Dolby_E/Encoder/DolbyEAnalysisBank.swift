// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// The eight analysis window and transition configurations.
public enum DolbyEAnalysisBlock: Int, CaseIterable, Sendable {
    case shortStart = 0
    case shortToLongStart = 1
    case longStart = 2
    case lfeLongStart = 3
    case shortContinue = 4
    case longToShort = 5
    case longContinue = 6
    case lfeLongContinue = 7
}

public enum DolbyEAnalysisBank {
    /// Input contains the retained overlap followed by the current channel samples.
    /// Output is the 1024-slot spectral buffer, with short blocks placed at their
    /// configured offsets. LFE band truncation belongs to exponent/bit allocation.
    public static func analyze(_ samples: [Double], block: DolbyEAnalysisBlock) throws -> [Double] {
        guard (1152...1344).contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("analysis bank requires 1152...1344 finite channel samples")
        }
        var output = [Double](repeating: 0, count: 1024)
        for plan in DolbyEAnalysisTables.plans[block.rawValue] {
            var windowed = [Double](repeating: 0, count: plan.inputCount)
            for index in 0..<plan.windowCount {
                let coefficient = DolbyEAnalysisTables.window[plan.windowOffset + plan.windowStep * index]
                windowed[plan.leadingZeros + index] = -(coefficient * samples[plan.sourceOffset + index])
            }
            var folded = [Double](repeating: 0, count: plan.outputCount)
            for pair in 0..<(plan.outputCount / 2) {
                let source = pair * 2 + plan.foldOffset
                let difference = pair < plan.differencePairs
                let mirror = (difference ? 0 : plan.inputCount) + plan.foldOffset - pair * 2 - 1
                folded[plan.outputCount - pair * 2 - 1] = difference
                    ? windowed[source] - windowed[mirror] : windowed[source] + windowed[mirror]
                folded[plan.outputCount - pair * 2 - 2] = difference
                    ? windowed[source + 1] - windowed[mirror - 1] : windowed[source + 1] + windowed[mirror - 1]
            }
            let scale = 2.0 / Double(plan.outputCount)
            let transformed = try DolbyECosineTransform.unscaled(folded[...])
            for bin in 0..<plan.outputCount {
                output[plan.outputOffset + bin] = transformed[bin] * scale
            }
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.invalidArgument("analysis bank overflow") }
        return output
    }
}
