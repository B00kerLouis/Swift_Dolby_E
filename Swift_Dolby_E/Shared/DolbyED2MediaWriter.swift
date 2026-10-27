// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// ST 390 permits one essence track in each OP-Atom file. An ED2 system
/// therefore uses two companion files, each containing one complete AES pair.
/// The file worker owns coordinated final publication of these two outputs.
final class DolbyED2MediaWriter {
    struct Checkpoint: Codable, Sendable {
        let first: DolbyEMXFWriter.Checkpoint
        let second: DolbyEMXFWriter.Checkpoint
        let companionFileName: String
        var dataBytes: UInt64 { first.dataBytes + second.dataBytes }
    }

    let companionURL: URL
    private let first: DolbyEMXFWriter
    private let second: DolbyEMXFWriter
    var dataBytes: UInt64 { first.dataBytes + second.dataBytes }

    init(url: URL, companionURL override: URL?, rate: DolbyEFrameRate) throws {
        let companion = override ?? DolbyED2CompanionFile.url(for: url)
        guard url.standardizedFileURL.resolvingSymlinksInPath() != companion.standardizedFileURL.resolvingSymlinksInPath(),
              url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                == companion.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: companion.path) else {
            throw DolbyEError.invalidArgument("paired OP-Atom outputs must be distinct new files")
        }
        self.companionURL = companion
        self.first = try DolbyEMXFWriter(url: url, format: .mxfOPAtom, frameRate: rate, channelCount: 2, dolbyE: true)
        self.second = try DolbyEMXFWriter(url: companion, format: .mxfOPAtom, frameRate: rate, channelCount: 2, dolbyE: true)
    }

    init(resuming url: URL, companionURL override: URL?, checkpoint: Checkpoint, recoveringFinalization: Bool) throws {
        let name = checkpoint.companionFileName
        guard !name.isEmpty, name != ".", name != "..", URL(fileURLWithPath: name).lastPathComponent == name,
              checkpoint.first.format == .mxfOPAtom, checkpoint.second.format == .mxfOPAtom,
              checkpoint.first.channelCount == 2, checkpoint.second.channelCount == 2,
              checkpoint.first.compressed, checkpoint.second.compressed,
              checkpoint.first.rate == checkpoint.second.rate,
              checkpoint.first.dataBytes == checkpoint.second.dataBytes,
              checkpoint.first.videoFrames == checkpoint.second.videoFrames else {
            throw DolbyEError.malformed("inconsistent paired OP-Atom checkpoint")
        }
        let companion = override ?? url.deletingLastPathComponent().appendingPathComponent(name)
        guard companion.lastPathComponent == name,
              url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                == companion.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
              url.standardizedFileURL.resolvingSymlinksInPath() != companion.standardizedFileURL.resolvingSymlinksInPath() else {
            throw DolbyEError.malformed("paired OP-Atom recovery path changed")
        }
        self.companionURL = companion
        self.first = try DolbyEMXFWriter(resuming: url, checkpoint: checkpoint.first, recoveringFinalization: recoveringFinalization)
        self.second = try DolbyEMXFWriter(resuming: companion, checkpoint: checkpoint.second, recoveringFinalization: recoveringFinalization)
    }

    func appendCarrier(_ words: [UInt32]) throws {
        guard words.count <= 8192, words.count % 4 == 0, words.allSatisfy({ $0 & 255 == 0 }) else {
            throw DolbyEError.invalidArgument("ED2 OP-Atom write requires interleaved aligned words from two AES pairs")
        }
        var a = [UInt32](), b = [UInt32]()
        a.reserveCapacity(words.count / 2); b.reserveCapacity(words.count / 2)
        for sample in stride(from: 0, to: words.count, by: 4) {
            a += words[sample..<(sample + 2)]
            b += words[(sample + 2)..<(sample + 4)]
        }
        try first.appendCarrier(a)
        try second.appendCarrier(b)
    }

    func checkpoint() throws -> Checkpoint {
        // The caller persists only after both files have been synchronized.
        let a = try first.checkpoint(), b = try second.checkpoint()
        guard a.dataBytes == b.dataBytes, a.videoFrames == b.videoFrames else {
            throw DolbyEError.malformed("ED2 OP-Atom files are not at a common durable boundary")
        }
        return Checkpoint(first: a, second: b, companionFileName: companionURL.lastPathComponent)
    }

    func finish() throws {
        try first.finish()
        try second.finish()
    }
}
