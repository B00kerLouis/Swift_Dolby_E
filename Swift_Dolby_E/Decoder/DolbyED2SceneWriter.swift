// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// An element-PCM export requires its moving object metadata. JSON Lines keeps
/// that information streamable and recoverable without buffering a programme.
final class DolbyED2SceneWriter {
    struct Checkpoint: Codable {
        let header: Data
        let byteCount: UInt64
        let records: UInt64
        let tailHash: String
    }
    private struct Header: Encodable {
        let format: String
        let version: Int
        let producer: String
        let identity: UUID
        let sampleRate: Int
        let channelCount: Int
        let channelOrder: String
        let frameRate: DolbyEFrameRate
    }
    private struct Record: Encodable {
        let samplePosition: UInt64
        let frameNumber: UInt16
        let authenticationVerified: Bool
        let scene: DolbyED2SceneMetadata
    }
    private let handle: FileHandle
    private let header: Data
    private var byteCount: UInt64
    private var records: UInt64 = 0
    private var finished = false

    init(url: URL, frameRate: DolbyEFrameRate) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(Header(format: "libdolbye.ed2.element-pcm", version: 1, producer: "libdolbye",
            identity: UUID(), sampleRate: 48000, channelCount: 16,
            channelOrder: "substream 0 signals 0...7, substream 1 signals 0...7; scene contains bed/object mappings", frameRate: frameRate)) + Data([10])
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DolbyEError.invalidArgument("ED2 metadata sidecar already exists or cannot be created")
        }
        let file = try FileHandle(forUpdating: url)
        do { try file.write(contentsOf: header) } catch { try? file.close(); throw error }
        self.header = header; self.handle = file; self.byteCount = UInt64(header.count)
    }
    init(resuming url: URL, checkpoint: Checkpoint) throws {
        try Self.validate(url, checkpoint: checkpoint, allowExtra: true)
        let file = try FileHandle(forUpdating: url)
        do { try file.truncate(atOffset: checkpoint.byteCount); try file.seek(toOffset: checkpoint.byteCount) }
        catch { try? file.close(); throw error }
        self.header = checkpoint.header; self.byteCount = checkpoint.byteCount
        self.records = checkpoint.records; self.handle = file
    }
    deinit { try? handle.close() }
    func append(scene: DolbyED2SceneMetadata, at sample: UInt64, frameNumber: UInt16) throws {
        guard !finished else { throw DolbyEError.invalidArgument("ED2 metadata sidecar is finalized") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Record(samplePosition: sample, frameNumber: frameNumber,
            authenticationVerified: true, scene: scene)) + Data([10])
        guard data.count <= 65536, byteCount <= UInt64.max - UInt64(data.count) else { throw DolbyEError.malformed("ED2 metadata sidecar record exceeds its bound") }
        try handle.write(contentsOf: data); byteCount += UInt64(data.count); records += 1
    }
    func checkpoint() throws -> Checkpoint {
        guard !finished else { throw DolbyEError.invalidArgument("ED2 metadata sidecar is finalized") }
        try handle.synchronize()
        let count = Int(min(byteCount, 65536))
        let data = try readBytes(handle, at: byteCount - UInt64(count), count: count)
        try handle.seek(toOffset: byteCount)
        return Checkpoint(header: header, byteCount: byteCount, records: records, tailHash: DolbyEFileJobStore.hash(data))
    }
    func finish() throws {
        guard !finished else { throw DolbyEError.invalidArgument("ED2 metadata sidecar is finalized") }
        try handle.synchronize(); try handle.close(); finished = true
    }
    static func validate(_ url: URL, checkpoint: Checkpoint, allowExtra: Bool = false) throws {
        guard checkpoint.header.count <= 4096, checkpoint.byteCount >= checkpoint.header.count else { throw DolbyEError.malformed("ED2 metadata sidecar checkpoint bounds") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd()
        guard (allowExtra ? size >= checkpoint.byteCount : size == checkpoint.byteCount),
              try readBytes(file, at: 0, count: checkpoint.header.count) == checkpoint.header else {
            throw DolbyEError.malformed("ED2 metadata sidecar identity or length changed")
        }
        let count = Int(min(checkpoint.byteCount, 65536))
        guard try DolbyEFileJobStore.hash(readBytes(file, at: checkpoint.byteCount - UInt64(count), count: count)) == checkpoint.tailHash else {
            throw DolbyEError.malformed("ED2 metadata sidecar durable tail changed")
        }
    }
}
