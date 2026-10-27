// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

struct DolbyEIABRamp: Codable, Sendable {
    let token: UInt64
    let start: [Double]
    let target: [Double]
    let periods: [Int]
    var current: [Double]
}

/// Streams one IAFrame at a time from raw IAB or IMF MXF. Header indexing uses
/// constant memory, including for multi-hour masters; seeking re-scans KLV/TLV
/// headers and only decodes the frame containing the requested sample.
final class DolbyEIABReader {
    struct Cursor {
        let klv: UInt64; let cursor: UInt64; let regionEnd: UInt64; let frameIndex: UInt64
        let frame: DolbyEIABFrame?; let frameOffset: Int; let position: UInt64
    }
    let info: WavePCMInfo
    let embeddedFrameRate: DolbyEFrameRate
    private let file: FileHandle
    private let fileSize: UInt64
    private let isMXF: Bool
    private let program: DolbyEProgram
    private let samplesPerFrame: Int
    private var klvOffset: UInt64 = 0
    private var cursor: UInt64 = 0
    private var regionEnd: UInt64 = 0
    private var frameIndex: UInt64 = 0
    private var frame: DolbyEIABFrame?
    private var frameOffset = 0
    private(set) var position: UInt64 = 0
    private static let essenceKey = DolbyEMXFKLV.ul("060e2b34010201010d01030116010d01")

    init(url: URL, program: DolbyEProgram) throws {
        let file = try FileHandle(forReadingFrom: url)
        do {
            self.file = file; self.fileSize = try file.seekToEnd(); self.program = program
            self.isMXF = try readBytes(file, at: 0, count: 4) == Data([6, 14, 43, 52])
            self.regionEnd = isMXF ? 0 : fileSize
            // Initialize immutable properties before the bounded index pass.
            var scan: UInt64 = 0, local: UInt64 = 0, end: UInt64 = isMXF ? 0 : fileSize
            var total: UInt64 = 0, first: (Int, Int)?
            while let location = try Self.next(file, size: fileSize, mxf: isMXF, klv: &scan, cursor: &local, end: &end) {
                let prefix = try readBytes(file, at: location.lowerBound, count: Int(min(64, location.count)))
                var bits = DolbyEIABBits(data: prefix)
                let id = try bits.plex(), length = try bits.plex()
                guard id == 8, UInt64(bits.position / 8) + UInt64(length) == UInt64(location.count) else { throw DolbyEError.malformed("IAB frame element length") }
                let header = try DolbyEIABFrame.header(bits.bytes(2))
                if let first { guard first == (header.samples, header.rate) else { throw DolbyEError.malformed("IAB frame rate changes within source track") } }
                else { first = (header.samples, header.rate) }
                guard total <= UInt64.max - UInt64(header.samples) else { throw DolbyEError.malformed("IAB sample count overflow") }
                total += UInt64(header.samples)
                try Task.checkCancellation()
            }
            guard let first, total > 0 else { throw DolbyEError.malformed("source contains no complete IAFrames") }
            self.samplesPerFrame = first.0
            self.embeddedFrameRate = Self.outputRate(first.1)
            self.info = WavePCMInfo(sampleRate: 48000, channelCount: 8, containerBits: 24, validBits: 24,
                channelMask: 0, floatingPoint: false, frameCount: total, hasADM: false, hasChannelAssignment: false,
                hasDolbyMetadata: true, dataOffset: 0, dataBytes: 0)
        } catch { try? file.close(); throw error }
    }
    deinit { try? file.close() }
    func captureCursor() -> Cursor {
        Cursor(klv: klvOffset, cursor: cursor, regionEnd: regionEnd, frameIndex: frameIndex,
            frame: frame, frameOffset: frameOffset, position: position)
    }
    func restoreCursor(_ saved: Cursor) {
        klvOffset = saved.klv; cursor = saved.cursor; regionEnd = saved.regionEnd; frameIndex = saved.frameIndex
        frame = saved.frame; frameOffset = saved.frameOffset; position = saved.position
    }
    static func outputRate(_ code: Int) -> DolbyEFrameRate {
        if code == 9 { return .fps23976 }
        return code % 3 == 0 ? .fps24 : (code % 3 == 1 ? .fps25 : .fps30)
    }
    private static func next(_ file: FileHandle, size: UInt64, mxf: Bool, klv: inout UInt64,
                             cursor: inout UInt64, end: inout UInt64) throws -> Range<UInt64>? {
        if cursor == end {
            if !mxf { return nil }
            var found = false
            while klv < size {
                let item = try DolbyEMXFKLV.read(file, at: klv, limit: size)
                klv = item.end
                if item.key == essenceKey { cursor = item.start; end = item.end; found = true; break }
            }
            if !found { return nil }
        }
        func tlv(_ tag: UInt8, _ cursor: inout UInt64) throws -> Range<UInt64> {
            guard cursor <= end, end - cursor >= 5 else { throw DolbyEError.malformed("truncated IAB container TLV") }
            let header = try readBytes(file, at: cursor, count: 5)
            let count = try header.integer(at: 1, bytes: 4, bigEndian: true)
            cursor += 5
            guard header[0] == tag, count <= end - cursor else { throw DolbyEError.malformed("invalid IAB container tag or length") }
            let range = cursor..<(cursor + count); cursor += count; return range
        }
        _ = try tlv(1, &cursor)
        let result = try tlv(2, &cursor)
        guard result.count > 0, result.count <= 16 * 1024 * 1024 else { throw DolbyEError.malformed("IAB frame exceeds bounded parser size") }
        return result
    }
    func seek(toFrame sample: UInt64) throws {
        guard sample <= info.frameCount else { throw DolbyEError.invalidArgument("IAB seek exceeds samples") }
        klvOffset = 0; cursor = 0; regionEnd = isMXF ? 0 : fileSize
        frameIndex = 0; frame = nil; frameOffset = 0; position = sample
        while frameIndex * UInt64(samplesPerFrame) < sample {
            guard let location = try Self.next(file, size: fileSize, mxf: isMXF, klv: &klvOffset, cursor: &cursor, end: &regionEnd) else { throw DolbyEError.malformed("IAB seek ran out of frame headers") }
            if (frameIndex + 1) * UInt64(samplesPerFrame) > sample {
                frame = try DolbyEIABFrame.parse(readBytes(file, at: location.lowerBound, count: location.count), program: program)
                frameOffset = Int(sample - frameIndex * UInt64(samplesPerFrame)); return
            }
            frameIndex += 1
        }
    }
    func render(frames count: Int, renderer: inout DolbyEAtmosRenderer) throws -> [Double] {
        guard (1...8192).contains(count) else { throw DolbyEError.invalidArgument("IAB render block exceeds bound") }
        var result = [Double](repeating: 0, count: count * 8)
        var diffuse = result
        var written = 0
        var spatialCache: [DolbyEIABPan: [Double]] = [:]
        while written < count, position < info.frameCount {
            if frame == nil {
                guard let location = try Self.next(file, size: fileSize, mxf: isMXF, klv: &klvOffset, cursor: &cursor, end: &regionEnd) else { throw DolbyEError.malformed("IAB essence ended before indexed duration") }
                frame = try DolbyEIABFrame.parse(readBytes(file, at: location.lowerBound, count: location.count), program: program)
                frameOffset = 0
            }
            guard let frame, frame.samples == samplesPerFrame else { throw DolbyEError.malformed("IAB decoded sample count changed") }
            let amount = min(count - written, frame.samples - frameOffset)
            let portion = frameOffset..<(frameOffset + amount)
            let ranges = frame.blockRanges
            for source in frame.renderables where source.audioID != 0 && source.gain != 0 {
                guard let samples = frame.assets[source.audioID] else { throw DolbyEError.malformed("IAB audio reference disappeared") }
                if let bed = source.bed {
                    let weights = renderer.gains(DolbyEAtmosValue(gain: source.gain), bed: bed)
                    for index in portion {
                        let sample = Double(samples[index]), output = (written + index - frameOffset) * 8
                        for channel in 0..<8 { result[output + channel] += sample * weights[channel] }
                    }
                } else {
                    guard source.pans.count == ranges.count else { throw DolbyEError.malformed("IAB pan sub-block count") }
                    for block in ranges.indices {
                        let start = max(portion.lowerBound, ranges[block].lowerBound), end = min(portion.upperBound, ranges[block].upperBound)
                        guard start < end else { continue }
                        let pan = source.pans[block]
                        let weights: [Double]
                        if let cached = spatialCache[pan] { weights = cached }
                        else {
                            weights = try renderer.spatialGains(pan)
                            if spatialCache.count >= 4096 { spatialCache.removeAll(keepingCapacity: true) }
                            spatialCache[pan] = weights
                        }
                        try renderer.mixIAB(samples: samples, range: start..<end, blockStart: ranges[block].lowerBound,
                            blockLength: ranges[block].count, outputOffset: written - frameOffset,
                            token: frameIndex * 16 + UInt64(block), id: source.id + ".d",
                            target: weights.map { $0 * sqrt(1 - pan.decorrelation) }, output: &result)
                        try renderer.mixIAB(samples: samples, range: start..<end, blockStart: ranges[block].lowerBound,
                            blockLength: ranges[block].count, outputOffset: written - frameOffset,
                            token: frameIndex * 16 + UInt64(block), id: source.id + ".w",
                            target: weights.map { $0 * sqrt(pan.decorrelation) }, output: &diffuse)
                    }
                }
            }
            written += amount; frameOffset += amount; position += UInt64(amount)
            if frameOffset == frame.samples {
                renderer.retainIABSources(Set(frame.renderables.filter { $0.bed == nil && $0.audioID != 0 }.flatMap { [$0.id + ".d", $0.id + ".w"] }))
                self.frame = nil; frameOffset = 0; frameIndex += 1
            }
        }
        return try renderer.processIABBuses(dry: result, diffuse: diffuse)
    }

    /// Gather only this read's native sources and their timed sub-blocks.
    /// AudioDataID can change across frames; authored metadata ID owns the
    /// transport object's identity. PCM and DLC use the same decoded assets.
    func renderED2(frames count: Int, router: inout DolbyED2SceneRouter) throws -> DolbyED2RoutedFrame {
        guard (1...2048).contains(count), program == .eightMono else {
            throw DolbyEError.invalidArgument("ED2 IAB input requires the immersive eight-mono source mode")
        }
        var buffers: [String: DolbyED2BufferedInput] = [:]
        var written = 0
        while written < count, position < info.frameCount {
            if frame == nil {
                guard let location = try Self.next(file, size: fileSize, mxf: isMXF, klv: &klvOffset, cursor: &cursor, end: &regionEnd) else {
                    throw DolbyEError.malformed("IAB ED2 essence ended before indexed duration")
                }
                frame = try DolbyEIABFrame.parse(readBytes(file, at: location.lowerBound, count: location.count), program: program)
                frameOffset = 0
            }
            guard let frame, frame.samples == samplesPerFrame else { throw DolbyEError.malformed("IAB ED2 decoded sample count changed") }
            let amount = min(count - written, frame.samples - frameOffset)
            let portion = frameOffset..<(frameOffset + amount)
            let ranges = frame.blockRanges
            for source in frame.renderables {
                let audio: [Float]?
                if source.audioID == 0 {
                    // AudioDataID zero explicitly denotes a silent source.
                    // Bed assignments and object trajectories still exist.
                    audio = nil
                } else {
                    guard let decoded = frame.assets[source.audioID] else { throw DolbyEError.malformed("IAB ED2 references a missing decoded asset") }
                    audio = decoded
                }
                var buffer = buffers[source.id] ?? DolbyED2BufferedInput(id: source.id, bed: source.bed,
                    samples: Array(repeating: 0, count: count))
                guard buffer.bed == source.bed, buffers.count <= 512 else {
                    throw DolbyEError.malformed("IAB source identity changes channel semantics or exceeds bound")
                }
                if let audio {
                    for index in portion { buffer.samples[written + index - frameOffset] += audio[index] }
                }
                if source.bed != nil {
                    buffer.spans.append(.init(range: written..<(written + amount), value: DolbyEAtmosValue(gain: source.gain)))
                } else {
                    guard source.pans.count == ranges.count else { throw DolbyEError.malformed("IAB ED2 pan sub-block count") }
                    for block in ranges.indices {
                        let first = max(portion.lowerBound, ranges[block].lowerBound)
                        let end = min(portion.upperBound, ranges[block].upperBound)
                        guard first < end else { continue }
                        let pan = source.pans[block]
                        var value = pan.value
                        value.gain *= source.gain; value.spread = pan.spread; value.decorrelation = pan.decorrelation
                        value.snapTolerance = pan.snap; value.zones = pan.zones
                        buffer.spans.append(.init(range: (written + first - frameOffset)..<(written + end - frameOffset), value: value))
                    }
                }
                buffers[source.id] = buffer
            }
            written += amount; frameOffset += amount; position += UInt64(amount)
            if frameOffset == frame.samples { self.frame = nil; frameOffset = 0; frameIndex += 1 }
        }
        return try router.route(buffers.keys.sorted().compactMap { buffers[$0]?.source() }, frames: count)
    }
}
