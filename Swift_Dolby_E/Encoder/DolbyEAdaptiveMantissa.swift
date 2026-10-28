// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Inverts the primary and escape quantizers. The selected
/// refinement changes the actual bit cost, so allocation includes every escape.
enum DolbyEAdaptiveMantissa {
    struct Token: Sendable {
        let primary: UInt32
        let escape: UInt32?
        let reconstructed: Double
    }
    struct Band: Sendable {
        let precision: Int
        let width: Int
        let escapeWidth: Int
        let tokens: [Token]
        let bits: Int
        let error: Double
    }
    struct Selection: Sendable {
        let threshold: Int
        let spectrum: Int
        let offset: Int
        let model: Int
        let bands: [Band]
        let bits: Int
        let error: Double
        var refined: Bool { bands.contains { $0.precision != 0 } }
    }

    struct Quantizer: Sendable {
        let width: Int,precision: Int,minimum: Int,limit: Int,escapedWidth: Int
        let step: Double,scale: Double,offset: Double,escapedScale: Double,escapedStep: Double
        let mask: UInt32
        init(baseWidth: Int,precision: Int) {
            self.precision = precision
            guard baseWidth != 0 else {
                width = 0;minimum = 0;limit = 0;escapedWidth = 0;step = 0;scale = 0
                offset = 0;escapedScale = 0;escapedStep = 0;mask = 0;return
            }
            let index = (baseWidth-1)*4+precision,w = DolbyEMantissaCodingTables.width[index]
            width = w;step = 2.0/Double(1<<w);limit = (1<<(w-1))-1
            scale = precision == 0 ? 1:DolbyEMantissaCodingTables.scale[w*4+precision]
            minimum = precision == 0 ? -(1<<(w-1)) : (1-(1<<(w-1)))
            mask = UInt32((1<<w)-1)
            if precision == 0 { escapedWidth = 0;offset = 0;escapedScale = 0;escapedStep = 0 }
            else {
                let ew = DolbyEMantissaCodingTables.escapeWidth[index]
                escapedWidth = ew;offset = DolbyEMantissaCodingTables.escapeOffset[ew*4+precision]
                escapedScale = DolbyEMantissaCodingTables.escapeScale[precision];escapedStep = 2.0/Double(1<<ew)
            }
        }
        @inline(__always) func apply(_ value: Double) -> Token {
        if width == 0 { return Token(primary:0,escape:nil,reconstructed:0) }
        let bounded = max(-2, min(2, value))
        let integer = scale == 0 ? 0 : max(minimum, min(limit, Int((bounded / (step * scale)).rounded())))
        let primary = UInt32(bitPattern: Int32(integer)) & mask
        let main = Token(primary: primary, escape: nil, reconstructed: Double(integer) * step * scale)
        guard precision != 0 else { return main }
        let maximum = (1 << (escapedWidth - 1)) - 1
        let raw = max(0, min(maximum, Int(((abs(bounded) - offset) / (escapedScale * escapedStep)).rounded())))
        let magnitude = offset + Double(raw) * escapedStep * escapedScale
        let restored = value < 0 ? -magnitude : magnitude
        guard abs(restored - value) < abs(main.reconstructed - value) else { return main }
        let code = value < 0 ? UInt32(raw) ^ UInt32((1 << escapedWidth) - 1) : UInt32(raw)
        return Token(primary: UInt32(1 << (width - 1)), escape: code, reconstructed: restored)
        }
    }
    static func quantize(_ value: Double,baseWidth: Int,precision: Int) -> Token {
        Quantizer(baseWidth:baseWidth,precision:precision).apply(value)
    }

    struct Planner: Sendable {
        let coefficients: [Double]
        let normalized: [Double]
        let exponents: [Int]
        let sizes: [Int]
        let starts: [Int]
        struct Cost: Sendable { let bits: Int;let error: Double;let refined: Bool }
        struct Options: Sendable { let bands: [Band];let costs: [Cost];let minimumBits: Int }
        var cache: [Int: Options] = [:]
        struct Mask: Sendable { let energy: [Int];let mask: [Int] }
        var masks: [Int:Mask] = [:]
        var widthCache: [Int:[Int]] = [:]
        init(coefficients: [Double], spectrum: DolbyEEncodedSpectrum, sizes: [Int]) {
            self.coefficients = coefficients; self.normalized = spectrum.normalized
            self.exponents = spectrum.exponents; self.sizes = sizes
            var cursor = 0, starts: [Int] = []
            for size in sizes { starts.append(cursor); cursor += size }
            self.starts = starts
        }
        mutating func options(band: Int, baseWidth: Int) -> [Band] {
            plans(band:band,baseWidth:baseWidth).bands
        }
        mutating func plans(band: Int,baseWidth: Int) -> Options {
            let key = band * 17 + baseWidth
            if let saved = cache[key] { return saved }
            let exponent = exponents[band]
            let scale = (exponent & 1 == 0 ? 1.0 : 0.70710678116) * pow(0.5, Double(exponent / 2))
            var choices: [Band] = [];choices.reserveCapacity(4)
            for precision in 0..<(baseWidth == 0 ? 1 : 4) {
                let index = max(0, (baseWidth - 1) * 4 + precision)
                let width = baseWidth == 0 ? 0 : DolbyEMantissaCodingTables.width[index]
                let escaped = baseWidth == 0 ? 0 : DolbyEMantissaCodingTables.escapeWidth[index]
                var tokens: [Token] = [], bits = 0, error = 0.0
                tokens.reserveCapacity(sizes[band])
                let quantizer = Quantizer(baseWidth:baseWidth,precision:precision)
                for at in starts[band]..<(starts[band] + sizes[band]) {
                    let token = quantizer.apply(normalized[at])
                    tokens.append(token); bits += width + (token.escape == nil ? 0 : escaped)
                    let delta = coefficients[at] - token.reconstructed * scale
                    error += delta * delta
                }
                choices.append(Band(precision: precision, width: width, escapeWidth: escaped, tokens: tokens, bits: bits, error: error))
            }
            let result = Options(bands:choices,costs:choices.map { Cost(bits:$0.bits,error:$0.error,refined:$0.precision != 0) },minimumBits:choices.reduce(Int.max) { min($0,$1.bits) })
            cache[key] = result
            return result
        }
        mutating func choose(rate: DolbyEFrameRate, kind: Int, budget: Int, preserving prior: Selection? = nil) throws -> Selection {
            var best = prior.flatMap { $0.bits <= budget ? $0 : nil }
            var visitedBasic: Set<[Int]> = [], visitedRefined: Set<[Int]> = []
            let header = 22 + sizes.count * 2
            let initialPrice = max(1e-30,coefficients.reduce(0) { $0+$1*$1 }*1e-12)
            if coefficients.allSatisfy({ $0 == 0 }) {
                let plans = sizes.indices.map { options(band: $0, baseWidth: 0)[0] }
                return Selection(threshold: 0, spectrum: 0, offset: 3, model: 0, bands: plans, bits: 16, error: 0)
            }
            for spectrum in 0..<4 {
                for model in 0..<2 {
                  for offset in 0..<8 {
                    let maskKey = (rate.referenceCode*64+kind)*64+spectrum*16+model*8+offset
                    let masking: Mask
                    if let saved = masks[maskKey] { masking = saved }
                    else {
                        let value = try DolbyESpectralAllocation.masking(exponents:exponents,bandKind:kind,rate:rate,
                            fastSpectrum:spectrum,fastOffset:offset,model:model,highPrecision:true)
                        masking = Mask(energy:value.energy,mask:value.mask);masks[maskKey] = masking
                    }
                    func widths(_ threshold: Int) throws -> [Int] {
                        let key = maskKey*256+threshold
                        if let saved = widthCache[key] { return saved }
                        let value = try DolbyESpectralAllocation.bitWidths(energy:masking.energy,mask:masking.mask,threshold:threshold)
                        widthCache[key] = value;return value
                    }
                    var basicLow = 0, basicHigh = 256
                    while basicHigh - basicLow > 1 {
                        let middle = (basicLow + basicHigh) / 2
                        let bits = zip(sizes, try widths(middle)).reduce(16) { $0 + $1.0 * $1.1 }
                        if bits <= budget { basicLow = middle } else { basicHigh = middle }
                    }
                    let basicWidths = try widths(basicLow)
                    if visitedBasic.insert(basicWidths).inserted {
                        var basicPlans: [Band] = [];basicPlans.reserveCapacity(sizes.count)
                        for band in sizes.indices { basicPlans.append(options(band: band, baseWidth: basicWidths[band])[0]) }
                        let basic = Selection(threshold: basicLow, spectrum: spectrum, offset: offset, model: model, bands: basicPlans,
                            bits: basicPlans.reduce(16) { $0 + $1.bits }, error: basicPlans.reduce(0) { $0 + $1.error })
                        if best == nil || basic.error < best!.error { best = basic }
                    }
                    var low = 0, high = 256
                    while high - low > 1 {
                        let mid = (low + high) / 2
                        let base = try widths(mid)
                        var cost = header
                        for band in sizes.indices { cost += plans(band:band,baseWidth:base[band]).minimumBits }
                        if cost <= budget { low = mid } else { high = mid }
                    }
                    for threshold in max(0, low - 3)...low {
                        let base = try widths(threshold)
                        guard visitedRefined.insert(base).inserted else { continue }
                        var choices: [[Band]] = [],costs: [[Cost]] = []
                        choices.reserveCapacity(sizes.count);costs.reserveCapacity(sizes.count)
                        for band in sizes.indices {
                            let values = plans(band:band,baseWidth:base[band])
                            choices.append(values.bands);costs.append(values.costs)
                        }
                        // Price search touches only scalar costs. Copying full
                        // Bands here repeatedly retains their token arrays and
                        // causes contention between otherwise independent lanes.
                        func choice(_ list: [Cost], _ price: Double) -> Int {
                            var index = 0, score = list[0].error + price * Double(list[0].bits)
                            for at in 1..<list.count {
                                let next = list[at].error + price * Double(list[at].bits)
                                if next < score || (next == score && list[at].bits < list[index].bits) {
                                    index = at; score = next
                                }
                            }
                            return index
                        }
                        func metrics(_ price: Double) -> (bits: Int, error: Double) {
                            var bits = 0, error = 0.0, refined = false
                            for list in costs {
                                let index = choice(list, price)
                                bits += list[index].bits; error += list[index].error
                                refined = refined || list[index].refined
                            }
                            return (bits + (refined ? header : 16),error)
                        }
                        func selected(_ price: Double) -> Selection {
                            let plans = choices.indices.map { choices[$0][choice(costs[$0],price)] }
                            let refined = plans.contains { $0.precision != 0 }
                            return Selection(threshold: threshold, spectrum: spectrum, offset: offset, model: model, bands: plans,
                                bits: plans.reduce(refined ? header : 16) { $0 + $1.bits }, error: plans.reduce(0) { $0 + $1.error })
                        }
                        // Bracket the *bit-price* scale first. A fixed number
                        // of bisections from full signal energy never reaches
                        // the much smaller quantization-error-per-bit scale.
                        var a = 0.0, b = initialPrice
                        while metrics(b).bits > budget { a = b; b *= 4 }
                        for _ in 0..<18 {
                            let price = (a + b) / 2, candidate = metrics(price)
                            if candidate.bits <= budget {
                                if best == nil || candidate.error < best!.error { best = selected(price) }
                                b = price
                            } else { a = price }
                        }
                        let cheapest = metrics(b)
                        if cheapest.bits <= budget, best == nil || cheapest.error < best!.error { best = selected(b) }
                    }
                  }
                }
            }
            guard let best, best.error.isFinite else { throw DolbyEError.invalidArgument("mantissa allocation cannot fit finite spectrum") }
            return best
        }
    }
}
