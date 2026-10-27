// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Streaming 24-bit BWF writer. A reserved ds64 slot permits an in-place RF64
/// upgrade at finalization without moving or staging the audio data.
public final class DolbyEWaveWriter {
    public struct Checkpoint: Codable, Sendable {
        public let channelCount: Int
        public let header: Data
        public let dataBytes: UInt64
    }

    public let channelCount: Int
    public private(set) var dataBytes: UInt64 = 0
    private let handle: FileHandle
    private let header: Data
    private let dataSizeOffset: UInt64
    private var finished = false

    public init(url: URL, channelCount: Int, dolbyE: Bool, description: String,
                timeReference: UInt64 = 0, channelMask: UInt32 = 0) throws {
        guard (dolbyE ? [2, 4].contains(channelCount) : (1...16).contains(channelCount)),
              !FileManager.default.fileExists(atPath: url.path) else {
            throw DolbyEError.invalidArgument("invalid output channels or output file already exists")
        }
        var data = Data()
        func number(_ value: UInt64, _ bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func chunk(_ name: String, _ payload: Data) {
            data.append(contentsOf: name.utf8)
            data.append(number(UInt64(payload.count), 4))
            data.append(payload)
            if payload.count & 1 != 0 { data.append(0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        data.append(number(0, 4))
        data.append(contentsOf: "WAVE".utf8)
        chunk("JUNK", Data(repeating: 0, count: 28))
        let alignment = channelCount * 3
        var format = number(channelMask == 0 ? 1 : 0xfffe, 2) + number(UInt64(channelCount), 2) + number(48000, 4)
            + number(UInt64(48000 * alignment), 4) + number(UInt64(alignment), 2) + number(24, 2)
        if channelMask != 0 {
            guard channelMask.nonzeroBitCount == channelCount else { throw DolbyEError.invalidArgument("output speaker mask does not match channel count") }
            format += number(22, 2) + number(24, 2) + number(UInt64(channelMask), 4)
            format += Data([1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
        }
        chunk("fmt ", format)
        var broadcast = Data(repeating: 0, count: 602)
        func text(_ string: String, at offset: Int, count: Int) {
            let bytes = Array(string.utf8.prefix(count))
            broadcast.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        text(description, at: 0, count: 256)
        text("libdolbye", at: 256, count: 32)
        text(UUID().uuidString.replacingOccurrences(of: "-", with: ""), at: 288, count: 32)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        text(formatter.string(from: now), at: 320, count: 10)
        formatter.dateFormat = "HH:mm:ss"
        text(formatter.string(from: now), at: 330, count: 8)
        broadcast.replaceSubrange(338..<346, with: number(timeReference, 8))
        broadcast.replaceSubrange(346..<348, with: number(2, 2))
        for offset in stride(from: 412, through: 420, by: 2) {
            // EBU Tech 3285 v2 §2.4: unused loudness values are 7FFFh.
            broadcast.replaceSubrange(offset..<(offset + 2), with: number(0x7fff, 2))
        }
        let coding = dolbyE
            ? "A=DOLBYE,F=48000,W=24,M=\(channelCount == 2 ? "stereo" : "4ch"),T=FrameOffset 0;\r\n"
            : "A=PCM,F=48000,W=24,M=\(channelCount)ch,T=Dolby E decode;\r\n"
        broadcast.append(contentsOf: coding.utf8)
        chunk("bext", broadcast)
        // INFO identifies the muxing software independently of the BWF
        // originator. Both names intentionally identify the same library.
        let software = Data("libdolbye\0".utf8)
        chunk("LIST", Data("INFOISFT".utf8) + number(UInt64(software.count), 4) + software)
        data.append(contentsOf: "data".utf8)
        let sizeOffset = UInt64(data.count)
        data.append(number(0, 4))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DolbyEError.invalidArgument("cannot create output at \(url.path)")
        }
        let file = try FileHandle(forWritingTo: url)
        do { try file.write(contentsOf: data) } catch { try? file.close(); throw error }
        self.channelCount = channelCount
        self.header = data
        self.dataSizeOffset = sizeOffset
        self.handle = file
    }

    public init(resuming url: URL, checkpoint: Checkpoint, recoveringFinalization: Bool = false) throws {
        guard (1...16).contains(checkpoint.channelCount), checkpoint.header.count >= 80,
              checkpoint.dataBytes % UInt64(checkpoint.channelCount * 3) == 0 else {
            throw DolbyEError.malformed("invalid output checkpoint")
        }
        let file = try FileHandle(forUpdating: url)
        do {
            let bytes = try readBytes(file, at: 0, count: checkpoint.header.count)
            let identityMatches = bytes == checkpoint.header || (recoveringFinalization
                && bytes[8..<12] == checkpoint.header[8..<12]
                && bytes[48..<(bytes.count - 4)] == checkpoint.header[48..<(bytes.count - 4)])
            guard identityMatches,
                  try file.seekToEnd() >= UInt64(bytes.count) + checkpoint.dataBytes else {
                throw DolbyEError.malformed("output identity or durable length changed")
            }
            let length = UInt64(bytes.count) + checkpoint.dataBytes
            if bytes != checkpoint.header {
                try file.seek(toOffset: 0)
                try file.write(contentsOf: checkpoint.header)
            }
            try file.truncate(atOffset: length)
            try file.seek(toOffset: length)
        } catch { try? file.close(); throw error }
        self.channelCount = checkpoint.channelCount
        self.header = checkpoint.header
        self.dataSizeOffset = UInt64(checkpoint.header.count - 4)
        self.dataBytes = checkpoint.dataBytes
        self.handle = file
    }

    deinit { try? handle.close() }

    public func appendCarrier(_ words: [UInt32]) throws {
        guard !finished, [2, 4].contains(channelCount), words.count <= 8192,
              words.count % channelCount == 0,
              words.allSatisfy({ $0 & 255 == 0 }) else {
            throw DolbyEError.invalidArgument("carrier write requires aligned words for one or two AES pairs")
        }
        var bytes = Data()
        bytes.reserveCapacity(words.count * 3)
        for word in words {
            bytes.append(UInt8(truncatingIfNeeded: word >> 8))
            bytes.append(UInt8(truncatingIfNeeded: word >> 16))
            bytes.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        try handle.write(contentsOf: bytes)
        dataBytes += UInt64(bytes.count)
    }

    public func appendPCM(_ samples: [Double]) throws {
        guard !finished, samples.count <= 8192 * channelCount, samples.count % channelCount == 0,
              samples.allSatisfy(\.isFinite) else { throw DolbyEError.invalidArgument("invalid PCM output block") }
        var bytes = Data()
        bytes.reserveCapacity(samples.count * 3)
        for sample in samples {
            let rounded = (sample * 8388608).rounded(.toNearestOrEven)
            let value = UInt32(bitPattern: Int32(max(-8388608, min(8388607, rounded))))
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        }
        try handle.write(contentsOf: bytes)
        dataBytes += UInt64(bytes.count)
    }

    public func checkpoint() throws -> Checkpoint {
        guard !finished else { throw DolbyEError.invalidArgument("output has already been finalized") }
        try handle.synchronize()
        return Checkpoint(channelCount: channelCount, header: header, dataBytes: dataBytes)
    }

    public func finish() throws {
        guard !finished else { throw DolbyEError.invalidArgument("output has already been finalized") }
        func number(_ value: UInt64, _ bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let fileBytes = UInt64(header.count) + dataBytes
        if fileBytes - 8 > UInt64(UInt32.max) || dataBytes > UInt64(UInt32.max) {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("RF64".utf8) + number(UInt64(UInt32.max), 4))
            try handle.seek(toOffset: 12)
            let sizes = number(fileBytes - 8, 8) + number(dataBytes, 8)
                + number(dataBytes / UInt64(channelCount * 3), 8) + number(0, 4)
            try handle.write(contentsOf: Data("ds64".utf8) + number(28, 4) + sizes)
            try handle.seek(toOffset: dataSizeOffset)
            try handle.write(contentsOf: number(UInt64(UInt32.max), 4))
        } else {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: number(fileBytes - 8, 4))
            try handle.seek(toOffset: dataSizeOffset)
            try handle.write(contentsOf: number(dataBytes, 4))
        }
        try handle.synchronize()
        try handle.close()
        finished = true
    }
}
