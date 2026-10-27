// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyED2DecodedPCM: Sendable {
    /// Bed and object signals in substream order, before presentation rendering.
    public let samples: [Double]
    public let scene: DolbyED2SceneMetadata
    public let frameNumber: UInt16
}

/// Two independent full-band codec states advance together. A failure in one
/// substream never commits only half of a decoded system frame.
public struct DolbyED2PCMFrameDecoder: Codable, Sendable {
    public let frameRate: DolbyEFrameRate
    private var first: DolbyEPCMFrameDecoder
    private var second: DolbyEPCMFrameDecoder
    public init(frameRate: DolbyEFrameRate, startingAtFrame: UInt64 = 0) throws {
        self.frameRate = frameRate
        first = try DolbyEPCMFrameDecoder(program: .eightMono, frameRate: frameRate, startingAtFrame: startingAtFrame)
        second = try DolbyEPCMFrameDecoder(program: .eightMono, frameRate: frameRate, startingAtFrame: startingAtFrame)
    }
    public mutating func decode(_ frame: DolbyED2CarrierFrame) throws -> DolbyED2DecodedPCM {
        guard frame.frameRate == frameRate else { throw DolbyEError.malformed("ED2 frame rate changed") }
        var a = first, b = second
        let x = try a.decode(frame.first), y = try b.decode(frame.second)
        guard x.count == y.count, x.count % 8 == 0 else { throw DolbyEError.malformed("ED2 substream sample clocks disagree") }
        var output = [Double](); output.reserveCapacity(x.count + y.count)
        for offset in stride(from: 0, to: x.count, by: 8) {
            output += x[offset..<(offset + 8)]
            output += y[offset..<(offset + 8)]
        }
        first = a; second = b
        return DolbyED2DecodedPCM(samples: output, scene: frame.scene, frameNumber: frame.frameNumber)
    }
}
