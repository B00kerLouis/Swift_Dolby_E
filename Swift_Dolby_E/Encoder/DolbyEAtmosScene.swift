// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

enum DolbyEAtmosBed: String, Sendable {
    case left, right, center, lfe, leftSide, rightSide, leftBack, rightBack, leftTop, rightTop, leftExtra, rightExtra
    case leftTopFront, rightTopFront, leftTopBack, rightTopBack
    init?(label: String) {
        var value = (label.split(separator: ":").last.map(String.init) ?? label).lowercased()
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        if value.hasPrefix("rc") { value = String(value.dropFirst(2)) }
        switch value {
        case "l", "left", "roomcentricleft", "m+030": self = .left
        case "r", "right", "roomcentricright", "m-030": self = .right
        case "c", "center", "centre", "roomcentriccenter", "m+000": self = .center
        case "lfe", "lfe1", "lowfrequency", "roomcentriclfe": self = .lfe
        case "ls", "lss", "leftside", "roomcentricleftside", "leftsidesurround", "roomcentricleftsidesurround", "m+090": self = .leftSide
        case "rs", "rss", "rightside", "roomcentricrightside", "rightsidesurround", "roomcentricrightsidesurround", "m-090": self = .rightSide
        case "lb", "lrs", "leftrear", "roomcentricleftrear", "leftrearsurround", "roomcentricleftrearsurround", "m+110", "m+135": self = .leftBack
        case "rb", "rrs", "rightrear", "roomcentricrightrear", "rightrearsurround", "roomcentricrightrearsurround", "m-110", "m-135": self = .rightBack
        case "lt", "lts", "lefttop", "roomcentriclefttop", "lefttopsurround", "roomcentriclefttopsurround", "u+090": self = .leftTop
        case "rt", "rts", "righttop", "roomcentricrighttop", "righttopsurround", "roomcentricrighttopsurround", "u-090": self = .rightTop
        case "ltfl", "ltf", "tfl", "lefttopfront", "u+030", "u+045": self = .leftTopFront
        case "rtfr", "rtf", "tfr", "righttopfront", "u-030", "u-045": self = .rightTopFront
        case "ltbl", "ltb", "tbl", "lefttopback", "u+135": self = .leftTopBack
        case "rtbr", "rtb", "tbr", "righttopback", "u-135": self = .rightTopBack
        case "le", "lc", "leftcenter", "m+015": self = .leftExtra
        case "re", "rc", "rightcenter", "m-015": self = .rightExtra
        default: return nil
        }
    }
}

struct DolbyEAtmosValue: Hashable, Sendable {
    var x: Double = 0
    var y: Double = 1
    var z: Double = 0
    var gain: Double = 1
    var spread: Double = 0
    var decorrelation: Double = 0
    var snapTolerance: Double? = nil
    var zones: [Double]? = nil
}

struct DolbyEAtmosEvent: Sendable {
    let sample: UInt64
    let ramp: UInt64
    let value: DolbyEAtmosValue
}

struct DolbyEAtmosTrack: Sendable {
    let channel: Int
    let bed: DolbyEAtmosBed?
    let start: UInt64
    let end: UInt64
    let gain: Double
    let events: [DolbyEAtmosEvent]

    func value(at sample: UInt64) -> DolbyEAtmosValue? {
        guard sample >= start, sample < end else { return nil }
        let relative = sample - start
        var low = 0, high = events.count
        while low < high {
            let middle = (low + high) / 2
            if events[middle].sample <= relative { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return bed == nil ? nil : DolbyEAtmosValue(gain: gain) }
        let event = events[low - 1]
        var value = event.value
        if event.ramp > 0, relative - event.sample < event.ramp, low > 1 {
            let previous = events[low - 2].value
            let fraction = Double(relative - event.sample) / Double(event.ramp)
            value.x = previous.x + (value.x - previous.x) * fraction
            value.y = previous.y + (value.y - previous.y) * fraction
            value.z = previous.z + (value.z - previous.z) * fraction
            value.gain = previous.gain + (value.gain - previous.gain) * fraction
            value.spread = previous.spread + (value.spread - previous.spread) * fraction
            value.decorrelation = previous.decorrelation + (value.decorrelation - previous.decorrelation) * fraction
        }
        value.gain *= gain
        return value
    }
}

struct DolbyEAtmosScene: Sendable {
    let channels: Int
    let tracks: [DolbyEAtmosTrack]
    let ignoredChannels: Set<Int>
    func validate() throws {
        guard (1...256).contains(channels), !tracks.isEmpty else { throw DolbyEError.malformed("empty Atmos scene") }
        for track in tracks {
            guard (0..<channels).contains(track.channel), track.start < track.end, track.gain.isFinite, track.gain >= 0,
                  track.bed != nil || !track.events.isEmpty else { throw DolbyEError.malformed("invalid Atmos track \(track.channel), \(channels) source channels") }
            for (index, event) in track.events.enumerated() {
                let value = event.value
                guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
                      (-1...1).contains(value.x), (-1...1).contains(value.y), (-1...1).contains(value.z) else {
                    throw DolbyEError.malformed("Atmos track \(track.channel), sample \(event.sample): position [\(value.x), \(value.y), \(value.z)] exceeds the room")
                }
                guard value.gain.isFinite, value.gain >= 0, (0...1).contains(value.spread), (0...1).contains(value.decorrelation),
                      value.snapTolerance == nil || (0...1).contains(value.snapTolerance!),
                      value.zones == nil || (value.zones!.count == 9 && value.zones!.allSatisfy({ $0.isFinite && (0...1).contains($0) })),
                      index == 0 || track.events[index - 1].sample < event.sample else { throw DolbyEError.malformed("invalid spatial event on track \(track.channel), sample \(event.sample)") }
            }
        }
    }
}

/// Stateful rendering into the two requested delivery programs. Cinema and
/// Home have separate gain graphs, with one common Home output phase network.
struct DolbyEAtmosRenderer: Codable, Sendable {
    let program: DolbyEProgram
    let downmixMode: DolbyEDownmixMode
    private var homeHistory = Array(repeating: [Float](repeating: 0, count: 8), count: 2)
    private var parity = 0
    private var iabRamps: [String: DolbyEIABRamp] = [:]
    private var decorrelators = (0..<8).map { DolbyEDecorrelator(channel: $0) }

    init(program: DolbyEProgram, downmixMode: DolbyEDownmixMode = .loro) { self.program = program; self.downmixMode = downmixMode }

    mutating func render(_ pcm: [Float], scene: DolbyEAtmosScene, at position: UInt64) throws -> [Double] {
        guard pcm.count % scene.channels == 0, pcm.count <= 8192 * scene.channels, pcm.allSatisfy(\.isFinite),
              homeHistory.count == 2, homeHistory.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isFinite) }),
              (0...1).contains(parity) else { throw DolbyEError.malformed("invalid Atmos renderer state or samples") }
        let count = pcm.count / scene.channels
        let mapped = Set(scene.tracks.map(\.channel)).union(scene.ignoredChannels)
        for channel in 0..<scene.channels where !mapped.contains(channel) {
            for frame in 0..<count where pcm[frame * scene.channels + channel] != 0 {
                throw DolbyEError.malformed("active Atmos channel \(channel + 1) has no bed or object assignment")
            }
        }
        var output = [Double](repeating: 0, count: count * 8)
        var diffuse = output
        // Static events reuse their computed gains; moving objects are evaluated
        // at the exact source sample, independent of processing block size.
        for track in scene.tracks {
            var previous: DolbyEAtmosValue?
            var weights = [Double]()
            for frame in 0..<count {
                let sample = Double(pcm[frame * scene.channels + track.channel])
                guard sample != 0, let value = track.value(at: position + UInt64(frame)) else { continue }
                if previous != value {
                    if let bed = track.bed { weights = gains(value, bed: bed, zones: value.zones) }
                    else { weights = try spatialGains(DolbyEIABPan(value: value, spread: value.spread,
                        snap: value.snapTolerance, zones: value.zones, decorrelation: value.decorrelation)) }
                    previous = value
                }
                let wet = track.bed == .lfe ? 0 : sqrt(value.decorrelation), dry = sqrt(1 - wet * wet)
                for channel in 0..<8 {
                    output[frame * 8 + channel] += sample * weights[channel] * dry
                    diffuse[frame * 8 + channel] += sample * weights[channel] * wet
                }
            }
        }
        return try processIABBuses(dry: output, diffuse: diffuse)
    }

    mutating func processHome(_ samples: [Double]) throws -> [Double] {
        guard samples.count % 8 == 0, homeHistory.count == 2,
              homeHistory.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isFinite) }), (0...1).contains(parity) else {
            throw DolbyEError.malformed("invalid Home filter state")
        }
        var output = samples
        let count = output.count / 8
        if program == .fiveOnePlusTwo {
            for frame in 0..<count {
                for channel in 0..<2 {
                    let index = frame * 8 + channel + 6
                    let input = Float(output[index]), base = parity * 4
                    let a = Float(bitPattern: 0xbf158aae), b = Float(bitPattern: 0xbd858444)
                    let value = b * input + a * homeHistory[channel][base] + homeHistory[channel][base + 1]
                        - a * homeHistory[channel][base + 2] - b * homeHistory[channel][base + 3]
                    homeHistory[channel][base + 1] = homeHistory[channel][base]; homeHistory[channel][base] = input
                    homeHistory[channel][base + 3] = homeHistory[channel][base + 2]; homeHistory[channel][base + 2] = value
                    output[index] = Double(value)
                }
                parity ^= 1
            }
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("Atmos render overflow") }
        return output
    }

    mutating func mixIAB(samples: [Float], range: Range<Int>, blockStart: Int, blockLength: Int,
                         outputOffset: Int, token: UInt64, id: String, target: [Double], output: inout [Double]) throws {
        guard target.count == 8, target.allSatisfy(\.isFinite), samples.indices.contains(range.lowerBound),
              range.upperBound <= samples.count, outputOffset + range.lowerBound >= 0,
              (outputOffset + range.upperBound) * 8 <= output.count, iabRamps.count <= 512 else {
            throw DolbyEError.malformed("invalid IAB gain interpolation state")
        }
        let old = iabRamps[id]
        let state: DolbyEIABRamp
        if let old, old.token == token { state = old }
        else {
            let current = old?.current ?? target
            guard current.count == 8, current.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("invalid saved IAB gains") }
            var start = current, periods = [Int](repeating: 0, count: 8)
            for channel in 0..<8 where current[channel] != target[channel] {
                let initial = min(4800, blockLength)
                let delta = (target[channel] - current[channel]) / Double(initial)
                let slope = max(-1.0 / 480, min(1.0 / 480, delta))
                periods[channel] = abs(delta) > 1.0 / 480 ? 480 : initial
                start[channel] += slope
            }
            state = DolbyEIABRamp(token: token, start: start, target: target, periods: periods, current: current)
        }
        guard state.start.count == 8, state.target.count == 8, state.periods.count == 8,
              state.start.allSatisfy(\.isFinite), state.target.allSatisfy(\.isFinite),
              state.periods.allSatisfy({ (0...4800).contains($0) }) else { throw DolbyEError.malformed("corrupt IAB gain ramp checkpoint") }
        var reached = state
        for index in range {
            let step = index - blockStart, sample = Double(samples[index]), base = (outputOffset + index) * 8
            for channel in 0..<8 {
                let period = state.periods[channel]
                let fraction = period > 1 && step < period ? Double(step) / Double(period - 1) : 1
                let gain = state.start[channel] + (state.target[channel] - state.start[channel]) * fraction
                output[base + channel] += sample * gain
                reached.current[channel] = gain
            }
        }
        iabRamps[id] = reached
    }

    mutating func retainIABSources(_ ids: Set<String>) { iabRamps = iabRamps.filter { ids.contains($0.key) } }

    mutating func processIABBuses(dry: [Double], diffuse: [Double]) throws -> [Double] {
        guard dry.count == diffuse.count, dry.count % 8 == 0, decorrelators.count == 8 else { throw DolbyEError.malformed("invalid IAB diffuse bus") }
        var output = dry
        for frame in 0..<(dry.count / 8) {
            for channel in 0..<8 where channel != 3 {
                let index = frame * 8 + channel
                output[index] += try decorrelators[channel].process(diffuse[index])
            }
        }
        return try processHome(output)
    }

    func gains(_ value: DolbyEAtmosValue, bed: DolbyEAtmosBed?, zones: [Double]? = nil) -> [Double] {
        let boost = pow(10.0, 3 / 20.0)
        var gains = [Double](repeating: 0, count: 8)
        if let bed {
            switch bed {
            case .left: gains[0] = 1; gains[6] = 1
            case .right: gains[1] = 1; gains[7] = 1
            case .center: gains[2] = 1; gains[6] = 0.70800775; gains[7] = 0.70800775
            case .lfe: gains[3] = 1
            case .leftSide: gains[4] = boost; gains[6] = 0.53108376
            case .rightSide: gains[5] = boost; gains[7] = 0.53108376
            case .leftBack: gains[4] = boost; gains[6] = 0.5012322
            case .rightBack: gains[5] = boost; gains[7] = 0.5012322
            case .leftTop, .leftTopFront, .leftTopBack: gains[4] = 1; gains[6] = 0.5012322
            case .rightTop, .rightTopFront, .rightTopBack: gains[5] = 1; gains[7] = 0.5012322
            case .leftExtra: gains[0] = sqrt(0.5); gains[2] = sqrt(0.5); gains[6] = (1 + 0.70800775) * sqrt(0.5)
            case .rightExtra: gains[1] = sqrt(0.5); gains[2] = sqrt(0.5); gains[7] = (1 + 0.70800775) * sqrt(0.5)
            }
            if downmixMode == .ltrt, [.leftSide, .rightSide, .leftBack, .rightBack, .leftTop, .rightTop,
                .leftTopFront, .rightTopFront, .leftTopBack, .rightTopBack].contains(bed) {
                let surround = (gains[6] + gains[7]) * sqrt(0.5)
                gains[6] = -surround; gains[7] = surround
            }
            if program == .sevenOneScreen {
                gains[6] = 0; gains[7] = 0
                if bed == .leftExtra { gains[0] = 0; gains[2] = 0; gains[6] = 1 }
                if bed == .rightExtra { gains[1] = 0; gains[2] = 0; gains[7] = 1 }
            }
        } else {
            let x = value.x, y = value.y
            let lateral = (x + 1) * .pi / 4
            let depth = (1 - y) * .pi / 4
            // Front row: L/C/R for 5.1, L/Le/C/Re/R for Screen.
            let frontChannels = program == .fiveOnePlusTwo ? [0, 2, 1] : [0, 6, 2, 7, 1]
            let location = (x + 1) * Double(frontChannels.count - 1) / 2
            let cell = min(frontChannels.count - 2, Int(location))
            let angle = (location - Double(cell)) * .pi / 2
            gains[frontChannels[cell]] = cos(angle) * cos(depth)
            gains[frontChannels[cell + 1]] = sin(angle) * cos(depth)
            gains[4] = cos(lateral) * sin(depth) * boost
            gains[5] = sin(lateral) * sin(depth) * boost
            if program == .fiveOnePlusTwo {
                // Home compatibility power law, then the Home Lo/Ro fold.
                var floor = [Double](repeating: 0, count: 8)
                let front = y >= 0 ? sin(y * .pi / 2) : 0
                let side = cos(abs(y) * .pi / 2), back = y < 0 ? sin(-y * .pi / 2) : 0
                let frontLocation = x < 0 ? x + 1 : x
                let pair = frontLocation * .pi / 2
                floor[x < 0 ? 0 : 2] = cos(pair) * front
                floor[x < 0 ? 2 : 1] = sin(pair) * front
                floor[4] = cos(lateral) * side; floor[5] = sin(lateral) * side
                floor[6] = cos(lateral) * back; floor[7] = sin(lateral) * back
                if let zones {
                    let power = floor.reduce(0) { $0 + $1 * $1 }
                    for (channel, zone) in [(0, 0), (1, 2), (2, 1), (4, 3), (5, 4), (6, 5), (7, 6)] { floor[channel] *= zones[zone] }
                    let remaining = floor.reduce(0) { $0 + $1 * $1 }
                    if remaining > 0 { let correction = sqrt(power / remaining); floor = floor.map { $0 * correction } }
                }
                let rearPower = sqrt(0.5)
                let horizontal = y >= 0 ? 0.75 + 0.25 * y : 0.75 + (0.75 - rearPower) * y
                let scale = sqrt(rearPower + (horizontal - rearPower) * max(0, 1 - 2 * abs(value.z)))
                let collapse = pow(2.0, -0.25)
                let surroundLeft = (floor[4] + floor[6]) * collapse * 0.5012322
                let surroundRight = (floor[5] + floor[7]) * collapse * 0.5012322
                gains[6] = (floor[0] + floor[2] * 0.70800775) * scale
                gains[7] = (floor[1] + floor[2] * 0.70800775) * scale
                if downmixMode == .loro { gains[6] += surroundLeft * scale; gains[7] += surroundRight * scale }
                else {
                    let surround = (surroundLeft + surroundRight) * sqrt(0.5) * scale
                    gains[6] -= surround; gains[7] += surround
                }
            }
        }
        if let zones {
            let power = gains[0..<6].reduce(0) { $0 + $1 * $1 }
            gains[0] *= zones[0]; gains[1] *= zones[2]; gains[2] *= zones[1]
            let rear = max(0, -value.y), side = sqrt(max(0, 1 - rear * rear))
            gains[4] *= sqrt(pow(zones[3] * side, 2) + pow(zones[5] * rear, 2))
            gains[5] *= sqrt(pow(zones[4] * side, 2) + pow(zones[6] * rear, 2))
            let remaining = gains[0..<6].reduce(0) { $0 + $1 * $1 }
            if remaining > 0 { let correction = sqrt(power / remaining); for channel in 0..<6 { gains[channel] *= correction } }
            if program == .sevenOneScreen { gains[6] *= sqrt(zones[0] * zones[1]); gains[7] *= sqrt(zones[1] * zones[2]) }
        }
        return gains.map { $0 * value.gain }
    }
}
