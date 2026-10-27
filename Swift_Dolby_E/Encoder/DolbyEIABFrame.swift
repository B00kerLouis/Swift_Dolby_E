// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct DolbyEIABBits {
    let data: Data
    var position = 0
    var remaining: Int { data.count * 8 - position }
    mutating func take(_ count: Int) throws -> UInt32 {
        guard (0...32).contains(count), count <= remaining else { throw DolbyEError.malformed("truncated IAB bit field at \(position)") }
        var result: UInt32 = 0
        for _ in 0..<count { result = result << 1 | UInt32((data[position / 8] >> (7 - position % 8)) & 1); position += 1 }
        return result
    }
    mutating func plex(_ base: Int = 8) throws -> UInt32 {
        for width in [base, base * 2, base * 4, base * 8] where width <= 32 {
            let value = try take(width)
            if value != (width == 32 ? UInt32.max : (1 << width) - 1) { return value }
        }
        throw DolbyEError.malformed("IAB Plex integer exceeds 32 bits")
    }
    mutating func align() throws { if position % 8 != 0 { _ = try take(8 - position % 8) } }
    mutating func bytes(_ count: Int) throws -> Data {
        guard position % 8 == 0, count >= 0, count <= remaining / 8 else { throw DolbyEError.malformed("truncated or unaligned IAB byte range") }
        let start = position / 8; position += count * 8
        return Data(data[start..<(start + count)])
    }
    mutating func element() throws -> (UInt32, Data) {
        guard position % 8 == 0 else { throw DolbyEError.malformed("unaligned IAB element") }
        let id = try plex(), size = try plex()
        guard size > 0 else { throw DolbyEError.malformed("empty IAB element") }
        return (id, try bytes(Int(size)))
    }
    mutating func finish() throws {
        guard remaining <= 7 else { throw DolbyEError.malformed("unconsumed IAB element bytes") }
        if remaining > 0, try take(remaining) != 0 { throw DolbyEError.malformed("nonzero IAB padding") }
    }
    mutating func description() throws {
        if try take(8) & 128 != 0 { while try take(8) != 0 {} }
    }
    mutating func gain(zone: Bool = false) throws -> Double {
        switch try take(2) {
        case 0: return zone ? 0 : 1
        case 1: return zone ? 1 : 0
        case 2:
            let code = try take(10)
            return code == 1023 ? 0 : pow(2, -Double(code) / 64)
        default: throw DolbyEError.malformed("reserved IAB gain prefix")
        }
    }
    mutating func decorrelation() throws -> Double {
        switch try take(2) {
        case 0: return 0
        case 1: return 1
        case 2: return Double(try take(8)) / 255
        default: throw DolbyEError.malformed("reserved IAB decorrelation prefix")
        }
    }
}

struct DolbyEIABPan: Hashable {
    let value: DolbyEAtmosValue
    let spread: Double
    let snap: Double?
    let zones: [Double]?
    let decorrelation: Double
}
struct DolbyEIABRenderable {
    let id: String
    let audioID: UInt32
    let bed: DolbyEAtmosBed?
    let gain: Double
    let pans: [DolbyEIABPan]
}
struct DolbyEIABFrame {
    let samples: Int
    let rateCode: Int
    let assets: [UInt32: [Float]]
    let renderables: [DolbyEIABRenderable]

    static let sampleCounts = [2000, 1920, 1600, 1000, 960, 800, 500, 480, 400, 2002]
    static func header(_ data: Data) throws -> (samples: Int, rate: Int, bits: Int, is96k: Bool) {
        guard data.count >= 2, data[0] == 1 else { throw DolbyEError.unsupported("IAB bitstream version") }
        let rate = Int(data[1] & 15), sampleCode = data[1] >> 6, bits = (data[1] >> 4) & 3
        guard sampleCode <= 1, bits <= 1, rate < sampleCounts.count else { throw DolbyEError.malformed("reserved IAB audio/frame format") }
        return (sampleCounts[rate], rate, bits == 0 ? 16 : 24, sampleCode == 1)
    }
    static func parse(_ data: Data, program: DolbyEProgram) throws -> DolbyEIABFrame {
        var outer = DolbyEIABBits(data: data)
        let (id, payload) = try outer.element()
        guard id == 8 else { throw DolbyEError.malformed("IAB IAFrame element ID") }
        try outer.finish()
        let format = try header(payload)
        var bits = DolbyEIABBits(data: payload)
        _ = try bits.take(16)
        let rendered = try bits.plex(), count = try bits.plex()
        guard rendered <= 512, count <= 4096 else { throw DolbyEError.malformed("IAB renderable/element count exceeds bound") }
        var assets: [UInt32: [Float]] = [:], renderables: [DolbyEIABRenderable] = []
        for _ in 0..<count {
            let (id, payload) = try bits.element()
            switch id {
            case 0x200, 0x400:
                var audio = DolbyEIABBits(data: payload)
                let audioID = try audio.plex()
                guard audioID != 0, assets[audioID] == nil, assets.count < 512 else { throw DolbyEError.malformed("duplicate, zero or excessive IAB AudioDataID") }
                if id == 0x200 { assets[audioID] = try decodeDLC(&audio, format: format) }
                else {
                    try audio.align()
                    let encodedCount = format.samples * (format.is96k ? 2 : 1)
                    guard audio.remaining == encodedCount * format.bits else { throw DolbyEError.malformed("IAB PCM sample count differs from frame") }
                    let bytes = try audio.bytes(audio.remaining / 8), width = format.bits / 8
                    var samples = [Float](); samples.reserveCapacity(format.samples)
                    guard !format.is96k else { throw DolbyEError.unsupported("96 kHz IAB AudioDataPCM requires source-rate conversion; use a 48 kHz master") }
                    for offset in stride(from: 0, to: bytes.count, by: width) {
                        let raw = UInt32(try bytes.integer(at: offset, bytes: width)) << (32 - format.bits)
                        samples.append(Float(Int32(bitPattern: raw)) / Float(Int32.max))
                    }
                    assets[audioID] = samples
                }
            case 0x10: renderables += try parseBed(payload, rate: format.rate, program: program, depth: 0)
            case 0x40: renderables += try parseObject(payload, rate: format.rate, program: program, depth: 0)
            case 0x100, 0x101: break // Authoring and user data contain no audio.
            default: throw DolbyEError.unsupported("IAB root element 0x\(String(id, radix: 16))")
            }
        }
        try bits.finish()
        guard renderables.count <= 512 else { throw DolbyEError.malformed("too many IAB rendered sources") }
        for item in renderables where item.audioID != 0 {
            guard assets[item.audioID]?.count == format.samples else { throw DolbyEError.malformed("IAB source references missing audio asset \(item.audioID)") }
        }
        return DolbyEIABFrame(samples: format.samples, rateCode: format.rate, assets: assets, renderables: renderables)
    }
    static func subblocks(_ rate: Int) -> Int { rate <= 2 || rate == 9 ? 8 : (rate <= 5 ? 4 : 2) }
    var blockRanges: [Range<Int>] {
        let lengths = rateCode == 9 ? [251, 250, 250, 250, 251, 250, 250, 250] : Array(repeating: samples / Self.subblocks(rateCode), count: Self.subblocks(rateCode))
        var position = 0
        return lengths.map { count in defer { position += count }; return position..<(position + count) }
    }
    private static func active(_ useCase: UInt32?, program: DolbyEProgram) -> Bool {
        guard let useCase else { return true }
        // ST 2098-2:2022 table 1 assigns 0x06 to 9.1OH. ED2 scene
        // reduction starts from that immersive scene, before the 5.1.2 fold.
        if program == .eightMono { return useCase == 0xff || useCase == 0x06 }
        return useCase == 0xff || useCase == (program == .fiveOnePlusTwo ? 0x01 : 0x02)
    }
    private static func parseBed(_ data: Data, rate: Int, program: DolbyEProgram, depth: Int) throws -> [DolbyEIABRenderable] {
        guard depth < 16 else { throw DolbyEError.malformed("IAB bed nesting exceeds bound") }
        var bits = DolbyEIABBits(data: data)
        let metadataID = try bits.plex(), conditional = try bits.take(1)
        let useCase = try conditional == 0 ? nil : bits.take(8)
        let count = try bits.plex(4)
        guard count <= 256 else { throw DolbyEError.malformed("IAB bed channel count exceeds bound") }
        var sources: [DolbyEIABRenderable] = []
        for _ in 0..<count {
            let channel = try bits.plex(4), audio = try bits.plex(), gain = try bits.gain()
            if try bits.take(1) != 0 {
                _ = try bits.take(4)
                guard try bits.decorrelation() == 0 else { throw DolbyEError.unsupported("IAB decorrelated bed channel") }
            }
            let bed = try bedChannel(channel, program: program)
            sources.append(DolbyEIABRenderable(id: "B\(metadataID).\(channel)", audioID: audio, bed: bed, gain: gain, pans: []))
        }
        _ = try bits.take(10); try bits.align(); try bits.description()
        let children = try bits.plex()
        guard children <= 512 else { throw DolbyEError.malformed("IAB bed child count exceeds bound") }
        var replacement: [DolbyEIABRenderable]?
        for _ in 0..<children {
            let (id, child) = try bits.element()
            if id == 0x10 {
                let items = try parseBed(child, rate: rate, program: program, depth: depth + 1)
                if !items.isEmpty, replacement == nil { replacement = items }
            } else if id == 0x20 { throw DolbyEError.unsupported("IAB bed remapping") }
            else { throw DolbyEError.malformed("disallowed IAB bed child") }
        }
        try bits.finish()
        return active(useCase, program: program) ? replacement ?? sources : []
    }
    /// SMPTE ST 2098-2:2022 table19. ChannelID is a semantic routing code,
    /// not an interleaved PCM index: 0x02 is C and 0x04 is R.
    static func bedChannel(_ channel: UInt32, program: DolbyEProgram) throws -> DolbyEAtmosBed {
        var mapping: [UInt32: DolbyEAtmosBed] = [0: .left, 1: .leftExtra, 2: .center, 3: .rightExtra, 4: .right,
            5: .leftSide, 6: .leftBack, 7: .leftBack, 8: .rightBack, 9: .rightSide, 10: .rightBack,
            11: .leftTop, 12: .rightTop, 13: .lfe, 0x80: .leftTop, 0x81: .rightTop, 0x82: .leftTop, 0x83: .rightTop]
        if program == .eightMono {
            mapping[0x80] = .leftTopFront; mapping[0x81] = .rightTopFront
            mapping[0x82] = .leftTopBack; mapping[0x83] = .rightTopBack
        }
        guard let bed = mapping[channel] else { throw DolbyEError.unsupported("IAB bed channel 0x\(String(channel, radix: 16))") }
        return bed
    }
    private static func parseObject(_ data: Data, rate: Int, program: DolbyEProgram, depth: Int) throws -> [DolbyEIABRenderable] {
        guard depth < 16 else { throw DolbyEError.malformed("IAB object nesting exceeds bound") }
        var bits = DolbyEIABBits(data: data)
        let metadataID = try bits.plex(), audio = try bits.plex(), conditional = try bits.take(1)
        var useCase: UInt32?
        if conditional != 0 { _ = try bits.take(1); useCase = try bits.take(8) }
        _ = try bits.take(1)
        var pans: [DolbyEIABPan] = []
        for index in 0..<subblocks(rate) {
            if try index == 0 || bits.take(1) != 0 { pans.append(try parsePan(&bits)) }
            else { pans.append(pans[index - 1]) }
        }
        try bits.align(); try bits.description()
        let children = try bits.plex()
        guard children <= 512 else { throw DolbyEError.malformed("IAB object child count exceeds bound") }
        var replacement: [DolbyEIABRenderable]?
        for _ in 0..<children {
            let (id, child) = try bits.element()
            guard id == 0x40 else { throw DolbyEError.unsupported("IAB object child element 0x\(String(id, radix: 16))") }
            let items = try parseObject(child, rate: rate, program: program, depth: depth + 1)
            if !items.isEmpty, replacement == nil { replacement = items }
        }
        try bits.finish()
        return active(useCase, program: program) ? replacement ?? [DolbyEIABRenderable(id: "O\(metadataID)", audioID: audio, bed: nil, gain: 1, pans: pans)] : []
    }
    private static func parsePan(_ bits: inout DolbyEIABBits) throws -> DolbyEIABPan {
        let gain = try bits.gain(); _ = try bits.take(3)
        let x = try bits.take(16), y = try bits.take(16), z = try bits.take(16)
        guard x >= 32767, y >= 32767 else { throw DolbyEError.malformed("IAB position exceeds coding cube") }
        let value = DolbyEAtmosValue(x: 2 * Double(x - 32767) / 32768 - 1,
            y: 1 - 2 * Double(y - 32767) / 32768, z: Double(z) / 65536, gain: gain)
        var snap: Double?
        if try bits.take(1) != 0 { snap = try bits.take(1) != 0 ? Double(bits.take(12)) / 4095 : 1; _ = try bits.take(1) }
        var zones: [Double]?
        if try bits.take(1) != 0 {
            var gains: [Double] = []
            for _ in 0..<9 { gains.append(try bits.gain(zone: true)) }
            zones = gains
        }
        let mode = try bits.take(2)
        let spread: Double
        switch mode {
        case 0: spread = Double(try bits.take(8)) / 255
        case 1: spread = 0
        case 2: spread = Double(try bits.take(12)) / 4095
        default: spread = Double(try bits.take(12) + bits.take(12) + bits.take(12)) / (4095 * 3)
        }
        _ = try bits.take(4)
        return DolbyEIABPan(value: value, spread: spread, snap: snap, zones: zones, decorrelation: try bits.decorrelation())
    }

    // DLC is lossless integer prediction plus sign/magnitude or Rice residuals.
    // Arithmetic wraps at 32 bits exactly as the coding process specifies.
    private static func decodeDLC(_ bits: inout DolbyEIABBits,
                                  format: (samples: Int, rate: Int, bits: Int, is96k: Bool)) throws -> [Float] {
        let size = Int(try bits.take(16))
        guard bits.remaining == size * 8 else { throw DolbyEError.malformed("IAB DLCSize differs from element length") }
        let is96k = try bits.take(2)
        guard is96k <= 1, (is96k == 1) == format.is96k else { throw DolbyEError.malformed("IAB DLC sampling rate mismatch") }
        let shift = Int(try bits.take(5))
        let layout = [(10, 200), (10, 192), (8, 200), (5, 200), (5, 192), (4, 200), (5, 100), (4, 120), (4, 100)]
        guard format.rate < layout.count else { throw DolbyEError.unsupported("IAB DLC at 24000/1001") }
        let (blocks, length) = layout[format.rate]
        func layer(_ reader: inout DolbyEIABBits, length: Int) throws -> [Int32] {
            let regions = Int(try reader.take(2))
            var predictors: [(end: Int, coefficients: [Int32])] = [], covered = 0
            for _ in 0..<regions {
                let span = Int(try reader.take(4)), order = Int(try reader.take(5))
                guard span > 0, covered + span <= blocks else { throw DolbyEError.malformed("invalid IAB prediction region") }
                var coefficients = [Int32](repeating: 0, count: order + 1); coefficients[0] = 1 << 20
                if order > 0 {
                    for stage in 1...order {
                        let reflection = (Int32(try reader.take(10)) - 512) << 11
                        let previous = coefficients
                        for tap in 1...stage {
                            coefficients[tap] = previous[tap] &+ Int32(truncatingIfNeeded: (Int64(reflection) * Int64(previous[stage - tap])) >> 20)
                        }
                    }
                }
                covered += span; predictors.append((covered, coefficients))
            }
            guard regions == 0 || covered == blocks else { throw DolbyEError.malformed("IAB predictors do not cover the frame") }
            var output = [Int32](); output.reserveCapacity(blocks * length)
            var history = [Int32](repeating: 0, count: 64), head = 0, region = 0
            for block in 0..<blocks {
                while region < predictors.count && block >= predictors[region].end { region += 1 }
                let rice = try reader.take(1) != 0, width = Int(try reader.take(5))
                for _ in 0..<length {
                    var quotient: UInt64 = 0
                    if rice { while try reader.take(1) != 0 { quotient += 1; guard quotient <= UInt64(Int32.max) >> width else { throw DolbyEError.malformed("IAB Rice quotient overflow") } } }
                    let magnitude = (quotient << width) + UInt64(try reader.take(width))
                    guard magnitude <= UInt64(Int32.max) else { throw DolbyEError.malformed("IAB residual overflow") }
                    var value = Int32(magnitude)
                    if value != 0, try reader.take(1) != 0 { value = -value }
                    if region < predictors.count {
                        let coefficients = predictors[region].coefficients
                        var accumulator: Int64 = 0
                        for tap in 1..<coefficients.count { accumulator = accumulator &- Int64(history[(head - tap + 1) & 63]) * Int64(coefficients[tap]) }
                        value = value &+ Int32(truncatingIfNeeded: accumulator >> 20)
                    }
                    head = (head + 1) & 63; history[head] = value; output.append(value)
                }
            }
            return output
        }
        let base = try layer(&bits, length: length)
        if format.is96k { _ = try layer(&bits, length: length * 2) }
        try bits.finish()
        return base.map { Float($0 &<< shift) / Float(Int32.max) }
    }
}
