// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Speaker identities shared by playback and rendered file requests. The
/// transport's bed/object signal order is distinct from these output feeds.
public enum DolbyESpeaker: String, CaseIterable, Codable, Sendable {
    case left = "L", right = "R", center = "C", lfe = "LFE", leftSide = "Ls", rightSide = "Rs"
    case leftBack = "Lrs", rightBack = "Rrs", leftExtra = "Le", rightExtra = "Re"
    case topFrontLeft = "Tfl", topFrontRight = "Tfr", topBackLeft = "Tbl", topBackRight = "Tbr"
    case topMiddleLeft = "Tml", topMiddleRight = "Tmr", wideLeft = "Lw", wideRight = "Rw"
    var position: SIMD3<Double> {
        switch self {
        case .left: SIMD3(-1, 1, 0)
        case .right: SIMD3(1, 1, 0)
        case .center, .lfe: SIMD3(0, 1, 0)
        case .leftSide: SIMD3(-1, 0, 0)
        case .rightSide: SIMD3(1, 0, 0)
        case .leftBack: SIMD3(-1, -1, 0)
        case .rightBack: SIMD3(1, -1, 0)
        case .leftExtra: SIMD3(-0.5, 1, 0)
        case .rightExtra: SIMD3(0.5, 1, 0)
        case .wideLeft: SIMD3(-1, 0.5, 0)
        case .wideRight: SIMD3(1, 0.5, 0)
        case .topFrontLeft: SIMD3(-1, 1, 1)
        case .topFrontRight: SIMD3(1, 1, 1)
        case .topBackLeft: SIMD3(-1, -1, 1)
        case .topBackRight: SIMD3(1, -1, 1)
        case .topMiddleLeft: SIMD3(-1, 0, 1)
        case .topMiddleRight: SIMD3(1, 0, 1)
        }
    }
}

public enum DolbyEPlaybackLayout: String, CaseIterable, Codable, Sendable {
    case stereo = "2.0", fiveOne = "5.1", sevenOne = "7.1", sevenOneScreen = "7.1-scrn", fiveOneTwo = "5.1.2", fiveOneFour = "5.1.4"
    case sevenOneTwo = "7.1.2", sevenOneFour = "7.1.4", sevenOneSix = "7.1.6", nineOneSix = "9.1.6"
    public var speakers: [DolbyESpeaker] {
        if self == .stereo { return [.left, .right] }
        if self == .sevenOneScreen { return [.left, .right, .center, .lfe, .leftSide, .rightSide, .leftExtra, .rightExtra] }
        let five = rawValue.hasPrefix("5.")
        var output: [DolbyESpeaker] = [.left, .right, .center, .lfe, .leftSide, .rightSide]
        if !five { output += [.leftBack, .rightBack] }
        if rawValue.hasSuffix(".4") || rawValue.hasSuffix(".6") { output += [.topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight] }
        if rawValue.hasSuffix(".2") || rawValue.hasSuffix(".6") { output += [.topMiddleLeft, .topMiddleRight] }
        if self == .nineOneSix { output += [.wideLeft, .wideRight] }
        return output
    }
    public var physicalOrder: [DolbyESpeaker] {
        if self == .stereo || self == .sevenOneScreen || rawValue.hasPrefix("5.") { return speakers }
        return [.left, .right, .center, .lfe, .leftBack, .rightBack, .leftSide, .rightSide] + speakers.dropFirst(8)
    }
}
