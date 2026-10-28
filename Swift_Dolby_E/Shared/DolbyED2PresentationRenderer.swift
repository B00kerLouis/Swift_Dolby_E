// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Renders the actual two-substream element PCM described by ED2 metadata.
/// Each call consumes one metadata frame; update offsets are relative to its
/// first sample. Histories include unfinished ramps and stereo phase delays.
/// This renderer uses room coordinates.
public struct DolbyED2PresentationRenderer: Codable, Sendable {
    public let layout: DolbyEPlaybackLayout
    public let downmixMode: DolbyEDownmixMode
    public var outputChannelCount: Int { layout.speakers.count }
    /// Lt/Rt uses a linear-phase quadrature FIR and matched front-path delay.
    public var latencySamples: Int { layout == .stereo && downmixMode == .ltrt ? 31 : 0 }

    private var samplePosition: UInt64 = 0
    private var presentation: Int?
    private var programID: UInt16?
    private var objects: [String: ObjectHistory] = [:]
    private var phase = StereoPhase()
    private static let geometries: [DolbyEPlaybackLayout: Geometry] = Dictionary(uniqueKeysWithValues:
        DolbyEPlaybackLayout.allCases.map { ($0,Geometry(speakers: $0.speakers)) })

    public init(layout: DolbyEPlaybackLayout = .fiveOneTwo, downmixMode: DolbyEDownmixMode = .ltrt) {
        self.layout = layout; self.downmixMode = downmixMode
    }

    /// A completed ramp after all possible pre-window events erases the
    /// unknown ramp origin. Require it for every retained object and leave a
    /// full stereo FIR tail before exposing PCM at the seek destination.
    static func permitsShortSeek(_ frames: [(scene: DolbyED2SceneMetadata, samples: Int)], layout: DolbyEPlaybackLayout) throws -> Bool {
        let mask = layout == .stereo ? 1 : (layout.speakers.contains { $0.position.z > 0 } ? 4 : 2)
        let end = frames.reduce(0) { $0 + $1.samples }
        let settlingTail = layout == .stereo ? DolbyETruePeakLimiter.releaseFrames + DolbyETruePeakLimiter.previewFrames + 64 : 64
        var clock = 0, retained: Set<String> = []
        var events: [String: [Int: Int]] = [:]
        for frame in frames {
            let scene = try frame.scene.resolved(deviceMask: mask)
            retained.removeAll(keepingCapacity: true)
            for (index, object) in scene.objects.enumerated() {
                let key = "\(index):\(object.source.substreamIndex * 8 + object.source.channelIndex)"
                retained.insert(key)
                for state in object.states { events[key, default: [:]][clock + state.sampleOffset] = state.rampDuration }
            }
            clock += frame.samples
        }
        return retained.allSatisfy { key in
            let updates = (events[key] ?? [:]).sorted { $0.key < $1.key }
            return updates.indices.contains { index in
                let event = updates[index], complete = event.key + event.value
                let next = index + 1 < updates.count ? updates[index + 1].key : end
                return event.key >= 2048 && complete <= next && complete < end - settlingTail
            }
        }
    }

    public mutating func render(_ pcm: [Double], scene: DolbyED2SceneMetadata,
                                presentationIndex: Int = 0,maximumParallelism: Int = 1) throws -> [Double] {
        guard pcm.count % 16 == 0, pcm.count <= 8192 * 16, pcm.allSatisfy(\.isFinite),
              outputChannelCount > 0, outputChannelCount <= 16 else {
            throw DolbyEError.invalidArgument("ED2 rendering requires bounded interleaved sixteen-element PCM")
        }
        if pcm.isEmpty { return [] }
        // A failed render never commits a partial ramp or phase-filter history.
        var next = self
        let result = try next.process(pcm, scene: scene, presentationIndex: presentationIndex,maximumParallelism:maximumParallelism)
        self = next
        return result
    }

    private mutating func process(_ pcm: [Double], scene: DolbyED2SceneMetadata,
                                  presentationIndex: Int,maximumParallelism: Int) throws -> [Double] {
        let count = pcm.count / 16
        guard samplePosition <= UInt64.max - UInt64(count + 4096), objects.count <= 16, phase.valid,
              objects.values.allSatisfy(\.valid) else { throw DolbyEError.malformed("invalid ED2 renderer checkpoint") }
        let mask = layout == .stereo ? 1 : (layout.speakers.contains { $0.position.z > 0 } ? 4 : 2)
        let resolved = try scene.resolved(presentation: presentationIndex, deviceMask: mask)
        if presentation != presentationIndex || programID != scene.programID {
            objects.removeAll(keepingCapacity: true); phase = StereoPhase()
            presentation = presentationIndex; programID = scene.programID
        }
        let destinations = layout == .stereo ? DolbyEPlaybackLayout.sevenOneFour.speakers : layout.speakers
        let geometry = Self.geometries[layout == .stereo ? .sevenOneFour : layout]!
        var output = [Double](repeating: 0, count: count * destinations.count)
        for bed in resolved.beds {
            for (channel, speaker) in bed.channels.enumerated() where bed.gains[channel] != 0 {
                let source = bed.source.substreamIndex * 8 + bed.source.channelIndex + channel
                let gains: [Double]
                if speaker == .lfe || speaker == .lfe2 {
                    var row = [Double](repeating: 0, count: destinations.count)
                    if let slot = destinations.firstIndex(of: .lfe) { row[slot] = 1 }
                    gains = row
                } else {
                    let label = Self.speaker(speaker)
                    if let slot = destinations.firstIndex(of: label) {
                        var row = [Double](repeating: 0, count: destinations.count); row[slot] = 1; gains = row
                    } else { gains = geometry.weights(position: label.position, size: 0, snap: false) }
                }
                let routes = gains.enumerated().filter { $0.element != 0 }
                for frame in 0..<count {
                    let value = pcm[frame * 16 + source] * bed.gains[channel]
                    for route in routes { output[frame * destinations.count + route.offset] += value * route.element }
                }
            }
        }
        var retained: Set<String> = []
        // On the measured real programme, independent full-speaker object
        // buffers increase memory/reduction work enough to outweigh worker
        // parallelism. Keep the original ordered in-place render; the budget
        // remains a validated upper bound, not a promise to occupy threads.
        _=try DolbyEParallelWork.limit(maximumParallelism)
        for (index,object) in resolved.objects.enumerated() {
            let key="\(index):\(object.source.substreamIndex*8+object.source.channelIndex)"
            retained.insert(key)
            objects[key]=try Self.renderObject(object,history:objects[key] ?? ObjectHistory(),pcm:pcm,geometry:geometry,position:samplePosition,output:&output)
        }
        objects = objects.filter { retained.contains($0.key) }
        samplePosition += UInt64(count)
        if layout == .stereo {
            var stereo = [Double](repeating: 0, count: count * 2)
            let attenuation = sqrt(0.5)
            for frame in 0..<count {
                let at = frame * destinations.count
                let frontLeft = output[at] + output[at + 2] * attenuation + output[at + 8] * attenuation
                let frontRight = output[at + 1] + output[at + 2] * attenuation + output[at + 9] * attenuation
                let surroundLeft = output[at + 4] + output[at + 6] + output[at + 10] * attenuation
                let surroundRight = output[at + 5] + output[at + 7] + output[at + 11] * attenuation
                if downmixMode == .loro {
                    stereo[frame * 2] = frontLeft + surroundLeft * attenuation
                    stereo[frame * 2 + 1] = frontRight + surroundRight * attenuation
                } else {
                    let filtered = phase.process(left: frontLeft, right: frontRight,
                        surround: (surroundLeft + surroundRight) * attenuation)
                    stereo[frame * 2] = filtered.0 - filtered.2 * attenuation
                    stereo[frame * 2 + 1] = filtered.1 + filtered.2 * attenuation
                }
            }
            output = stereo
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("ED2 presentation render overflow") }
        return output
    }

    private static func speaker(_ value: DolbyED2Speaker) -> DolbyESpeaker {
        switch value {
        case .left: .left
        case .right: .right
        case .center: .center
        case .lfe, .lfe2: .lfe
        case .leftSurround: .leftSide
        case .rightSurround: .rightSide
        case .leftRear: .leftBack
        case .rightRear: .rightBack
        case .leftHeightFront: .topFrontLeft
        case .rightHeightFront: .topFrontRight
        case .leftTopMiddle: .topMiddleLeft
        case .rightTopMiddle: .topMiddleRight
        case .leftHeightRear: .topBackLeft
        case .rightHeightRear: .topBackRight
        case .leftWide: .wideLeft
        case .rightWide: .wideRight
        }
    }

    private struct Parameters: Codable, Sendable {
        var position = SIMD3<Double>(0, 1, 0)
        var gain: Double = 0
        var size: Double = 0
        var snap = false
        var active = false
        init() {}
        init(_ state: DolbyED2ObjectState) {
            position = SIMD3(state.position.x, state.position.y, state.position.z)
            gain = state.active ? state.gain : 0; size = state.size; snap = state.snap; active = state.active
        }
        var valid: Bool {
            [position.x, position.y, position.z].allSatisfy { $0.isFinite && (-1...1).contains($0) }
                && gain.isFinite && gain >= 0 && size.isFinite && (0...1).contains(size)
        }
    }
    @inline(__always) private static func renderObject(_ object:DolbyED2ObjectMetadata,history original:ObjectHistory,pcm:[Double],geometry:Geometry,position:UInt64,output:inout [Double])throws->ObjectHistory {
        var history=original
        let count=pcm.count/16,width=output.count/count
        let source=object.source.substreamIndex*8+object.source.channelIndex
            for state in object.states {
                let event = ScheduledState(sample: position + UInt64(state.sampleOffset), value: Parameters(state), duration: state.rampDuration)
                history.pending.removeAll { $0.sample == event.sample }
                history.pending.append(event)
            }
            history.pending.sort { $0.sample < $1.sample }
            guard history.pending.count <= 16 else { throw DolbyEError.malformed("ED2 object look-ahead exceeds two metadata frames") }
            var previous: SpatialParameters?
            var gains = [Double](repeating: 0, count: width)
            var coneScratch = gains, powers = gains
            for frame in 0..<count {
                let clock = position + UInt64(frame)
                while let event = history.pending.first, event.sample <= clock {
                    let current = history.value(at: event.sample)
                    history.from = history.initialized ? current : event.value
                    history.target = event.value; history.start = event.sample
                    history.duration = history.initialized ? event.duration : 0
                    history.initialized = true; history.pending.removeFirst()
                }
                guard history.initialized else { continue }
                let value = history.value(at: clock)
                guard value.active, value.gain != 0 else { continue }
                let sample = pcm[frame * 16 + source] * value.gain
                // Real zero PCM needs no spatial work. Events and ramp history
                // still advance above, including authored AudioDataID0 motion.
                if sample == 0 { continue }
                let spatial = SpatialParameters(point: value.position, size: value.size, snap: value.snap)
                if previous != spatial {
                    geometry.weights(position: value.position, size: value.size, snap: value.snap,
                        into: &gains, scratch: &coneScratch, powers: &powers)
                    previous = spatial
                }
                for channel in gains.indices where gains[channel] != 0 {
                    output[frame * width + channel] += sample * gains[channel]
                }
            }
        return history
    }

    private struct SpatialParameters: Equatable {
        let point: SIMD3<Double>
        let size: Double
        let snap: Bool
    }
    private struct ScheduledState: Codable, Sendable {
        let sample: UInt64
        let value: Parameters
        let duration: Int
    }
    private struct ObjectHistory: Codable, Sendable {
        var initialized = false
        var from = Parameters()
        var target = Parameters()
        var start: UInt64 = 0
        var duration = 0
        var pending: [ScheduledState] = []
        var valid: Bool {
            from.valid && target.valid && (0...2048).contains(duration) && pending.count <= 16
                && pending.allSatisfy { $0.value.valid && (0...2048).contains($0.duration) }
                && zip(pending, pending.dropFirst()).allSatisfy { $0.sample < $1.sample }
        }
        func value(at sample: UInt64) -> Parameters {
            guard duration > 0, sample >= start, sample - start < UInt64(duration) else { return target }
            let fraction = Double(sample - start) / Double(duration)
            var value = target
            value.position = from.position + (target.position - from.position) * fraction
            value.gain = from.gain + (target.gain - from.gain) * fraction
            value.size = from.size + (target.size - from.size) * fraction
            return value
        }
    }

    /// Separable equal-power interpolation on the actual speaker rows/planes.
    /// Finite-size objects integrate equal solid-angle samples of a cone, then
    /// average channel powers; no random signals or manufactured height PCM exist.
    private struct Geometry: Sendable {
        private static let azimuths: [(cosine: Double, sine: Double)] = (0..<32).map {
            let golden = Double.pi * (3 - sqrt(5.0)), angle = Double($0) * golden
            return (cos(angle), sin(angle))
        }
        struct Row: Sendable { let y: Double; let channels: [Int]; let x: [Double] }
        struct Plane: Sendable { let z: Double; let rows: [Row] }
        let speakers: [DolbyESpeaker]
        let positions: [SIMD3<Double>]
        let planes: [Plane]
        init(speakers: [DolbyESpeaker]) {
            self.speakers = speakers
            self.positions = speakers.map(\.position)
            let indices = speakers.indices.filter { speakers[$0] != .lfe }
            self.planes = Set(indices.map { speakers[$0].position.z }).sorted().map { z in
                let plane = indices.filter { speakers[$0].position.z == z }
                let rows = Set(plane.map { speakers[$0].position.y }).sorted().map { y in
                    let channels = plane.filter { speakers[$0].position.y == y }.sorted { speakers[$0].position.x < speakers[$1].position.x }
                    return Row(y: y, channels: channels, x: channels.map { speakers[$0].position.x })
                }
                return Plane(z: z, rows: rows)
            }
        }
        func weights(position: SIMD3<Double>, size: Double, snap: Bool) -> [Double] {
            var result = [Double](repeating: 0, count: speakers.count)
            var scratch = result, powers = result
            weights(position: position, size: size, snap: snap, into: &result, scratch: &scratch, powers: &powers)
            return result
        }
        /// Reuse the three bounded rows across moving samples. The arithmetic
        /// order, cone directions and per-sample positions remain unchanged.
        func weights(position: SIMD3<Double>, size: Double, snap: Bool, into result: inout [Double],
                     scratch: inout [Double], powers: inout [Double]) {
            // Establish unique buffers once per spatial update. The inner cone
            // kernel then writes bounded rows without per-tap Array COW checks.
            result.withUnsafeMutableBufferPointer { output in
                scratch.withUnsafeMutableBufferPointer { cone in
                    powers.withUnsafeMutableBufferPointer { energy in
                        weights(position: position, size: size, snap: snap, result: output, scratch: cone, powers: energy)
                    }
                }
            }
        }
        private func weights(position: SIMD3<Double>, size: Double, snap: Bool,
                             result: UnsafeMutableBufferPointer<Double>, scratch: UnsafeMutableBufferPointer<Double>,
                             powers: UnsafeMutableBufferPointer<Double>) {
            for channel in result.indices { result[channel] = 0 }
            if snap && size == 0 {
                let indices = speakers.indices.filter { speakers[$0] != .lfe }
                if let nearest = indices.min(by: {
                    lengthSquared(positions[$0] - position) < lengthSquared(positions[$1] - position)
                }) { result[nearest] = 1 }
                return
            }
            if size == 0 { point(position, into: result); return }
            let norm = sqrt(lengthSquared(position))
            let axis = norm > 1e-12 ? position / norm : SIMD3<Double>(0, 1, 0)
            let seed = abs(axis.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
            var horizontal = cross(seed, axis)
            horizontal /= sqrt(lengthSquared(horizontal))
            let vertical = cross(axis, horizontal), aperture = size * Double.pi
            let minimum = cos(aperture)
            // Coordinates describe positions inside the room, not just rays
            // on its boundary. Projecting every nonzero extent straight onto
            // the outer cube made size→0 jump to a different speaker vector.
            // Preserve the actual point radius at zero and expand continuously
            // to the whole room at full extent.
            let pointRadius = max(abs(position.x), abs(position.y), abs(position.z))
            let extentRadius = pointRadius + (1 - pointRadius) * size
            let count = 32
            for channel in powers.indices { powers[channel] = 0 }
            for index in 0..<count {
                let cosine = 1 - (1 - minimum) * (Double(index) + 0.5) / Double(count)
                let sine = sqrt(max(0, 1 - cosine * cosine)), azimuth = Self.azimuths[index]
                let direction = axis * cosine + (horizontal * azimuth.cosine + vertical * azimuth.sine) * sine
                let radius = max(abs(direction.x), abs(direction.y), abs(direction.z), 1e-12)
                // One scratch row serves all32solid-angle samples. Repeated
                // cone integration must not allocate32arrays per PCM sample.
                for channel in scratch.indices { scratch[channel] = 0 }
                point((direction / radius) * extentRadius, into: scratch)
                for channel in powers.indices { powers[channel] += scratch[channel] * scratch[channel] / Double(count) }
            }
            for channel in result.indices { result[channel] = sqrt(powers[channel]) }
        }
        @inline(__always) private func point(_ position: SIMD3<Double>, into result: UnsafeMutableBufferPointer<Double>) {
            guard let low = planes.first, let high = planes.last else { return }
            let height = max(0, min(1, position.z))
            if planes.count == 1 { rowWeights(plane: low, position: position, gain: 1, into: result) }
            else {
                let angle = height * .pi / 2
                rowWeights(plane: low, position: position, gain: cos(angle), into: result)
                rowWeights(plane: high, position: position, gain: sin(angle), into: result)
            }
        }
        @inline(__always) private func rowWeights(plane: Plane, position: SIMD3<Double>, gain: Double, into result: UnsafeMutableBufferPointer<Double>) {
            guard gain != 0, let first = plane.rows.first, let last = plane.rows.last else { return }
            if position.y <= first.y { lateral(row: first, x: position.x, gain: gain, into: result); return }
            if position.y >= last.y { lateral(row: last, x: position.x, gain: gain, into: result); return }
            for index in 0..<(plane.rows.count - 1) where position.y >= plane.rows[index].y && position.y <= plane.rows[index + 1].y {
                let a = plane.rows[index], b = plane.rows[index + 1]
                let angle = (position.y - a.y) / (b.y - a.y) * .pi / 2
                lateral(row: a, x: position.x, gain: gain * cos(angle), into: result)
                lateral(row: b, x: position.x, gain: gain * sin(angle), into: result)
                return
            }
        }
        @inline(__always) private func lateral(row: Row, x: Double, gain: Double, into result: UnsafeMutableBufferPointer<Double>) {
            guard let first = row.channels.first, let last = row.channels.last else { return }
            if row.channels.count == 1 || x <= row.x[0] { result[first] += gain; return }
            if x >= row.x[row.x.count - 1] { result[last] += gain; return }
            for index in 0..<(row.channels.count - 1) {
                let a = row.channels[index], b = row.channels[index + 1]
                let left = row.x[index], right = row.x[index + 1]
                if x >= left && x <= right {
                    let angle = (x - left) / (right - left) * .pi / 2
                    result[a] += gain * cos(angle); result[b] += gain * sin(angle); return
                }
            }
        }
        @inline(__always) private func lengthSquared(_ value: SIMD3<Double>) -> Double { value.x * value.x + value.y * value.y + value.z * value.z }
        @inline(__always) private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
    }

    private struct StereoPhase: Codable, Sendable {
        var left = [Double](repeating: 0, count: 63)
        var right = [Double](repeating: 0, count: 63)
        var surround = [Double](repeating: 0, count: 63)
        var cursor = 0
        var valid: Bool {
            left.count == 63 && right.count == 63 && surround.count == 63 && (0..<63).contains(cursor)
                && left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite) && surround.allSatisfy(\.isFinite)
        }
        private static let coefficients = (0..<63).map { tap -> Double in
            let offset = tap - 31
            guard offset != 0, abs(offset) % 2 == 1 else { return 0 }
            let window = 0.54 + 0.46 * cos(Double.pi * Double(offset) / 31)
            return 2 / (Double.pi * Double(offset)) * window
        }
        mutating func process(left inputLeft: Double, right inputRight: Double, surround inputSurround: Double) -> (Double, Double, Double) {
            left[cursor] = inputLeft; right[cursor] = inputRight; surround[cursor] = inputSurround
            var phase = 0.0
            for tap in 0..<63 where Self.coefficients[tap] != 0 {
                phase += Self.coefficients[tap] * surround[(cursor - tap + 63) % 63]
            }
            let delayed = (cursor - 31 + 63) % 63
            let result = (left[delayed], right[delayed], phase)
            cursor = (cursor + 1) % 63
            return result
        }
    }
}
