// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Direct, bounded CAF linear-PCM access for DAMF audio sidecars. CAF's
/// little-endian flag is distinct from ASBD's similarly numbered flag.
final class DolbyECAFReader {
    let info: WavePCMInfo
    private let file: FileHandle
    private let littleEndian: Bool
    private let alignment: Int
    private(set) var position: UInt64 = 0

    init(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd()
            let header = try readBytes(file, at: 0, count: 8)
            guard try header.ascii(at: 0, count: 4) == "caff", try header.integer(at: 4, bytes: 2, bigEndian: true) == 1 else {
                throw DolbyEError.malformed("invalid CAF header")
            }
            var offset: UInt64 = 8
            var description: Data?
            var audio: (UInt64, UInt64)?
            while offset < size {
                guard size - offset >= 12 else { throw DolbyEError.malformed("truncated CAF chunk") }
                let chunk = try readBytes(file, at: offset, count: 12)
                let name = try chunk.ascii(at: 0, count: 4)
                let stored = try chunk.integer(at: 4, bytes: 8, bigEndian: true)
                let start = offset + 12
                let count = stored == UInt64.max && name == "data" ? size - start : stored
                guard count <= size - start else { throw DolbyEError.malformed("CAF chunk exceeds file") }
                if name == "desc" {
                    guard description == nil, count == 32 else { throw DolbyEError.malformed("invalid CAF stream description") }
                    description = try readBytes(file, at: start, count: 32)
                } else if name == "data" {
                    guard audio == nil, count >= 4 else { throw DolbyEError.malformed("invalid CAF audio chunk") }
                    audio = (start + 4, count - 4)
                }
                offset = start + count
            }
            guard let description, let audio else { throw DolbyEError.malformed("CAF missing desc or data") }
            let sampleRate = Double(bitPattern: try description.integer(at: 0, bytes: 8, bigEndian: true))
            let flags = try description.integer(at: 12, bytes: 4, bigEndian: true)
            let packetBytes = Int(try description.integer(at: 16, bytes: 4, bigEndian: true))
            let packetFrames = try description.integer(at: 20, bytes: 4, bigEndian: true)
            let channels = Int(try description.integer(at: 24, bytes: 4, bigEndian: true))
            let bits = Int(try description.integer(at: 28, bytes: 4, bigEndian: true))
            let floating = flags & 1 != 0
            guard try description.ascii(at: 8, count: 4) == "lpcm", sampleRate == 48000,
                  (1...256).contains(channels), [16, 24, 32].contains(bits), packetFrames == 1,
                  packetBytes == channels * bits / 8, flags & ~UInt64(3) == 0,
                  !floating || bits == 32, audio.1 % UInt64(packetBytes) == 0 else {
                throw DolbyEError.unsupported("DAMF audio requires interleaved 48 kHz integer PCM or Float32 CAF")
            }
            self.info = WavePCMInfo(sampleRate: 48000, channelCount: channels, containerBits: bits, validBits: bits,
                channelMask: 0, floatingPoint: floating, frameCount: audio.1 / UInt64(packetBytes), hasADM: false,
                hasChannelAssignment: false, hasDolbyMetadata: true, dataOffset: audio.0, dataBytes: audio.1)
            self.file = file; self.littleEndian = flags & 2 != 0; self.alignment = packetBytes
        } catch { try? file.close(); throw error }
    }
    deinit { try? file.close() }
    func seek(toFrame frame: UInt64) throws {
        guard frame <= info.frameCount else { throw DolbyEError.invalidArgument("CAF seek exceeds audio") }
        position = frame
    }
    func read(maxFrames: Int) throws -> [Float] {
        guard (1...8192).contains(maxFrames) else { throw DolbyEError.invalidArgument("CAF read exceeds bound") }
        let frames = Int(min(UInt64(maxFrames), info.frameCount - position))
        guard frames > 0 else { return [] }
        let data = try readBytes(file, at: info.dataOffset + position * UInt64(alignment), count: frames * alignment)
        let width = info.containerBits / 8
        var samples = [Float](); samples.reserveCapacity(frames * info.channelCount)
        for offset in stride(from: 0, to: data.count, by: width) {
            let raw = UInt32(try data.integer(at: offset, bytes: width, bigEndian: !littleEndian))
            let sample: Float
            if info.floatingPoint { sample = Float(bitPattern: raw) }
            else {
                let shift = 32 - info.containerBits
                sample = Float(Double(Int32(bitPattern: raw << shift) >> shift) / pow(2, Double(info.containerBits - 1)))
            }
            guard sample.isFinite else { throw DolbyEError.malformed("non-finite DAMF audio") }
            samples.append(sample)
        }
        position += UInt64(frames)
        return samples
    }
}
