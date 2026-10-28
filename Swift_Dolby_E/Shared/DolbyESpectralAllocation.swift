// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyESpectralAllocation {
    public static let longBandSizes = [
        1,1,1,1,1,1,1,1,2,2,2,2,2,3,3,3,3,4,4,5,5,6,6,7,8,
        9,9,10,12,13,14,16,18,19,22,24,27,29,32,36,40,44,49,54,60,66,74,82,90,100,
    ]

    /// Computes the spreading/masking model for one long block. All math
    /// stays in integer log units so encoder and decoder derive identical widths.
    public static func masking(exponents: [Int], lfe: Bool, rate: DolbyEFrameRate)
        throws -> (energy: [Int], mask: [Int]) {
        try masking(exponents: exponents, bandKind: lfe ? 21 : 50, rate: rate,
                    fastSpectrum: 0, fastOffset: 3, model: 0, highPrecision: true)
    }

    public static func masking(exponents: [Int], bandKind: Int, rate: DolbyEFrameRate,
                                fastSpectrum: Int, fastOffset: Int, model: Int, highPrecision: Bool)
        throws -> (energy: [Int], mask: [Int]) {
        let count = exponents.count
        guard [21, 38, 44, 50].contains(bandKind), (max(1, bandKind - 7)...bandKind).contains(count),
              exponents.allSatisfy({ (0...49).contains($0) }), (0...3).contains(fastSpectrum),
              (0...7).contains(fastOffset), (0...1).contains(model) else {
            throw DolbyEError.invalidArgument("spectral masking parameters")
        }
        let kind = bandKind == 38 ? 0 : (bandKind == 44 ? 1 : 2)
        let rateIndex = rate.referenceCode - 1
        let rateClass = rateIndex < 2 ? 0 : (rateIndex == 2 ? 1 : 2)
        let slowGroup = rateIndex >= 3 ? 1 : 0
        let variant = (kind * 2 + slowGroup) * 2 + model
        let gain = DolbyEMaskingTables.value(0x10285c68, fastOffset)
        let forwardDecay = DolbyEMaskingTables.value(0x10286a98, slowGroup * 2 + model)
        let backwardDecay = DolbyEMaskingTables.value(0x10286abc, variant)
        let curve = 0x10285698 + 248 * (kind * 2 + slowGroup)
            + 4 * DolbyEMaskingTables.value(0x10285668, kind * 4 + fastSpectrum)
        let decay = 0x10285c88 + 200 * variant
        let secondCurve = 0x102865e8 + 400 * kind + 200 * model
        let floor = 0x10284f60 + 600 * kind + 200 * rateClass
        let energy = exponents.map { (48 - $0) * 64 }
        var mask = [Int](repeating: 0, count: count)
        func addLog(_ a: Int, _ b: Int) -> Int {
            max(a, b) + DolbyEMaskingTables.value(0x10286af0, min(abs(a - b) >> 1, 211))
        }
        var firstState = 0
        var secondState = 0
        for band in 0..<count {
            firstState = addLog(energy[band] + DolbyEMaskingTables.value(curve, band) - gain,
                                firstState - DolbyEMaskingTables.value(decay, band))
            secondState = addLog(energy[band] - DolbyEMaskingTables.value(secondCurve, band),
                                 secondState - forwardDecay)
            mask[band] = max(firstState, secondState)
        }
        var backwardState = 0
        let backwardStart = DolbyEMaskingTables.value(0x10286aa8, kind)
        let backwardGain = highPrecision ? gain : DolbyEMaskingTables.value(0x10286ab4, model)
        if count - 1 > backwardStart {
            for band in stride(from: count - 1, through: backwardStart + 1, by: -1) {
                backwardState = addLog(energy[band] - backwardGain, backwardState - backwardDecay)
                mask[band] = max(mask[band], backwardState)
            }
        }
        for band in 0..<count { mask[band] = max(mask[band], DolbyEMaskingTables.value(floor, band)) }
        if bandKind == 38 {
            var correction = [Int](repeating: 0, count: 17)
            for region in 0..<11 {
                let upper = region + 3
                let lower = max(0, upper - 6)
                let weights = 0x10286f40 + region * 7 * 4
                var maximumBand = lower
                var maximum = mask[lower] + DolbyEMaskingTables.value(weights)
                var combined = maximum
                if lower < upper {
                    for band in (lower + 1)...upper {
                        let value = mask[band] + DolbyEMaskingTables.value(weights, band - lower)
                        if value > maximum { maximum = value; maximumBand = band }
                        combined = addLog(combined, value)
                    }
                }
                if mask[region] < combined {
                    let first = max(0, maximumBand - 3)
                    let last = maximumBand + 3
                    let curve = maximumBand < 3 ? 0x10287080 - maximumBand * 4 : 0x10287074
                    for band in first...last {
                        correction[band] += DolbyEMaskingTables.value(curve, band - first)
                    }
                }
            }
            for band in 0..<16 { mask[band] = max(0, mask[band] + max(-512, correction[band])) }
        }
        return (energy, mask)
    }

    public static func bitWidths(energy: [Int], mask: [Int], threshold: Int) throws -> [Int] {
        guard energy.count == mask.count, energy.count <= 50, (0...255).contains(threshold) else {
            throw DolbyEError.invalidArgument("bit-allocation dimensions or threshold")
        }
        if threshold == 0 { return Array(repeating: 0, count: energy.count) }
        return zip(energy, mask).map { level, floor in
            let index = min(63, max(0, (16 * (threshold - 64) + level - floor) >> 5))
            let code = DolbyEMaskingTables.value(0x10286e40, index)
            return code == 0 ? 0 : code + 1
        }
    }
}
