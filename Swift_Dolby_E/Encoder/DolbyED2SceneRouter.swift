// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct DolbyED2RoutedFrame: Sendable {
    var samples: [Double]
    var metadata: DolbyED2SceneMetadata
}

/// A transient source for one bounded read. The position/gain closure captures
/// only immutable scene values; file handles and persistent state never escape.
struct DolbyED2SpatialInput: Sendable {
    let id: String
    let bed: DolbyEAtmosBed?
    let samples: [Float]
    let valueAt: @Sendable (Int) -> DolbyEAtmosValue?
}

struct DolbyED2SourceSpan: Sendable {
    let range: Range<Int>
    let value: DolbyEAtmosValue
}

/// Only the current IAB read is buffered. Stable metadata IDs, rather than
/// per-frame AudioDataIDs, associate a moving source across IAFrame boundaries.
struct DolbyED2BufferedInput {
    let id: String
    let bed: DolbyEAtmosBed?
    var samples: [Float]
    var spans: [DolbyED2SourceSpan] = []

    func source() -> DolbyED2SpatialInput {
        let spans = spans
        return DolbyED2SpatialInput(id: id, bed: bed, samples: samples, valueAt: { index in
            var low = 0, high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].range.upperBound <= index { low = middle + 1 } else { high = middle }
            }
            guard low < spans.count, spans[low].range.contains(index) else { return nil }
            return spans[low].value
        })
    }
}

/// Reduces source objects into a finite, moving eight-object transport while
/// retaining an independent 5.1.2 bed. This spatial reduction is lossy; it is
/// separate from the Dolby E audio codec and does not imply renderer identity.
///
/// Energy-weighted farthest-point seeding and Lloyd refinement account for every
/// audible source. A small global assignment keeps centroid slot identities
/// stable. LFE never participates. Source gains/time windows remain sample-based;
/// at most eight spatial updates describe each delivered video frame.
struct DolbyED2SceneRouter: Codable, Sendable {
    let dialogueSource: DolbyEDialogueSource
    let inputLayout: DolbyEInputLayout
    private var centers: [DolbyED2Position] = [
        .init(x: -1, y: 1), .init(x: 1, y: 1), .init(x: -1, y: -1), .init(x: 1, y: -1),
        .init(x: -1, y: 1, z: 1), .init(x: 1, y: 1, z: 1),
        .init(x: -1, y: -1, z: 1), .init(x: 1, y: -1, z: 1)
    ]
    private var leaders = Array(repeating: "", count: 8)
    private var lastWeights: [String: [Double]] = [:]
    private var decorrelators = (0..<16).map { DolbyEDecorrelator(channel: $0) }
    private var seenCenter = false

    init(dialogueSource: DolbyEDialogueSource, inputLayout: DolbyEInputLayout = .automatic) {
        self.dialogueSource = dialogueSource; self.inputLayout = inputLayout
        if dialogueSource == .bedCenter { centers[0] = .init() }
    }

    private struct Prepared {
        let index: Int
        let gains: [Double]
        let value: DolbyEAtmosValue
        let energy: Double
        let position: DolbyED2Position
        let declared: Bool
    }

    mutating func route(_ sources: [DolbyED2SpatialInput], frames: Int) throws -> DolbyED2RoutedFrame {
        guard (1...2048).contains(frames), sources.count <= 512,
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ $0.samples.count == frames && $0.samples.allSatisfy(\.isFinite) }),
              centers.count == 8, leaders.count == 8, decorrelators.count == 16,
              lastWeights.count <= 512, lastWeights.values.allSatisfy({ $0.count == 32 && $0.allSatisfy(\.isFinite) }) else {
            throw DolbyEError.malformed("invalid ED2 spatial input or recovery state")
        }
        seenCenter = seenCenter || sources.contains { $0.bed == .center }
        guard dialogueSource != .bedCenter || seenCenter else {
            throw DolbyEError.invalidArgument("--dialogue-source bed-c requires an assigned center bed channel")
        }
        for center in centers { try center.validate() }
        let updateCount = (frames + 255) / 256
        var output = [Double](repeating: 0, count: frames * 16)
        var states = Array(repeating: [DolbyED2ObjectState](), count: 8)
        for update in 0..<updateCount {
            // Fixed 256-sample analysis blocks share the OAMD 32-sample grid.
            // The source preview analyzes this same first block, so requesting
            // six preview samples cannot change their future committed route.
            let start = update * 256, end = min(frames, start + 256)
            let range = start..<end
            let bedKinds = Set(sources.compactMap { source in
                source.valueAt(start + range.count / 2) == nil ? nil : source.bed
            })
            var prepared: [Prepared] = []
            prepared.reserveCapacity(sources.count)
            for (index, source) in sources.enumerated() {
                var gains = [Double](); gains.reserveCapacity(range.count)
                var mass = 0.0, x = 0.0, y = 0.0, z = 0.0, spread = 0.0, decorrelation = 0.0
                var representative: DolbyEAtmosValue?
                for sample in range {
                    guard let value = source.valueAt(sample) else { gains.append(0); continue }
                    try validate(value)
                    gains.append(value.gain)
                    let amplitude = Double(source.samples[sample]) * value.gain
                    let energy = amplitude * amplitude
                    guard amplitude.isFinite, energy.isFinite, (mass + energy).isFinite else {
                        throw DolbyEError.malformed("ED2 source gain overflows spatial analysis")
                    }
                    if representative == nil || energy > 0 { representative = value }
                    mass += energy; x += value.x * energy; y += value.y * energy; z += value.z * energy
                    spread += value.spread * energy; decorrelation += value.decorrelation * energy
                }
                var value = representative ?? DolbyEAtmosValue(gain: 0)
                if mass > 0 {
                    value.x = x / mass; value.y = y / mass; value.z = z / mass
                    value.spread = spread / mass; value.decorrelation = decorrelation / mass
                }
                prepared.append(Prepared(index: index, gains: gains, value: value, energy: mass,
                    position: snappedPosition(value), declared: representative != nil))
            }
            guard prepared.reduce(0.0, { $0 + $1.energy }).isFinite else {
                throw DolbyEError.malformed("ED2 aggregate energy overflows spatial analysis")
            }
            let dynamic = prepared.filter { sources[$0.index].bed == nil && $0.energy > 0 }
            let declared = prepared.filter { sources[$0.index].bed == nil && $0.declared }
            let firstSlot = dialogueSource == .bedCenter ? 1 : 0
            // Authored coordinates remain meaningful with AudioDataID zero.
            // During total silence seed geometry from those real coordinates,
            // rather than leaving arbitrary cube/origin defaults on the wire.
            let geometry = dynamic.isEmpty ? declared.map {
                Prepared(index: $0.index, gains: $0.gains, value: $0.value, energy: 1,
                    position: $0.position, declared: true)
            } : dynamic
            let active = cluster(geometry, sources: sources, firstSlot: firstSlot)
            var sizes = [Double](repeating: 0, count: 8), masses = sizes
            if dynamic.isEmpty {
                for input in geometry {
                    if let slot = centers.indices.filter({ active[$0] }).min(by: { distance(input.position, centers[$0]) < distance(input.position, centers[$1]) }) {
                        masses[slot] += 1
                        sizes[slot] += min(1, input.value.spread + sqrt(distance(input.position, centers[slot])))
                    }
                }
            }
            var wet = [Double](repeating: 0, count: range.count * 16)
            for item in prepared {
                let source = sources[item.index]
                var target = [Double](repeating: 0, count: 16)
                if let bed = source.bed {
                    if bed == .center, dialogueSource == .bedCenter { target[8] = 1 }
                    else { target = bedWeights(bed, present: bedKinds) }
                } else if item.energy > 0 {
                    target = objectWeights(item.position, zones: item.value.zones, active: active)
                }
                let wetGain = source.bed == .lfe ? 0 : sqrt(item.value.decorrelation)
                let dryGain = sqrt(max(0, 1 - wetGain * wetGain))
                let desired = target.map { $0 * dryGain } + target.map { $0 * wetGain }
                let retained = lastWeights[source.id]
                // A newly audible source needs its complete first sample.
                // Spatial interpolation must not invent an onset fade merely
                // because its previous analysis interval contained silence.
                let previous = retained?.contains(where: { $0 != 0 }) == true ? retained! : desired
                // Sparse routes avoid multiplying all sixteen channels for a
                // point source. Linear crossfades conserve coherent amplitude.
                let routes = (0..<16).filter {
                    desired[$0] != 0 || desired[$0 + 16] != 0 || previous[$0] != 0 || previous[$0 + 16] != 0
                }
                for (local, sample) in range.enumerated() {
                    let fraction = range.count == 1 ? 1 : Double(local) / Double(range.count - 1)
                    let amplitude = Double(source.samples[sample]) * item.gains[local]
                    for channel in routes {
                        let dry = previous[channel] + (desired[channel] - previous[channel]) * fraction
                        let diffuse = previous[channel + 16] + (desired[channel + 16] - previous[channel + 16]) * fraction
                        output[sample * 16 + channel] += amplitude * dry
                        wet[local * 16 + channel] += amplitude * diffuse
                    }
                }
                lastWeights[source.id] = desired
                for slot in 0..<8 where target[slot + 8] != 0 {
                    let power = item.energy * target[slot + 8] * target[slot + 8]
                    masses[slot] += power
                    // Preserve authored spread and include spatial extent lost
                    // when several distinct points share a transport object.
                    sizes[slot] += power * min(1, item.value.spread + sqrt(distance(item.position, centers[slot])))
                }
            }
            for (local, sample) in range.enumerated() {
                for channel in 0..<16 where channel != 3 {
                    output[sample * 16 + channel] += try decorrelators[channel].process(wet[local * 16 + channel])
                }
            }
            for slot in 0..<8 {
                states[slot].append(.init(sampleOffset: start, rampDuration: update == 0 ? 0 : range.count,
                    position: centers[slot], gain: 1, active: true,
                    size: masses[slot] > 0 ? min(1, sizes[slot] / masses[slot]) : 0))
            }
        }
        lastWeights = lastWeights.filter { key, _ in sources.contains { $0.id == key } }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("ED2 spatial reduction overflow") }
        let objects = states.enumerated().map { slot, states in
            DolbyED2ObjectMetadata(source: .init(substreamIndex: 1, channelIndex: slot),
                isDialogue: dialogueSource == .bedCenter && slot == 0, states: states)
        }
        let metadata = DolbyED2SceneMetadata(objects: objects)
        try metadata.validate()
        return DolbyED2RoutedFrame(samples: output, metadata: metadata)
    }

    private func validate(_ value: DolbyEAtmosValue) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              (-1...1).contains(value.x), (-1...1).contains(value.y), (-1...1).contains(value.z),
              value.gain.isFinite, value.gain >= 0, (0...1).contains(value.spread),
              (0...1).contains(value.decorrelation),
              value.snapTolerance == nil || (0...1).contains(value.snapTolerance!),
              value.zones == nil || (value.zones!.count == 9 && value.zones!.allSatisfy({ $0.isFinite && (0...1).contains($0) })) else {
            throw DolbyEError.malformed("invalid ED2 source position, gain or spatial attributes")
        }
    }

    private static let anchors: [DolbyED2Position] = [
        .init(x: -1, y: 1), .init(x: 1, y: 1), .init(), .init(),
        .init(x: -1, y: -1), .init(x: 1, y: -1), .init(x: -1, y: 0, z: 1), .init(x: 1, y: 0, z: 1)
    ]
    private func snappedPosition(_ value: DolbyEAtmosValue) -> DolbyED2Position {
        let position = DolbyED2Position(x: value.x, y: value.y, z: value.z)
        guard let tolerance = value.snapTolerance, tolerance > 0, value.spread == 0 else { return position }
        let candidates = Self.anchors.enumerated().filter { $0.offset != 3 }
        let nearest = candidates.min { distance(position, $0.element) < distance(position, $1.element) }!.element
        return sqrt(distance(position, nearest)) <= tolerance ? nearest : position
    }
    private func distance(_ a: DolbyED2Position, _ b: DolbyED2Position) -> Double {
        pow((a.x - b.x) / 2, 2) + pow((a.y - b.y) / 2, 2) + pow(a.z - b.z, 2)
    }
    private mutating func cluster(_ inputs: [Prepared], sources: [DolbyED2SpatialInput], firstSlot: Int) -> [Bool] {
        let slots = Array(firstSlot..<8), count = slots.count
        var candidates: [DolbyED2Position] = [], seeds: [Int] = []
        for _ in 0..<count {
            var selected: Int?, maximum = -1.0
            for index in inputs.indices where !seeds.contains(index) {
                let separation = candidates.map { distance(inputs[index].position, $0) }.min() ?? 1
                let score = inputs[index].energy * separation
                if score > maximum { selected = index; maximum = score }
            }
            guard let selected, maximum > 0 else { break }
            candidates.append(inputs[selected].position); seeds.append(selected)
        }
        let used = candidates.count
        var dominant = Array(repeating: "", count: count)
        if used > 0 {
            for _ in 0..<6 {
                var mass = [Double](repeating: 0, count: used)
                var sums = Array(repeating: SIMD3<Double>.zero, count: used)
                var largest = mass
                for (index, input) in inputs.enumerated() {
                    var destination = (0..<used).min { distance(input.position, candidates[$0]) < distance(input.position, candidates[$1]) }!
                    if let seeded = seeds.firstIndex(of: index), distance(input.position, candidates[seeded]) <= distance(input.position, candidates[destination]) + 1e-12 { destination = seeded }
                    mass[destination] += input.energy
                    sums[destination] += SIMD3(input.position.x, input.position.y, input.position.z) * input.energy
                    if input.energy > largest[destination] {
                        largest[destination] = input.energy; dominant[destination] = sources[input.index].id
                    }
                }
                for index in 0..<used where mass[index] > 0 {
                    let point = sums[index] / mass[index]
                    candidates[index] = .init(x: max(-1, min(1, point.x)), y: max(-1, min(1, point.y)), z: max(-1, min(1, point.z)))
                }
            }
        }
        while candidates.count < count { candidates.append(centers[slots[candidates.count]]) }
        // Exact small assignment (at most 8! alternatives represented by 256
        // subset states) avoids ordering-dependent greedy centroid swaps.
        let combinations = 1 << count
        var costs = Array(repeating: Double.infinity, count: combinations), previous = Array(repeating: -1, count: combinations)
        costs[0] = 0
        for mask in 0..<combinations where costs[mask].isFinite {
            let slot = mask.nonzeroBitCount
            if slot == count { continue }
            for candidate in 0..<count where mask & (1 << candidate) == 0 {
                let identity = dominant[candidate].isEmpty || leaders[slots[slot]] == dominant[candidate] ? 0.0 : 0.25
                let value = costs[mask] + distance(centers[slots[slot]], candidates[candidate]) + identity
                let next = mask | (1 << candidate)
                if value < costs[next] { costs[next] = value; previous[next] = candidate }
            }
        }
        var assignment = [Int](repeating: 0, count: count), mask = combinations - 1
        for slot in stride(from: count - 1, through: 0, by: -1) {
            let candidate = previous[mask]
            assignment[slot] = candidate; mask ^= 1 << candidate
        }
        var active = [Bool](repeating: false, count: 8)
        for (index, slot) in slots.enumerated() {
            let candidate = assignment[index]
            if candidate < used {
                centers[slot] = candidates[candidate]; leaders[slot] = dominant[candidate]; active[slot] = true
            }
        }
        return active
    }

    private func bedWeights(_ bed: DolbyEAtmosBed, present: Set<DolbyEAtmosBed>) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        switch bed {
        case .left: result[0] = 1
        case .right: result[1] = 1
        case .center: result[2] = 1
        case .lfe: result[3] = 1
        case .leftSide, .leftBack:
            result[4] = present.contains(.leftSide) && present.contains(.leftBack) ? sqrt(0.5) : 1
        case .rightSide, .rightBack:
            result[5] = present.contains(.rightSide) && present.contains(.rightBack) ? sqrt(0.5) : 1
        case .leftTop: result[6] = 1
        case .rightTop: result[7] = 1
        case .leftTopFront, .leftTopBack:
            result[6] = present.contains(.leftTopFront) && present.contains(.leftTopBack) ? sqrt(0.5) : 1
        case .rightTopFront, .rightTopBack:
            result[7] = present.contains(.rightTopFront) && present.contains(.rightTopBack) ? sqrt(0.5) : 1
        case .leftExtra: result[0] = sqrt(0.5); result[2] = sqrt(0.5)
        case .rightExtra: result[1] = sqrt(0.5); result[2] = sqrt(0.5)
        }
        return result
    }

    private func zoneGain(_ point: DolbyED2Position, zones: [Double]) -> Double {
        if point.z > 0.5 { return zones[point.x <= 0 ? 7 : 8] }
        if point.y > 0.5 { return zones[point.x < -0.25 ? 0 : (point.x > 0.25 ? 2 : 1)] }
        if point.y < -0.5 { return zones[point.x <= 0 ? 5 : 6] }
        return zones[point.x <= 0 ? 3 : 4]
    }
    private func objectWeights(_ point: DolbyED2Position, zones: [Double]?, active: [Bool]) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        let eligible = centers.indices.filter { active[$0] && (zones == nil || zoneGain(centers[$0], zones: zones!) > 0) }
        if let nearest = eligible.min(by: { distance(point, centers[$0]) < distance(point, centers[$1]) }) {
            result[nearest + 8] = 1
            return result
        }
        guard let zones else { return result }
        // If no aggregate lies in an allowed zone, render this source into the
        // fixed bed with the authored zone gains. No active source is discarded
        // merely because the finite object budget has no eligible centroid.
        let elevation = max(0, min(1, point.z)) * .pi / 2, lateral = (point.x + 1) * .pi / 4
        let front = sin(max(0, point.y) * .pi / 2), surround = sqrt(max(0, 1 - front * front))
        let horizontal = (point.x + 1) * 1.0, pair = min(1, Int(horizontal)), fraction = horizontal - Double(pair)
        let order = [0, 2, 1]
        result[order[pair]] = cos(fraction * .pi / 2) * front * cos(elevation)
        result[order[pair + 1]] = sin(fraction * .pi / 2) * front * cos(elevation)
        result[4] = cos(lateral) * surround * cos(elevation)
        result[5] = sin(lateral) * surround * cos(elevation)
        result[6] = cos(lateral) * sin(elevation); result[7] = sin(lateral) * sin(elevation)
        let original = result.reduce(0) { $0 + $1 * $1 }
        for channel in 0..<8 where channel != 3 { result[channel] *= zoneGain(Self.anchors[channel], zones: zones) }
        let remaining = result.reduce(0) { $0 + $1 * $1 }
        if remaining > 0 { result = result.map { $0 * sqrt(original / remaining) } }
        return result
    }
}
