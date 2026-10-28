// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import SwiftUI
import Combine
import DolbyEDecoder

/// Display-only ballistics. Audio peaks remain untouched; playback epochs and
/// stopped states clear the display immediately instead of inheriting old peaks.
struct DolbyEMeterDisplayFrame: Sendable {
    let generation: UUID?
    let active: Bool
    let start: Double
    let startDate: Date
    let initial: [Float]
    let target: [Float]
    let readouts: [String]

    static func silent(channels: Int) -> Self {
        let floor = [Float](repeating: -96, count: channels)
        return .init(generation: nil, active: false, start: 0, startDate: Date(), initial: floor, target: floor,
                     readouts: Array(repeating: "−∞", count: channels))
    }
    func levels(at time: Double) -> [Float] {
        guard active else { return [Float](repeating: -96, count: target.count) }
        let elapsed = max(0, time - start)
        let attack = Float(1 - exp(-elapsed / 0.008)), release = Float(1 - exp(-elapsed / 0.18))
        return target.indices.map { index in
            let before = initial[index], after = target[index]
            return before + (after - before) * (after > before ? attack : release)
        }
    }
}

@MainActor
final class DolbyEMeterDisplayModel: ObservableObject {
    @Published private(set) var active = false
    @Published private var channelCount = 6
    private(set) var frame = DolbyEMeterDisplayFrame.silent(channels: 6)

    func reset(channels: Int) {
        frame = .silent(channels: channels)
        if active { active = false }
        if channelCount != channels { channelCount = channels }
    }
    func receive(_ update: DolbyEPlaybackMeterSnapshot) {
        apply(levels: update.levels, active: update.playing, generation: update.generation,
              time: ProcessInfo.processInfo.systemUptime)
    }
    func apply(levels: [Float], active: Bool, generation: UUID, time: Double) {
        let target = levels.map { $0.isFinite ? max(-96, $0) : -96 }
        guard active else { reset(channels: target.count); return }
        let prior = frame.active && frame.generation == generation && frame.target.count == target.count
            ? frame.levels(at: time) : [Float](repeating: -96, count: target.count)
        // Data arrival does not trigger a second draw between display ticks.
        // Only start/stop and topology changes invalidate the animation schedule.
        frame = .init(generation: generation, active: true, start: time, startDate: Date(), initial: prior, target: target,
                      readouts: target.map { $0 > -95 ? String(format: "%.1f", $0) : "−∞" })
        if !self.active { self.active = true }
        if channelCount != target.count { channelCount = target.count }
    }
}

/// One independently scheduled canvas replaces sixteen layout/mask trees.
/// Only this child observes meter updates; transport and metadata stay idle.
struct DolbyEMeterCanvas: View {
    @ObservedObject var model: DolbyEMeterDisplayModel
    var drawObserver: (@Sendable (Double) -> Void)? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.active)) { timeline in
            let frame = model.frame
            // Reading the timeline date is required for SwiftUI to invalidate
            // the canvas between audio events. Rebase each event to its own
            // receipt clock so a wall-clock adjustment cannot persist across it.
            let displayTime = frame.start + max(0, timeline.date.timeIntervalSince(frame.startDate))
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let time = ProcessInfo.processInfo.systemUptime
                drawObserver?(time)
                let levels = frame.levels(at: displayTime)
                guard !levels.isEmpty else { return }
                let gap = 8.0, column = max(1, (size.width - Double(levels.count - 1) * gap) / Double(levels.count))
                let top = 24.0, height = max(1, size.height - top)
                for index in levels.indices {
                    let x = Double(index) * (column + gap)
                    let bounds = CGRect(x: x, y: top, width: column, height: height)
                    let path = Path(roundedRect: bounds, cornerRadius: 4)
                    context.fill(path, with: .color(.white.opacity(0.05)))
                    let fraction = Double(max(0, min(1, (levels[index] + 60) / 60)))
                    var bar = context
                    bar.clip(to: Path(CGRect(x: x, y: top + height * (1 - fraction), width: column, height: height * fraction)))
                    bar.fill(path, with: .linearGradient(Gradient(colors: [.green, .green, .yellow, .red]),
                        startPoint: CGPoint(x: x, y: top + height), endPoint: CGPoint(x: x, y: top)))
                    let text = Text(frame.readouts[index]).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(frame.target[index] > 0 ? .red : .secondary)
                    context.draw(text, at: CGPoint(x: x + column / 2, y: 0), anchor: .top)
                }
            }
        }.frame(height: 214)
    }
}
