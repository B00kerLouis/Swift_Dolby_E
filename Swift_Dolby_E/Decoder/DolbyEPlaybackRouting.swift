// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

extension DolbyESpeaker {
    /// Decoder GUI labels only. Raw values, transport order and PCM routing
    /// retain their established identities in both self-contained frameworks.
    public func monitorName(in speakers: [DolbyESpeaker]) -> String {
        switch self {
        case .topFrontLeft: "Ltf"
        case .topFrontRight: "Rtf"
        case .topBackLeft: "Ltr"
        case .topBackRight: "Rtr"
        case .topMiddleLeft: "Ltm"
        case .topMiddleRight: "Rtm"
        case .leftSide: speakers.contains(.leftBack) ? "Lss" : "Ls"
        case .rightSide: speakers.contains(.rightBack) ? "Rss" : "Rs"
        default: rawValue
        }
    }
}

/// The render layout describes the QC feeds. Monitoring is a separate choice
/// applied afterwards, so a small endpoint never limits object rendering.
public enum DolbyEMonitorMode: String, CaseIterable, Codable, Sendable {
    case direct, downmix, meters
    public var displayName: String {
        switch self {
        case .direct: "Direct Channels"
        case .downmix: "Downmix to Device"
        case .meters: "QC Meters Only"
        }
    }
}

public struct DolbyEProgramPCM: Sendable {
    public let speakers: [DolbyESpeaker]
    public let samples: [Double]
}

/// Labelled PCM routing shared by real-time playback and framework clients.
/// Exact speaker matches are retained; LFE never enters a non-LFE feed. Height
/// layouts retain their own slots even when the current Dolby E program has
/// no height content. No ED2 elements or object positions are fabricated.
public enum DolbyEPlaybackRouting {
    /// Renderer lane N is driver lane N. Extra driver lanes are zero-filled;
    /// speaker labels never reorder or reject discrete virtual audio endpoints.
    public static func direct(_ pcm: [Float], inputChannels: Int, outputChannels: Int,
                              solo: Int? = nil) throws -> [Float] {
        guard (1...16).contains(inputChannels), (1...16).contains(outputChannels),
              pcm.count % inputChannels == 0, pcm.count <= 8192 * inputChannels,
              pcm.allSatisfy(\.isFinite), solo == nil || (0..<inputChannels).contains(solo!) else {
            throw DolbyEError.invalidArgument("invalid discrete playback PCM")
        }
        if inputChannels == outputChannels, solo == nil { return pcm }
        let frames = pcm.count / inputChannels
        var output = [Float](repeating: 0, count: frames * outputChannels)
        for frame in 0..<frames {
            for channel in 0..<min(inputChannels, outputChannels) where solo == nil || channel == solo {
                output[frame * outputChannels + channel] = pcm[frame * inputChannels + channel]
            }
        }
        return output
    }

    public static func selectProgram(_ pcm: [Double], configuration: DolbyEProgram, index: Int) throws -> DolbyEProgramPCM {
        guard pcm.count % 8 == 0, pcm.count <= 8192 * 8, pcm.allSatisfy(\.isFinite),
              configuration.programChannelCounts.indices.contains(index) else { throw DolbyEError.invalidArgument("the Dolby E stream does not contain that program") }
        let speakers: [DolbyESpeaker]
        let first: Int
        if configuration == .eightMono {
            speakers = [.center]; first = index
        } else if configuration == .fiveOnePlusTwo {
            speakers = index == 0 ? [.left, .right, .center, .lfe, .leftSide, .rightSide] : [.left, .right]
            first = index == 0 ? 0 : 6
        } else {
            speakers = [.left, .right, .center, .lfe, .leftSide, .rightSide, .leftExtra, .rightExtra]; first = 0
        }
        var samples = [Double](); samples.reserveCapacity(pcm.count / 8 * speakers.count)
        for frame in 0..<(pcm.count / 8) { for channel in first..<(first + speakers.count) { samples.append(pcm[frame * 8 + channel]) } }
        return DolbyEProgramPCM(speakers: speakers, samples: samples)
    }
    public static func render(_ pcm: [Double], source: [DolbyESpeaker], destination: [DolbyESpeaker],
                              centerLevel: Double = sqrt(0.5), surroundLevel: Double = sqrt(0.5),
                              monitorMode: DolbyEMonitorMode = .downmix) throws -> [Float] {
        guard !source.isEmpty, source.count <= 16, !destination.isEmpty, destination.count <= 16,
              Set(source).count == source.count, Set(destination).count == destination.count,
              pcm.count % source.count == 0, pcm.count <= 8192 * source.count, pcm.allSatisfy(\.isFinite),
              centerLevel.isFinite, surroundLevel.isFinite else { throw DolbyEError.invalidArgument("invalid labelled playback PCM") }
        if monitorMode == .meters { return [Float](repeating: 0, count: pcm.count / source.count * destination.count) }
        var matrix = Array(repeating: [Double](repeating: 0, count: destination.count), count: source.count)
        for (index, speaker) in source.enumerated() {
            if let exact = destination.firstIndex(of: speaker) { matrix[index][exact] = 1; continue }
            if monitorMode == .direct { continue }
            if speaker == .lfe { continue }
            if destination == [.left, .right] {
                switch speaker {
                case .center: matrix[index] = [centerLevel, centerLevel]
                case .leftSide, .leftBack: matrix[index] = [surroundLevel, 0]
                case .rightSide, .rightBack: matrix[index] = [0, surroundLevel]
                case .leftExtra: matrix[index] = [sqrt(0.5) * (1 + centerLevel), sqrt(0.5) * centerLevel]
                case .wideLeft: matrix[index] = [1, 0]
                case .rightExtra: matrix[index] = [sqrt(0.5) * centerLevel, sqrt(0.5) * (1 + centerLevel)]
                case .wideRight: matrix[index] = [0, 1]
                default:
                    let x = (speaker.position.x + 1) * .pi / 4
                    matrix[index] = [cos(x) * surroundLevel, sin(x) * surroundLevel]
                }
                continue
            }
            let point = speaker.position
            let hasHeight = destination.contains { $0.position.z > 0 }
            let candidates = destination.indices.filter { destination[$0] != .lfe && (hasHeight ? destination[$0].position.z == point.z : destination[$0].position.z == 0) }
            guard !candidates.isEmpty else { throw DolbyEError.unsupported("output has no speaker plane for \(speaker.rawValue)") }
            let ordered = candidates.sorted {
                let a = destination[$0].position - point, b = destination[$1].position - point
                return a.x * a.x + a.y * a.y + a.z * a.z < b.x * b.x + b.y * b.y + b.z * b.z
            }
            let first = ordered[0]
            if ordered.count == 1 { matrix[index][first] = 1; continue }
            let second = ordered[1], a = destination[first].position, b = destination[second].position
            let direction = b - a
            let denominator = direction.x * direction.x + direction.y * direction.y + direction.z * direction.z
            let delta = point - a
            let fraction = denominator == 0 ? 0 : max(0, min(1, (delta.x * direction.x + delta.y * direction.y + delta.z * direction.z) / denominator))
            matrix[index][first] = cos(fraction * .pi / 2); matrix[index][second] = sin(fraction * .pi / 2)
        }
        if source == destination { return pcm.map(Float.init) }
        let sparse = matrix.map { row in row.enumerated().filter { $0.element != 0 }.map { (channel: $0.offset, gain: $0.element) } }
        var output = [Float](repeating: 0, count: pcm.count / source.count * destination.count)
        for frame in 0..<(pcm.count / source.count) {
            for input in source.indices {
                let sample = pcm[frame * source.count + input]
                for value in sparse[input] { output[frame * destination.count + value.channel] += Float(sample * value.gain) }
            }
        }
        guard output.allSatisfy(\.isFinite) else { throw DolbyEError.malformed("playback routing overflow") }
        return output
    }
}
