// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public struct DolbyECarrierProbe: Codable, Sendable {
    public let carrier: WavePCMInfo
    public let program: DolbyEProgram
    public let frameRate: DolbyEFrameRate
    public let firstFrameNumber: UInt16
    public let firstFrameCRCVerified: Bool
    public let boundaries: DolbyEStreamBoundaryInfo
    public let ac3Metadata: [DolbyEAC3ProgramInfo]
    public let encodeVision: DolbyEEncodeVision
    public let ed2Scene: DolbyED2SceneMetadata?
    public let metadataAuthenticationVerified: Bool?

    public init(url: URL) throws {
        let reader = try DolbyEWaveCarrierReader(url: url)
        guard let frame = try reader.readFrame() else { throw DolbyEError.malformed("no complete Dolby E frame") }
        self.carrier = reader.info; self.program = frame.program; self.frameRate = frame.frameRate
        self.firstFrameNumber = frame.frameNumber; self.firstFrameCRCVerified = true
        self.boundaries = reader.boundaryInfo; self.ac3Metadata = frame.ac3Metadata
        if !frame.evolutionWords.isEmpty {
            let metadata = try DolbyED2MetadataContainer.parse(words: frame.evolutionWords).verifying(coreWords: frame.coreWords)
            self.encodeVision = .ed2; self.ed2Scene = try metadata.scene()
            self.metadataAuthenticationVerified = metadata.authenticationVerified
        } else {
            self.encodeVision = .e; self.ed2Scene = nil; self.metadataAuthenticationVerified = nil
        }
    }
}

/// Bounded, bit-preserving carrier reader. Its logical word cursor is independent
/// of read-ahead so a checkpoint can resume exactly at a burst boundary.
public final class DolbyEWaveCarrierReader {
    public enum BoundaryHandling: Sendable {
        case requireCompleteFrames
        case allowFragmentBoundaries
    }

    public let info: WavePCMInfo
    public private(set) var wordPosition: UInt64 = 0
    public private(set) var boundaryInfo = DolbyEStreamBoundaryInfo()
    public private(set) var lastFrameStartWord: UInt64 = 0
    private let handle: FileHandle
    private let mxf: DolbyEMXFReader?
    private let sampleBytes: Int
    private var buffer: [UInt32] = []
    private var index = 0
    private let boundaryHandling: BoundaryHandling
    private let pairIndex: Int
    private var acquired = false
    private var locatingUntilWord: UInt64?

    public init(url: URL, boundaryHandling: BoundaryHandling = .allowFragmentBoundaries, pairIndex: Int = 0) throws {
        let file = try FileHandle(forReadingFrom: url)
        let isMXF: Bool
        do { isMXF = try readBytes(file, at: 0, count: 4) == Data([6, 14, 43, 52]) }
        catch { try? file.close(); throw error }
        let info: WavePCMInfo
        do {
            if isMXF {
                let reader = try DolbyEMXFReader(url: url)
                guard reader.compressed else { throw DolbyEError.unsupported("MXF sound track is not marked Dolby E") }
                self.mxf = reader; info = reader.info
            } else {
                self.mxf = nil; info = try WavePCMReader(url: url).info
            }
        } catch { try? file.close(); throw error }
        guard info.sampleRate == 48000, [2, 4].contains(info.channelCount), [24, 32].contains(info.containerBits),
              (0..<(info.channelCount / 2)).contains(pairIndex) else {
            throw DolbyEError.unsupported("Dolby E/ED2 requires 48 kHz AES3 pairs in a 24/32-bit carrier")
        }
        self.info = info
        self.sampleBytes = info.containerBits / 8
        self.handle = file
        self.boundaryHandling = boundaryHandling
        self.pairIndex = pairIndex
    }

    deinit { try? handle.close() }

    public func seek(toWord position: UInt64, restoring boundaries: DolbyEStreamBoundaryInfo? = nil) throws {
        guard position <= info.frameCount * 2 else { throw DolbyEError.invalidArgument("carrier seek exceeds data") }
        if let boundaries {
            guard boundaries.leadingWords <= info.frameCount * 2, boundaries.truncatedTailWords <= info.frameCount * 2 else {
                throw DolbyEError.malformed("invalid saved carrier boundaries")
            }
        }
        wordPosition = position
        buffer.removeAll(keepingCapacity: true)
        index = 0
        acquired = position != 0
        boundaryInfo = boundaries ?? DolbyEStreamBoundaryInfo()
    }

    /// Reacquires within a bounded carrier neighborhood. Only preamble search
    /// is relaxed; a complete identified frame still undergoes every CRC check.
    func locateFrame(nearWord position: UInt64, maximumSearchWords: UInt64 = 8192) throws -> DolbyECarrierFrame? {
        guard maximumSearchWords <= 8192 else { throw DolbyEError.invalidArgument("carrier acquisition bound") }
        let boundaries = boundaryInfo
        try seek(toWord: position, restoring: boundaries)
        acquired = false
        locatingUntilWord = position + min(maximumSearchWords, info.frameCount * 2 - position)
        defer { locatingUntilWord = nil }
        return try readFrame()
    }

    private func word() throws -> UInt32? {
        let total = info.frameCount * 2
        if wordPosition == total { return nil }
        if index == buffer.count {
            try Task.checkCancellation()
            let words = Int(min(UInt64(4096), total - wordPosition))
            let data: Data
            let firstWord = Int(wordPosition % 2)
            if info.channelCount == 2 {
                let count = words * sampleBytes
                if let mxf { data = try mxf.readBytes(atByte: wordPosition * UInt64(sampleBytes), count: count) }
                else { data = try readBytes(handle, at: info.dataOffset + wordPosition * UInt64(sampleBytes), count: count) }
            } else {
                // A logical AES3 cursor is independent of the physical four-
                // channel mux. Read bounded PCM frames and retain one pair.
                let frames = (words + firstWord + 1) / 2
                let offset = (wordPosition / 2) * UInt64(info.channelCount * sampleBytes)
                let count = frames * info.channelCount * sampleBytes
                data = try mxf?.readBytes(atByte: offset, count: count)
                    ?? readBytes(handle, at: info.dataOffset + offset, count: count)
            }
            // Convert this bounded read once. Parsing each payload word through
            // Data's indexed/throwing integer accessor dominated carrier CPU.
            buffer.removeAll(keepingCapacity: true); buffer.reserveCapacity(words)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for index in 0..<words {
                    let logical = firstWord + index
                    let at = info.channelCount == 2 ? index * sampleBytes
                        : (logical / 2 * info.channelCount + pairIndex * 2 + logical % 2) * sampleBytes
                    let value = UInt32(raw[at]) | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2]) << 16
                    buffer.append(sampleBytes == 3 ? value : value | UInt32(raw[at + 3]) << 24)
                }
            }
            index = 0
        }
        let raw = buffer[index]
        index += 1
        wordPosition += 1
        if info.floatingPoint {
            let value = Double(Float(bitPattern: raw)) * 2147483648.0
            guard value.isFinite, value >= -2147483648, value < 2147483648, value == value.rounded() else {
                throw DolbyEError.malformed("float carrier contains an inexact or non-finite digital word")
            }
            return UInt32(bitPattern: Int32(value))
        }
        return sampleBytes == 3 ? raw << 8 : raw
    }

    public func readFrame() throws -> DolbyECarrierFrame? {
        let position = wordPosition, boundaries = boundaryInfo
        let locked = acquired, lastStart = lastFrameStartWord
        do { return try readNextFrame() }
        catch {
            // A cancellation may occur at a read-ahead refill in the middle
            // of a burst. Retry must see the same complete frame, not its tail.
            try seek(toWord: position, restoring: boundaries)
            acquired = locked; lastFrameStartWord = lastStart
            throw error
        }
    }

    private func readNextFrame() throws -> DolbyECarrierFrame? {
        while let first = try word() {
            let start = wordPosition - 1
            if let limit = locatingUntilWord, start > limit { return nil }
            if first == 0 { continue }
            guard first == 0x6f872000 else {
                if !acquired && (locatingUntilWord != nil || boundaryHandling == .allowFragmentBoundaries) { continue }
                throw DolbyEError.malformed("nonzero data outside a Dolby E burst at word \(start)")
            }
            var words = [first]
            for _ in 0..<3 {
                guard let value = try word() else { return try truncated(at: start, field: "SMPTE burst header") }
                words.append(value)
            }
            let control = words[2] >> 16
            let bits = Int(words[3] >> 12)
            let payloadCount = (bits + 19) / 20
            let valid = words[1] == 0x54e1f000 && control & 31 == 28 && (control >> 5) & 3 == 1
                && bits > 0 && payloadCount <= 4095
            if !valid {
                if !acquired && (locatingUntilWord != nil || boundaryHandling == .allowFragmentBoundaries) {
                    wordPosition = start + 1
                    buffer.removeAll(keepingCapacity: true)
                    index = 0
                    continue
                }
                throw DolbyEError.malformed("invalid SMPTE carrier header at word \(start)")
            }
            guard UInt64(payloadCount) <= info.frameCount * 2 - wordPosition else {
                return try truncated(at: start, field: "Dolby E burst payload")
            }
            for _ in 0..<payloadCount {
                guard let value = try word() else { return try truncated(at: start, field: "Dolby E burst payload") }
                words.append(value)
            }
            // Once a complete header identifies a Dolby E frame, CRC or syntax
            // failure is fatal. Acquisition never skips a corrupt complete frame.
            let frame = try DolbyECarrierFrame(words: words)
            if !acquired && locatingUntilWord == nil { boundaryInfo.leadingWords = start }
            lastFrameStartWord = start
            acquired = true
            return frame
        }
        return nil
    }

    private func truncated(at start: UInt64, field: String) throws -> DolbyECarrierFrame? {
        guard boundaryHandling == .allowFragmentBoundaries else {
            throw DolbyEError.malformed("truncated \(field) at carrier word \(start)")
        }
        boundaryInfo.truncatedTailWords = info.frameCount * 2 - start
        wordPosition = info.frameCount * 2
        buffer.removeAll(keepingCapacity: true)
        index = 0
        return nil
    }
}
