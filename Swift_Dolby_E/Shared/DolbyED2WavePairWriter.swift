// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// One BWF/RF64 file for each AES3 substream. Both synchronized files reach
/// the same durable boundary before the file worker saves its checkpoint.
final class DolbyED2WavePairWriter {
    struct Checkpoint: Codable, Sendable {
        let first: DolbyEWaveWriter.Checkpoint
        let second: DolbyEWaveWriter.Checkpoint
        let companionFileName: String
        var dataBytes: UInt64 { first.dataBytes + second.dataBytes }
    }
    let companionURL: URL
    private let first: DolbyEWaveWriter
    private let second: DolbyEWaveWriter
    var dataBytes: UInt64 { first.dataBytes + second.dataBytes }

    init(url: URL, companionURL override: URL?, description: String) throws {
        let other = override ?? DolbyED2CompanionFile.url(for: url)
        try Self.paths(url, other)
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: other.path) else {
            throw DolbyEError.invalidArgument("an ED2 WAV substream file already exists")
        }
        self.companionURL = other
        self.first = try DolbyEWaveWriter(url: url, channelCount: 2, dolbyE: true, description: description + "; AES1 of 2")
        self.second = try DolbyEWaveWriter(url: other, channelCount: 2, dolbyE: true, description: description + "; AES2 of 2")
    }
    init(resuming url: URL, companionURL override: URL?, checkpoint: Checkpoint, recoveringFinalization: Bool) throws {
        let name = checkpoint.companionFileName
        guard !name.isEmpty, name != ".", name != "..", URL(fileURLWithPath: name).lastPathComponent == name,
              checkpoint.first.channelCount == 2, checkpoint.second.channelCount == 2,
              checkpoint.first.dataBytes == checkpoint.second.dataBytes else { throw DolbyEError.malformed("ED2 WAV pair checkpoint") }
        let other = override ?? url.deletingLastPathComponent().appendingPathComponent(name)
        try Self.paths(url, other)
        guard other.lastPathComponent == name else { throw DolbyEError.malformed("ED2 WAV companion recovery name changed") }
        self.companionURL = other
        self.first = try DolbyEWaveWriter(resuming: url, checkpoint: checkpoint.first, recoveringFinalization: recoveringFinalization)
        self.second = try DolbyEWaveWriter(resuming: other, checkpoint: checkpoint.second, recoveringFinalization: recoveringFinalization)
    }
    private static func paths(_ a: URL, _ b: URL) throws {
        guard a.standardizedFileURL.resolvingSymlinksInPath() != b.standardizedFileURL.resolvingSymlinksInPath(),
              a.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                == b.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() else {
            throw DolbyEError.invalidArgument("ED2 WAV pair must use distinct adjacent files")
        }
    }
    func appendCarrier(_ words: [UInt32]) throws {
        guard words.count <= 8192, words.count % 4 == 0, words.allSatisfy({ $0 & 255 == 0 }) else {
            throw DolbyEError.invalidArgument("ED2 WAV pair requires complete interleaved AES1/AES2 words")
        }
        var a = [UInt32](), b = [UInt32]()
        a.reserveCapacity(words.count / 2); b.reserveCapacity(words.count / 2)
        for index in stride(from: 0, to: words.count, by: 4) {
            a += words[index..<(index + 2)]; b += words[(index + 2)..<(index + 4)]
        }
        try first.appendCarrier(a); try second.appendCarrier(b)
    }
    func checkpoint() throws -> Checkpoint {
        let a = try first.checkpoint(), b = try second.checkpoint()
        guard a.dataBytes == b.dataBytes else { throw DolbyEError.malformed("ED2 WAV substreams are not at the same durable sample") }
        return Checkpoint(first: a, second: b, companionFileName: companionURL.lastPathComponent)
    }
    func finish() throws { try first.finish(); try second.finish() }
}
