// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyED2CarrierFrame: Sendable {
    public let first: DolbyECarrierFrame
    public let second: DolbyECarrierFrame
    public let metadata: [DolbyED2MetadataContainer]
    public let scene: DolbyED2SceneMetadata
    public var frameRate: DolbyEFrameRate { first.frameRate }
    public var frameNumber: UInt16 { first.frameNumber }

    public init(first: DolbyECarrierFrame, second: DolbyECarrierFrame) throws {
        guard first.program == .eightMono, second.program == .eightMono,
              first.frameRate == second.frameRate, first.frameNumber == second.frameNumber else {
            throw DolbyEError.malformed("ED2 substreams do not share an eight-signal frame and clock")
        }
        let a = try DolbyED2MetadataContainer.parse(words: first.evolutionWords).verifying(coreWords: first.coreWords)
        let b = try DolbyED2MetadataContainer.parse(words: second.evolutionWords).verifying(coreWords: second.coreWords)
        guard let scene = try a.scene() else {
            throw DolbyEError.invalidArgument("ED2 input pair one must contain the presentation topology")
        }
        if let other = try b.scene(), other != scene {
            throw DolbyEError.malformed("ED2 substreams contain conflicting presentation topology")
        }
        try scene.validate()
        self.first = first; self.second = second; self.metadata = [a, b]; self.scene = scene
    }
}

/// Owns two bounded AES cursors. Acquisition can discard unmatched leading
/// frames; after lock, a missing or reordered frame is an explicit error.
/// This synchronization is separate from the codec's signed-counter DSP rule.
public final class DolbyED2CarrierReader {
    public let first: DolbyEWaveCarrierReader
    public let second: DolbyEWaveCarrierReader
    public let sourceURLs: [URL]
    public private(set) var discardedLeadingFrames = [UInt64](repeating: 0, count: 2)
    private var acquired = false

    public init(url: URL, secondaryURL: URL? = nil) throws {
        let a = try DolbyEWaveCarrierReader(url: url)
        var peer = secondaryURL
        if peer == nil, a.info.channelCount == 2 {
            let candidate = DolbyED2CompanionFile.url(for: url)
            if FileManager.default.fileExists(atPath: candidate.path) { peer = candidate }
        }
        if let secondaryURL = peer {
            guard url.standardizedFileURL.resolvingSymlinksInPath() != secondaryURL.standardizedFileURL.resolvingSymlinksInPath(),
                  a.info.channelCount == 2 else { throw DolbyEError.invalidArgument("separate ED2 inputs must be distinct AES3-pair files") }
            let b = try DolbyEWaveCarrierReader(url: secondaryURL)
            guard b.info.channelCount == 2 else { throw DolbyEError.invalidArgument("secondary ED2 input must contain one AES3 pair") }
            self.second = b; self.sourceURLs = [url, secondaryURL]
        } else {
            guard a.info.channelCount == 4 else { throw DolbyEError.invalidArgument("ED2 decoding needs a multiplexed carrier or --input-pri AES1 --input-exp AES2") }
            self.second = try DolbyEWaveCarrierReader(url: url, pairIndex: 1)
            self.sourceURLs = [url]
        }
        self.first = a
    }

    public func seek(firstWord: UInt64, secondWord: UInt64,
                     firstBoundaries: DolbyEStreamBoundaryInfo? = nil,
                     secondBoundaries: DolbyEStreamBoundaryInfo? = nil,
                     discardedLeadingFrames: [UInt64] = [0, 0]) throws {
        guard discardedLeadingFrames.count == 2 else { throw DolbyEError.malformed("ED2 acquisition checkpoint") }
        try first.seek(toWord: firstWord, restoring: firstBoundaries)
        try second.seek(toWord: secondWord, restoring: secondBoundaries)
        self.discardedLeadingFrames = discardedLeadingFrames
        acquired = firstWord != 0 || secondWord != 0
    }

    public func readFrame() throws -> DolbyED2CarrierFrame? {
        let a = first.wordPosition, b = second.wordPosition
        let firstBoundary = first.boundaryInfo, secondBoundary = second.boundaryInfo
        let locked = acquired, discarded = discardedLeadingFrames
        do { return try readNextFrame() }
        catch {
            // Pair acquisition and both AES reads commit as one operation.
            // Cancelling the second read cannot leave the first one a frame
            // ahead and turn the next play into a false clock/integrity error.
            try seek(firstWord: a, secondWord: b, firstBoundaries: firstBoundary,
                secondBoundaries: secondBoundary, discardedLeadingFrames: discarded)
            acquired = locked
            throw error
        }
    }

    private func readNextFrame() throws -> DolbyED2CarrierFrame? {
        var a = try first.readFrame(), b = try second.readFrame()
        if a == nil && b == nil { return nil }
        guard a != nil, b != nil else { throw DolbyEError.malformed("one ED2 substream ended before its companion") }
        if !acquired {
            var skipped = 0
            while a!.frameNumber != b!.frameNumber {
                guard skipped < 1024, a!.frameRate == b!.frameRate else { throw DolbyEError.malformed("ED2 substreams cannot acquire a common clock") }
                let difference = Int16(bitPattern: a!.frameNumber &- b!.frameNumber)
                if difference < 0 { a = try first.readFrame(); discardedLeadingFrames[0] += 1 }
                else { b = try second.readFrame(); discardedLeadingFrames[1] += 1 }
                guard a != nil, b != nil else { throw DolbyEError.malformed("ED2 substream ended while aligning its clock") }
                skipped += 1
            }
        }
        let frame = try DolbyED2CarrierFrame(first: a!, second: b!)
        acquired = true
        return frame
    }
}

public struct DolbyED2CarrierProbe: Codable, Sendable {
    public let encodeVision: DolbyEEncodeVision
    public let frameRate: DolbyEFrameRate
    public let firstFrameNumber: UInt16
    public let carrierChannels: Int
    public let elementChannels: Int
    public let sectionCRCsVerified: Bool
    public let metadataCRCsVerified: Bool
    public let authenticationVerified: Bool
    public let scene: DolbyED2SceneMetadata
    public let discardedLeadingFrames: [UInt64]

    public init(url: URL, secondaryURL: URL? = nil) throws {
        let reader = try DolbyED2CarrierReader(url: url, secondaryURL: secondaryURL)
        guard let frame = try reader.readFrame() else { throw DolbyEError.malformed("no complete ED2 frame pair") }
        frameRate = frame.frameRate; firstFrameNumber = frame.frameNumber
        encodeVision = .ed2; elementChannels = 16
        carrierChannels = 4
        sectionCRCsVerified = true
        metadataCRCsVerified = frame.metadata.allSatisfy(\.crcVerified)
        authenticationVerified = frame.metadata.allSatisfy(\.authenticationVerified)
        scene = frame.scene; discardedLeadingFrames = reader.discardedLeadingFrames
    }
}
