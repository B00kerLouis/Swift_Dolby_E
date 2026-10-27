// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyESynthesisBank {
    /// Inverse cosine transform, signed unfolding and synthesis-window accumulation
    /// for every short/long transition configuration. Overlap is applied by the channel state.
    public static func synthesize(_ coefficients: [Double], blockType: Int) throws -> [Double] {
        guard coefficients.count == 1024, coefficients.allSatisfy(\.isFinite), (0..<8).contains(blockType) else {
            throw DolbyEError.invalidArgument("synthesis requires 1024 finite coefficients and a valid block type")
        }
        var output = [Double](repeating: 0, count: 1152)
        for plan in DolbyESynthesisTables.plans[blockType] {
            let folded = try DolbyECosineTransform.inverse(coefficients[plan.source..<(plan.source + plan.bins)])
            var raw = [Double](repeating: 0, count: plan.count)
            for pair in 0..<(plan.bins / 2) {
                let source = pair * 2 + plan.foldOffset
                let difference = pair < plan.differences
                let mirror = (difference ? 0 : plan.count) + plan.foldOffset - pair * 2 - 1
                let first = folded[plan.bins - pair * 2 - 1]
                let second = folded[plan.bins - pair * 2 - 2]
                raw[source] = first
                raw[mirror] = difference ? -first : first
                raw[source + 1] = second
                raw[mirror - 1] = difference ? -second : second
            }
            for index in 0..<plan.windowCount {
                output[plan.destination + index] -= raw[plan.windowLead + index]
                    * DolbyESynthesisTables.window[plan.windowOffset + index * plan.windowStep]
            }
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("inverse transform overflow") }
        return output
    }
}
