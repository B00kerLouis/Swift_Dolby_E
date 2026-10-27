// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Accelerate

/// Fixed-size Double DCT-IV matrices evaluated by the native vector kernel.
/// Coefficients are immutable and initialized once; no stream state is shared.
/// The direct scalar formula remains available in the encoder's reference primitive.
enum DolbyECosineTransform {
    private struct Phases: Sendable {
        let preReal: [Double]
        let preImaginary: [Double]
        let postReal: [Double]
        let postImaginary: [Double]
        init(count: Int) {
            preReal = (0..<count).map { cos(.pi * (Double($0) + 0.5) / Double(2 * count)) }
            preImaginary = (0..<count).map { -sin(.pi * (Double($0) + 0.5) / Double(2 * count)) }
            postReal = (0..<count).map { cos(.pi * Double($0) / Double(2 * count)) }
            postImaginary = (0..<count).map { -sin(.pi * Double($0) / Double(2 * count)) }
        }
    }
    private static let phases128 = Phases(count: 128)
    private static let phases256 = Phases(count: 256)
    private static let phases1024 = Phases(count: 1024)

    /// Double-precision DCT-IV through a zero-padded complex FFT. Pre/post
    /// rotations include both half-sample offsets. No Float conversion, output
    /// scaling or shared mutable FFT/DSP state is introduced.
    static func inverse(_ input: ArraySlice<Double>) throws -> [Double] {
        let count = input.count
        let phases: Phases
        switch count {
        case 128: phases = phases128
        case 256: phases = phases256
        case 1024: phases = phases1024
        default: throw DolbyEError.invalidArgument("unsupported inverse cosine transform size")
        }
        let logarithm = vDSP_Length((2 * count).trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(logarithm, FFTRadix(kFFTRadix2)) else {
            throw DolbyEError.unsupported("inverse cosine FFT allocation")
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        var real = [Double](repeating: 0, count: count * 2)
        var imaginary = real
        for (index, value) in input.enumerated() {
            real[index] = value * phases.preReal[index]
            imaginary[index] = value * phases.preImaginary[index]
        }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, logarithm, FFTDirection(FFT_FORWARD))
            }
        }
        var output = [Double](repeating: 0, count: count)
        for index in 0..<count {
            output[index] = real[index] * phases.postReal[index] - imaginary[index] * phases.postImaginary[index]
        }
        return output
    }
    private static let short = matrix(count: 128)
    private static let medium = matrix(count: 256)
    private static let long = matrix(count: 1024)

    private static func matrix(count: Int) -> [Double] {
        var result = [Double](repeating: 0, count: count * count)
        for row in 0..<count {
            let frequency = Double.pi / Double(count) * (Double(row) + 0.5)
            for column in 0..<count {
                result[row * count + column] = cos(frequency * (Double(column) + 0.5))
            }
        }
        return result
    }

    static func unscaled(_ input: ArraySlice<Double>) throws -> [Double] {
        let count = input.count
        let matrix: [Double]
        switch count {
        case 128: matrix = short
        case 256: matrix = medium
        case 1024: matrix = long
        default: throw DolbyEError.invalidArgument("unsupported cosine transform size")
        }
        var result = [Double](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { coefficients in
            input.withUnsafeBufferPointer { source in
                result.withUnsafeMutableBufferPointer { destination in
                    vDSP_mmulD(coefficients.baseAddress!, 1, source.baseAddress!, 1,
                        destination.baseAddress!, 1, vDSP_Length(count), 1, vDSP_Length(count))
                }
            }
        }
        return result
    }
}
