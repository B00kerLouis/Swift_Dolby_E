// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyEDecodedSpectrum: Sendable {
    public let coefficients: [Double]
    public let blockType: Int
    public let consumedBits: Int
}

public enum DolbyEAudioSegmentDecoder {
    public static func decode(words: [UInt32], lfe: Bool, secondHalf: Bool, rate: DolbyEFrameRate,
                              highPrecision: Bool = true) throws -> DolbyEDecodedSpectrum {
        var reader = try DolbyEBitReader(words: words)
        let blockType: Int
        let bandwidth: Int
        if lfe {
            blockType = secondHalf ? 7 : 3
            bandwidth = 0
        } else {
            let family = Int(try reader.read(bits: 2))
            guard family < 3 else { throw DolbyEError.malformed("invalid transient block family") }
            blockType = [2, 0, 1][family] + (secondHalf ? 4 : 0)
            bandwidth = Int(try reader.read(bits: 3))
        }
        let kinds = DolbyECodecBands.kinds(blockType: blockType)
        let bands = kinds.map { Array(DolbyECodecBands.sizes(kind: $0).prefix($0 == 21 ? 21 : $0 - bandwidth)) }
        var exponents: [[Int]] = []
        for index in kinds.indices {
            let count = bands[index].count
            let new: Bool
            if index == 0 || bands[index - 1].count != count { new = true }
            else { new = try reader.read(bits: 1) != 0 }
            if new {
                let groups = DolbyECodecBands.groups(kind: kinds[index], bandwidth: bandwidth)
                var shifts: [Int] = []
                for _ in groups { shifts.append(Int(try reader.read(bits: 2)) * (highPrecision ? 6 : 3)) }
                var values: [Int] = []
                for (shift, length) in zip(shifts, groups) {
                    for _ in 0..<length { values.append(Int(try reader.read(bits: 5)) + shift) }
                }
                exponents.append(values)
            } else {
                exponents.append(exponents[index - 1])
            }
        }
        var parameters: [(spectrum: Int, offset: Int, model: Int)] = []
        for index in kinds.indices {
            let new: Bool
            if index == 0 { new = true }
            else { new = try reader.read(bits: 1) != 0 }
            if new {
                parameters.append((Int(try reader.read(bits: 2)), Int(try reader.read(bits: 3)), Int(try reader.read(bits: 1))))
            } else {
                parameters.append(parameters[index - 1])
            }
        }
        _ = try reader.read(bits: 1)
        let threshold = Int(try reader.read(bits: 8))
        var codes: [[Int]] = []
        for index in kinds.indices {
            let p = parameters[index]
            let model = try DolbyESpectralAllocation.masking(exponents: exponents[index], bandKind: kinds[index], rate: rate,
                fastSpectrum: p.spectrum, fastOffset: p.offset, model: p.model, highPrecision: highPrecision)
            let widths = try DolbyESpectralAllocation.bitWidths(energy: model.energy, mask: model.mask, threshold: threshold)
            codes.append(widths.map { $0 == 0 ? 0 : $0 - 1 })
        }
        var refinements: [[Int]] = []
        for index in kinds.indices {
            let count = bands[index].count
            if try reader.read(bits: 1) != 0 {
                let start = min(count, Int(try reader.read(bits: 6)))
                var values = [Int](repeating: 0, count: start)
                for _ in start..<count { values.append(Int(try reader.read(bits: 2))) }
                refinements.append(values)
            } else if index > 0, count == bands[index - 1].count {
                refinements.append(refinements[index - 1])
            } else {
                refinements.append(Array(repeating: 0, count: count))
            }
        }
        func q31(_ bits: Int, _ reader: inout DolbyEBitReader) throws -> UInt32 {
            if bits == 0 { return 0 }
            return try reader.read(bits: bits) << (32 - bits)
        }
        func value(_ aligned: UInt32) -> Double { Double(Int32(bitPattern: aligned)) / 2147483648.0 }
        var output = [Double](repeating: 0, count: 1024)
        var spectralOffset = 0
        for block in kinds.indices {
            var sample = spectralOffset
            for band in bands[block].indices {
                let count = bands[block][band]
                let precision = refinements[block][band]
                let index = codes[block][band] * 4 + precision
                let width = DolbyEMantissaTables.width[index]
                let escapeWidth = DolbyEMantissaTables.escapeWidth[index]
                var primary: [UInt32] = []
                for _ in 0..<count { primary.append(try q31(width, &reader)) }
                let exponent = exponents[block][band]
                let odd = exponent & 1 == 0 ? 1.0 : 0.70710678116
                let scale = pow(0.5, Double(exponent / 2))
                for primaryValue in primary {
                    var normalized = value(primaryValue)
                    if precision > 0 {
                        if primaryValue != 0x80000000 {
                            normalized *= DolbyEMantissaTables.scale[width * 4 + precision]
                        } else {
                            let escape = try q31(escapeWidth, &reader)
                            let negative = escape & 0x80000000 != 0
                            let raw = negative ? escape ^ (UInt32.max << (32 - escapeWidth)) : escape
                            normalized = value(raw) * DolbyEMantissaTables.escapeScale[precision]
                                + DolbyEMantissaTables.escapeOffset[escapeWidth * 4 + precision]
                            if negative { normalized = -normalized }
                        }
                    }
                    output[sample] = odd * normalized * scale
                    sample += 1
                }
            }
            spectralOffset += kinds[block] == 38 ? 128 : (kinds[block] == 44 ? 256 : 1024)
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("non-finite spectral reconstruction") }
        return DolbyEDecodedSpectrum(coefficients: output, blockType: blockType, consumedBits: reader.bitPosition)
    }
}
