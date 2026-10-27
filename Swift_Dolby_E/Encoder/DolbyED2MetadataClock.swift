// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Retimes the independent scene controls to this implementation's decoded PCM
/// timeline. These delays are measured full encoder/decoder impulse delays for
/// eight-mono coding, not a claim about an external presentation renderer's latency.
///
/// Three bounded source scenes and one boundary value per object are retained.
/// Output ramps target the delayed trajectory at the END of each 256-sample
/// interval: storing the trajectory's beginning as a ramp target would add an
/// unintended extra interval of delay. Activity is conservative over an interval
/// so a quantized control point cannot mute an audio onset inside that interval.
struct DolbyED2MetadataClock: Codable, Sendable {
    let frameRate: DolbyEFrameRate
    var delaySamples: Int {
        switch frameRate {
        case .fps23976: 556
        case .fps24: 555
        case .fps25: 534
        case .fps2997, .fps30: 437
        }
    }
    private struct TimedScene: Codable, Sendable {
        let start: Int64
        let frames: Int
        let scene: DolbyED2SceneMetadata
        var end: Int64 { start + Int64(frames) }
    }
    private var nextSample: Int64 = 0
    private var history: [TimedScene] = []
    private var anchor: [DolbyED2ObjectState] = []

    init(frameRate: DolbyEFrameRate) { self.frameRate = frameRate }

    mutating func shift(scene: DolbyED2SceneMetadata, frameCount: Int) throws -> DolbyED2SceneMetadata {
        // Work on a value copy, committing the metadata clock only on success.
        var next = self
        let result = try next.shiftInPlace(scene: scene, frameCount: frameCount)
        self = next
        return result
    }

    private mutating func shiftInPlace(scene: DolbyED2SceneMetadata, frameCount: Int) throws -> DolbyED2SceneMetadata {
        try scene.validate()
        guard (1600...2002).contains(frameCount), nextSample >= 0, history.count <= 3,
              history.allSatisfy({ $0.start >= 0 && (1600...2002).contains($0.frames) && $0.start <= Int64.max - Int64($0.frames) }),
              history.last?.end == nextSample || history.isEmpty && nextSample == 0,
              scene.objects.allSatisfy({ $0.states.first?.sampleOffset == 0 && $0.states.allSatisfy({ $0.sampleOffset < frameCount }) }) else {
            throw DolbyEError.malformed("ED2 metadata clock cadence, state or source update range")
        }
        for index in history.indices {
            try history[index].scene.validate()
            guard topology(scene, matches: history[index].scene),
                  history[index].scene.objects.allSatisfy({ $0.states.first?.sampleOffset == 0 && $0.states.allSatisfy({ $0.sampleOffset < history[index].frames }) }) else {
                throw DolbyEError.malformed("ED2 metadata clock retained topology or source update range")
            }
            if index > 0, history[index - 1].end != history[index].start {
                throw DolbyEError.malformed("ED2 metadata clock history is not contiguous")
            }
        }
        if let previous = history.last?.scene {
            guard topology(scene, matches: previous) else {
                throw DolbyEError.unsupported("ED2 metadata clock requires stable source, bed and presentation mappings")
            }
        }
        if history.isEmpty {
            anchor = scene.objects.map { object in
                var value = object.states[0]
                value.active = false; value.sampleOffset = 0; value.rampDuration = 0
                return value
            }
        }
        guard anchor.count == scene.objects.count else { throw DolbyEError.malformed("ED2 metadata clock anchor count") }
        for state in anchor {
            try state.position.validate()
            guard state.gain.isFinite, state.gain >= 0, (0...1).contains(state.size) else {
                throw DolbyEError.malformed("ED2 metadata clock anchor values")
            }
        }
        if history.count == 3 {
            let boundary = history[1].start
            anchor = scene.objects.indices.map { evaluate(object: $0, at: boundary, includeBoundary: false) }
            history.removeFirst()
        }
        let end = nextSample.addingReportingOverflow(Int64(frameCount))
        guard !end.overflow else { throw DolbyEError.invalidArgument("ED2 metadata clock overflow") }
        let start = nextSample
        history.append(TimedScene(start: start, frames: frameCount, scene: scene))
        nextSample = end.partialValue
        let delayedStart = start - Int64(delaySamples)
        let decoration = history.last(where: { $0.start <= max(0, delayedStart) })?.scene ?? scene
        var result = decoration
        let blocks = (frameCount + 255) / 256
        for object in result.objects.indices {
            var states: [DolbyED2ObjectState] = []
            for block in 0..<blocks {
                let offset = block * 256, duration = min(256, frameCount - offset)
                let sourceStart = start + Int64(offset) - Int64(delaySamples)
                let sourceEnd = sourceStart + Int64(duration)
                var target = evaluate(object: object, at: sourceEnd)
                let audible = activeValue(object: object, from: sourceStart, through: sourceEnd - 1)
                if let audible {
                    // Gain controls at zero/inactive points must not mute the
                    // real codec PCM that begins later in this same interval.
                    if !target.active || target.gain == 0 {
                        target.gain = audible.gain
                        if sourceEnd <= 0 { target.position = audible.position; target.size = audible.size }
                    }
                    target.active = true
                } else { target.active = false }
                target.sampleOffset = offset
                target.rampDuration = duration
                states.append(target)
            }
            result.objects[object].states = states
        }
        try result.validate()
        return result
    }

    private func topology(_ a: DolbyED2SceneMetadata, matches b: DolbyED2SceneMetadata) -> Bool {
        guard a.programID == b.programID, a.beds.count == b.beds.count, a.objects.count == b.objects.count,
              a.presentations == b.presentations else { return false }
        for index in a.beds.indices {
            guard a.beds[index] == b.beds[index] else { return false }
        }
        for index in a.objects.indices {
            guard a.objects[index].source == b.objects[index].source,
                  a.objects[index].isDialogue == b.objects[index].isDialogue,
                  a.objects[index].alternatives == b.objects[index].alternatives else { return false }
        }
        return true
    }

    /// The anchor is the continuous value just before the oldest retained
    /// scene's first control. Keeping it avoids losing an unfinished ramp when
    /// the oldest complete scene is removed from the bounded history.
    private func evaluate(object: Int, at sample: Int64, includeBoundary: Bool = true) -> DolbyED2ObjectState {
        var origin = anchor[object], target = origin
        var eventStart = history.first?.start ?? 0
        if sample < 0 {
            target.active = false; target.rampDuration = 0; target.sampleOffset = 0
            return target
        }
        for frame in history {
            for value in frame.scene.objects[object].states {
                let time = frame.start + Int64(value.sampleOffset)
                guard time < sample || includeBoundary && time == sample else { continue }
                origin = interpolate(origin: origin, target: target, elapsed: time - eventStart)
                target = value
                if !target.active {
                    // An inactive update may reset its nominal coordinates;
                    // retain the last actual position through silence/tails.
                    target.position = origin.position; target.size = origin.size
                }
                eventStart = time
            }
        }
        return interpolate(origin: origin, target: target, elapsed: sample - eventStart)
    }

    private func interpolate(origin: DolbyED2ObjectState, target: DolbyED2ObjectState, elapsed: Int64) -> DolbyED2ObjectState {
        let fraction = target.rampDuration == 0 ? 1 : max(0, min(1, Double(elapsed) / Double(target.rampDuration)))
        var value = target
        value.position = .init(x: origin.position.x + (target.position.x - origin.position.x) * fraction,
            y: origin.position.y + (target.position.y - origin.position.y) * fraction,
            z: origin.position.z + (target.position.z - origin.position.z) * fraction)
        value.gain = origin.gain + (target.gain - origin.gain) * fraction
        value.size = origin.size + (target.size - origin.size) * fraction
        value.snap = target.snap && fraction == 1
        value.sampleOffset = 0; value.rampDuration = 0
        return value
    }

    private func activeValue(object: Int, from first: Int64, through last: Int64) -> DolbyED2ObjectState? {
        guard last >= 0, last >= first else { return nil }
        let first = max(0, first)
        let a = evaluate(object: object, at: first), b = evaluate(object: object, at: last)
        var candidate: DolbyED2ObjectState?
        if a.active && a.gain > 0 { candidate = a }
        if b.active && b.gain > (candidate?.gain ?? 0) { candidate = b }
        for frame in history {
            for value in frame.scene.objects[object].states {
                let time = frame.start + Int64(value.sampleOffset)
                if time >= first, time <= last, value.active, value.gain > (candidate?.gain ?? 0) { candidate = value }
            }
        }
        return candidate
    }
}
