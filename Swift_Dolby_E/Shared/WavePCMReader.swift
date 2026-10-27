// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct WavePCMInfo: Codable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let containerBits: Int
    public let validBits: Int
    public let channelMask: UInt32
    public let floatingPoint: Bool
    public let frameCount: UInt64
    public let hasADM: Bool
    public let hasChannelAssignment: Bool
    public let hasDolbyMetadata: Bool
    public let dataOffset: UInt64
    public let dataBytes: UInt64
}

/// Streams input in place. Scans metadata after `data` without allocating the audio chunk.
/// A reader owns its file handle and must not be shared between concurrent jobs.
public final class WavePCMReader {
    public let info: WavePCMInfo
    private let handle: FileHandle
    private let alignment: Int
    private let metadata: [String: (UInt64, UInt64)]
    private let url: URL
    public private(set) var position: UInt64 = 0

    public init(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd()
            let header = try readBytes(file, at: 0, count: 12)
            let kind = try header.ascii(at: 0, count: 4)
            guard ["RIFF", "RF64", "BW64"].contains(kind), try header.ascii(at: 8, count: 4) == "WAVE" else {
                throw DolbyEError.malformed("expected RIFF/RF64/BW64 WAVE")
            }
            let declared = try header.integer(at: 4, bytes: 4)
            var limit = size
            if kind == "RIFF" {
                guard declared >= 4, declared <= size - 8 else {
                    throw DolbyEError.malformed("RIFF size exceeds file bounds")
                }
                limit = declared + 8
            } else if declared != UInt64(UInt32.max) {
                throw DolbyEError.malformed("RF64/BW64 requires sentinel RIFF size")
            }
            var cursor: UInt64 = 12
            var format: Data?
            var audio: (offset: UInt64, bytes: UInt64)?
            var extendedDataSize: UInt64?
            var sawDS64 = false
            var adm = false, chna = false, dbmd = false
            var metadata: [String: (UInt64, UInt64)] = [:]
            while cursor < limit {
                guard limit - cursor >= 8 else { throw DolbyEError.malformed("truncated WAVE chunk header") }
                let chunk = try readBytes(file, at: cursor, count: 8)
                let name = try chunk.ascii(at: 0, count: 4)
                let shortLength = try chunk.integer(at: 4, bytes: 4)
                let start = cursor + 8
                let length: UInt64
                if shortLength == UInt64(UInt32.max) {
                    guard name == "data", let extendedDataSize else {
                        throw DolbyEError.unsupported("unresolved RF64 extended chunk size for \(name)")
                    }
                    length = extendedDataSize
                } else {
                    length = shortLength
                }
                guard start <= limit, length <= limit - start else {
                    throw DolbyEError.malformed("\(name) at byte \(cursor) exceeds WAVE bounds")
                }
                switch name {
                case "ds64":
                    guard kind != "RIFF", !sawDS64, length >= 28 else {
                        throw DolbyEError.malformed("invalid or duplicate ds64")
                    }
                    let ds = try readBytes(file, at: start, count: 28)
                    let riffSize = try ds.integer(at: 0, bytes: 8)
                    guard riffSize >= 4, riffSize <= size - 8, riffSize + 8 >= start + length else {
                        throw DolbyEError.malformed("ds64 RIFF size outside file")
                    }
                    let tableCount = try ds.integer(at: 24, bytes: 4)
                    guard tableCount <= (length - 28) / 12 else {
                        throw DolbyEError.malformed("ds64 table exceeds chunk")
                    }
                    limit = riffSize + 8
                    extendedDataSize = try ds.integer(at: 8, bytes: 8)
                    sawDS64 = true
                case "fmt ":
                    guard format == nil, length >= 16, length <= 65536 else {
                        throw DolbyEError.malformed("invalid or duplicate fmt chunk")
                    }
                    format = try readBytes(file, at: start, count: Int(length))
                case "data":
                    guard audio == nil else { throw DolbyEError.unsupported("multiple WAVE data chunks") }
                    audio = (start, length)
                case "axml": adm = length > 0
                case "chna": chna = length > 0
                case "dbmd": dbmd = length > 0
                default: break
                }
                let end = start + length
                if ["axml", "chna", "bext", "dbmd"].contains(name) {
                    guard metadata[name] == nil else {
                        throw DolbyEError.malformed("duplicate \(name) metadata")
                    }
                    metadata[name] = (start, length)
                }
                guard length & 1 == 0 || end < limit else {
                    throw DolbyEError.malformed("missing odd-chunk padding")
                }
                cursor = end + (length & 1)
            }
            guard kind == "RIFF" || sawDS64 else { throw DolbyEError.malformed("RF64/BW64 missing ds64") }
            guard let format, let audio else { throw DolbyEError.malformed("WAVE missing fmt or data") }
            let channels = Int(try format.integer(at: 2, bytes: 2))
            let rate = Int(try format.integer(at: 4, bytes: 4))
            let block = Int(try format.integer(at: 12, bytes: 2))
            let bits = Int(try format.integer(at: 14, bytes: 2))
            var tag = try format.integer(at: 0, bytes: 2)
            var valid = bits
            var mask: UInt32 = 0
            if tag == 0xfffe {
                guard format.count >= 40, try format.integer(at: 16, bytes: 2) >= 22,
                      Int(try format.integer(at: 16, bytes: 2)) <= format.count - 18 else {
                    throw DolbyEError.malformed("short WAVE extensible format")
                }
                valid = Int(try format.integer(at: 18, bytes: 2))
                if valid == 0 { valid = bits }
                mask = UInt32(try format.integer(at: 20, bytes: 4))
                let subtype = Data(format[24..<40])
                let pcmGUID = Data([1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113])
                var floatGUID = pcmGUID
                floatGUID[0] = 3
                guard subtype == pcmGUID || subtype == floatGUID else {
                    throw DolbyEError.unsupported("WAVE extensible subtype GUID")
                }
                tag = subtype == pcmGUID ? 1 : 3
            }
            guard (1...256).contains(channels), (1...384000).contains(rate), [16, 24, 32].contains(bits),
                  valid > 0, valid <= bits, (tag == 1 || (tag == 3 && bits == 32 && valid == 32)) else {
                throw DolbyEError.unsupported("expected 16/24/32-bit integer PCM or Float32")
            }
            guard block == channels * (bits / 8), audio.bytes % UInt64(block) == 0,
                  try format.integer(at: 8, bytes: 4) == UInt64(rate * block),
                  mask == 0 || mask.nonzeroBitCount == channels else {
                throw DolbyEError.malformed("inconsistent WAVE alignment, byte rate, mask or data length")
            }
            self.info = WavePCMInfo(sampleRate: rate, channelCount: channels, containerBits: bits,
                                    validBits: valid, channelMask: mask, floatingPoint: tag == 3,
                                    frameCount: audio.bytes / UInt64(block), hasADM: adm,
                                    hasChannelAssignment: chna, hasDolbyMetadata: dbmd,
                                    dataOffset: audio.offset, dataBytes: audio.bytes)
            self.alignment = block
            self.metadata = metadata
            self.url = url
            self.handle = file
        } catch {
            try? file.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    /// Bounded ancillary metadata access; audio remains at its original location.
    public func metadataChunk(_ name: String) throws -> Data? {
        guard let (offset, length) = metadata[name] else { return nil }
        guard length <= 16 * 1024 * 1024 else { throw DolbyEError.invalidArgument("metadata chunk requires streaming access") }
        return try readBytes(handle, at: offset, count: Int(length))
    }
    public func metadataStream(_ name: String) throws -> InputStream? {
        guard let (offset, length) = metadata[name] else { return nil }
        return try DolbyEMetadataStream(url: url, range: offset..<(offset + length))
    }

    public func seek(toFrame frame: UInt64) throws {
        guard frame <= info.frameCount else { throw DolbyEError.invalidArgument("seek exceeds PCM frames") }
        position = frame
    }

    /// Interleaved normalized samples. The maximum request bounds memory independently of file size.
    public func read(maxFrames: Int = 4096) throws -> [Float] {
        guard (1...8192).contains(maxFrames) else { throw DolbyEError.invalidArgument("read size must be 1...8192") }
        let frames = Int(min(UInt64(maxFrames), info.frameCount - position))
        if frames == 0 { return [] }
        let data = try readBytes(handle, at: info.dataOffset + position * UInt64(alignment), count: frames * alignment)
        var result: [Float] = []
        result.reserveCapacity(frames * info.channelCount)
        let sampleBytes = info.containerBits / 8
        for offset in stride(from: 0, to: data.count, by: sampleBytes) {
            let raw = UInt32(try data.integer(at: offset, bytes: sampleBytes))
            let value: Float
            if info.floatingPoint {
                value = Float(bitPattern: raw)
                guard value.isFinite else { throw DolbyEError.malformed("non-finite float PCM at frame \(position)") }
            } else {
                let shift = 32 - info.containerBits
                let signed = Int32(bitPattern: raw << shift) >> shift
                value = Float(Double(signed) / pow(2, Double(info.containerBits - 1)))
            }
            result.append(value)
        }
        position += UInt64(frames)
        return result
    }
}
