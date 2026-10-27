// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyEEncodedSpectrum: Sendable {
    public let exponents: [Int]
    public let normalized: [Double]
    public let groups: [Int]
}

/// Long-block audio payload coding. Uses real spectral coefficients and a
/// decoder-reproducible masking allocation and content-selected adaptive mantissas.
public enum DolbyEAudioSegment {
    public static func normalize(_ coefficients: [Double], lfe: Bool, rate: DolbyEFrameRate = .fps25) throws -> DolbyEEncodedSpectrum {
        guard coefficients.count == 1024, coefficients.allSatisfy(\.isFinite) else {
            throw DolbyEError.invalidArgument("spectral buffer requires 1024 finite coefficients")
        }
        let count = lfe ? 21 : (rate.referenceCode > 3 ? 49 : 50)
        let bands = Array(DolbyESpectralAllocation.longBandSizes.prefix(count))
        var exponents: [Int] = []
        var cursor = 0
        for size in bands {
            var magnitude = coefficients[cursor..<(cursor + size)].map(abs).max() ?? 0
            var exponent = 48
            if magnitude != 0 {
                var halvings = 0
                while magnitude < 0.5 && halvings < 24 { magnitude *= 2; halvings += 1 }
                exponent = halvings * 2
                if exponent < 48 && magnitude < 0.70710678116 { exponent += 1 }
            }
            exponents.append(exponent)
            cursor += size
        }
        let groupCounts = lfe ? [21] : [27, count - 27]
        var groups: [Int] = []
        cursor = 0
        for count in groupCounts {
            let minimum = exponents[cursor..<(cursor + count)].min() ?? 0
            let shift = min(3, minimum / 6)
            groups.append(shift)
            for band in cursor..<(cursor + count) { exponents[band] = min(exponents[band], shift * 6 + 31) }
            cursor += count
        }
        var normalized = coefficients
        cursor = 0
        for (band, size) in bands.enumerated() {
            let exponent = exponents[band]
            let multiplier = (exponent & 1 == 0 ? 1.0 : 1.41421356232) * pow(2, Double(exponent / 2))
            for index in cursor..<(cursor + size) { normalized[index] *= multiplier }
            cursor += size
        }
        return DolbyEEncodedSpectrum(exponents: exponents, normalized: normalized, groups: groups)
    }

    static func writeExponents(_ spectrum: DolbyEEncodedSpectrum, lfe: Bool, writer: inout DolbyEBitWriter) throws {
        for group in spectrum.groups { try writer.append(UInt32(group), bits: 2) }
        let counts = lfe ? [21] : [27, spectrum.exponents.count - 27]
        var band = 0
        for (group, count) in zip(spectrum.groups, counts) {
            for _ in 0..<count {
                try writer.append(UInt32(spectrum.exponents[band] - group * 6), bits: 5)
                band += 1
            }
        }
    }

    public static func encode(coefficients: [Double], lfe: Bool, rate: DolbyEFrameRate,
                              capacityWords: Int) throws -> [UInt32] {
        var prepared = try Prepared(coefficients: coefficients, lfe: lfe, rate: rate)
        try prepared.fit(capacityWords: capacityWords)
        return try prepared.words(capacityWords: capacityWords)
    }

    struct Prepared: Sendable {
        let spectrum: DolbyEEncodedSpectrum
        let lfe: Bool
        let rate: DolbyEFrameRate
        let prefixBits: Int
        var planner: DolbyEAdaptiveMantissa.Planner
        var selection: DolbyEAdaptiveMantissa.Selection?
        private var fittedCapacity: Int?
        init(coefficients: [Double], lfe: Bool, rate: DolbyEFrameRate) throws {
            spectrum = try normalize(coefficients, lfe: lfe, rate: rate)
            self.lfe = lfe; self.rate = rate
            prefixBits = (lfe ? 2 : 9) + spectrum.exponents.count * 5
            let bands = Array(DolbyESpectralAllocation.longBandSizes.prefix(spectrum.exponents.count))
            planner = DolbyEAdaptiveMantissa.Planner(coefficients: coefficients, spectrum: spectrum, sizes: bands)
        }
        mutating func fit(capacityWords: Int) throws {
            if fittedCapacity == capacityWords,selection != nil { return }
            selection = try planner.choose(rate: rate, kind: lfe ? 21 : 50,
                budget: capacityWords * 20 - prefixBits, preserving: selection)
            fittedCapacity = capacityWords
        }
        var usedWords: Int { (prefixBits + (selection?.bits ?? 0) + 19) / 20 }
        func words(capacityWords: Int) throws -> [UInt32] {
            guard let selection else { throw DolbyEError.malformed("unallocated audio spectrum") }
            var writer = try DolbyEBitWriter(capacityWords: capacityWords)
            if !lfe { try writer.append(0, bits: 2); try writer.append(rate.referenceCode > 3 ? 1 : 0, bits: 3) }
            try writeExponents(spectrum, lfe: lfe, writer: &writer)
            try writer.append(UInt32(selection.spectrum), bits: 2)
            try writer.append(UInt32(selection.offset), bits: 3)
            try writer.append(UInt32(selection.model), bits: 1)
            try writer.append(0, bits: 1)
            try writer.append(UInt32(selection.threshold), bits: 8)
            if selection.refined {
                try writer.append(1, bits: 1); try writer.append(0, bits: 6)
                for band in selection.bands { try writer.append(UInt32(band.precision), bits: 2) }
            } else { try writer.append(0, bits: 1) }
            for band in selection.bands where band.width > 0 {
                for token in band.tokens { try writer.append(token.primary, bits: band.width) }
                for token in band.tokens { if let escape = token.escape { try writer.append(escape, bits: band.escapeWidth) } }
            }
            return writer.finalizedWords()
        }
    }
}
