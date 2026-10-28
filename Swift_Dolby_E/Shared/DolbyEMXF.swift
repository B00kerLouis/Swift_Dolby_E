// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// ST 377 KLV primitives. Media values are always skipped or read in bounded
/// slices; a clip-wrapped value can be larger than four GiB.
enum DolbyEMXFKLV {
    static func bytes(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func ul(_ value: String) -> Data {
        let characters = Array(value.utf8)
        func nibble(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : (c >= 65 ? c - 55 : c - 48) }
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            nibble(characters[$0]) * 16 + nibble(characters[$0 + 1])
        })
    }
    static func packet(_ key: Data, _ value: Data) -> Data {
        key + Data([0x88]) + bytes(UInt64(value.count), 8) + value
    }
    struct Item {
        let key: Data
        let start: UInt64
        let length: UInt64
        var end: UInt64 { start + length }
    }
    static func read(_ file: FileHandle, at offset: UInt64, limit: UInt64) throws -> Item {
        guard offset <= limit, limit - offset >= 17 else { throw DolbyEError.malformed("truncated MXF KLV at \(offset)") }
        let header = try readBytes(file, at: offset, count: 17)
        guard header.starts(with: [6, 14, 43, 52]) else { throw DolbyEError.malformed("invalid MXF key at \(offset)") }
        let first = header[16]
        let count = first & 128 == 0 ? 0 : Int(first & 127)
        guard count <= 8, first != 128, UInt64(count) <= limit - offset - 17 else {
            throw DolbyEError.malformed("invalid MXF BER length")
        }
        let length = count == 0 ? UInt64(first)
            : try readBytes(file, at: offset + 17, count: count).integer(at: 0, bytes: count, bigEndian: true)
        let start = offset + 17 + UInt64(count)
        guard length <= limit - start else { throw DolbyEError.malformed("MXF value exceeds source at \(offset)") }
        return Item(key: Data(header.prefix(16)), start: start, length: length)
    }
    static let dolbyE = ul("060e2b34040101010402020203021c00")
    static let fill = ul("060e2b34010101020301021001000000")
    static let primer = ul("060e2b34020501010d01020101050100")
    static let sound = ul("060e2b34040101010103020202000000")
    static func essence(clip: Bool, count: Int = 1, number: Int = 1) -> Data {
        var key = ul(clip ? "060e2b34010201010d01030116010201" : "060e2b34010201010d01030116010101")
        key[13] = UInt8(count); key[15] = UInt8(number)
        return key
    }
    static func container(clip: Bool) -> Data { ul(clip ? "060e2b34040101010d01030102060200" : "060e2b34040101010d01030102060100") }
    static func operation(clip: Bool) -> Data { ul(clip ? "060e2b34040101020d01020110000000" : "060e2b34040101010d01020101010100") }
    static func local(_ value: Data) throws -> [UInt16: Data] {
        var result: [UInt16: Data] = [:]
        var offset = 0
        while offset < value.count {
            guard value.count - offset >= 4 else { throw DolbyEError.malformed("truncated MXF local item") }
            let tag = UInt16(try value.integer(at: offset, bytes: 2, bigEndian: true))
            let count = Int(try value.integer(at: offset + 2, bytes: 2, bigEndian: true))
            offset += 4
            guard count <= value.count - offset, result[tag] == nil else { throw DolbyEError.malformed("invalid or duplicate MXF local item") }
            result[tag] = Data(value[offset..<(offset + count)])
            offset += count
        }
        return result
    }
}

/// ST 382 BWF sound tracks, frame wrapped for OP-1A and clip wrapped for
/// OP-Atom. ED2 OP-1A has two separate AES-pair sound elements and linked
/// eight-channel descriptors. Paired OP-Atom files use DolbyED2MediaWriter.
/// Encoded channel count and carrier alignment are independent properties.
public final class DolbyEMXFWriter {
    public struct Checkpoint: Codable, Sendable {
        let format: DolbyEOutputFormat
        let rate: DolbyEFrameRate
        let channelCount: Int
        let compressed: Bool
        let ids: [Data]
        let timestamp: Data
        let header: Data
        // Version 2 uses the normative ST 382 essence BER lengths. Missing
        // versions identify older checkpoints and are rejected explicitly.
        let layoutVersion: Int?
        public let dataBytes: UInt64
        public let videoFrames: UInt64
    }
    public let channelCount: Int
    public private(set) var dataBytes: UInt64
    public private(set) var videoFrames: UInt64
    private let format: DolbyEOutputFormat
    private let rate: DolbyEFrameRate
    private let compressed: Bool
    private let ids: [Data]
    private let timestamp: Data
    private let handle: FileHandle
    private var header = Data()
    private var finished = false
    private var clip: Bool { format == .mxfOPAtom }
    private var alignment: Int { channelCount * 3 }
    private var elementCount: Int { compressed && channelCount == 4 ? 2 : 1 }
    private var elementAlignment: Int { alignment / elementCount }
    private var essenceStart: UInt64 { 16384 + 129 + (clip ? 24 : 0) }
    private var endOfEssence: UInt64 { essenceStart + dataBytes + (clip ? 0 : videoFrames * UInt64(20 * elementCount)) }

    public init(url: URL, format: DolbyEOutputFormat, frameRate: DolbyEFrameRate,
                channelCount: Int, dolbyE: Bool) throws {
        guard format != .pcm, (dolbyE ? [2, 4].contains(channelCount) : (1...16).contains(channelCount)),
              !(format == .mxfOPAtom && dolbyE && channelCount == 4),
              !FileManager.default.fileExists(atPath: url.path) else { throw DolbyEError.invalidArgument("invalid MXF output or existing file") }
        self.format = format; self.rate = frameRate; self.channelCount = channelCount; self.compressed = dolbyE
        self.ids = (0..<(dolbyE && channelCount == 4 ? 24 : 16)).map { _ in var value = UUID().uuid; return withUnsafeBytes(of: &value) { Data($0) } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let time = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        self.timestamp = DolbyEMXFKLV.bytes(UInt64(time.year!), 2)
            + Data([UInt8(time.month!), UInt8(time.day!), UInt8(time.hour!), UInt8(time.minute!), UInt8(time.second!), 0])
        self.dataBytes = 0; self.videoFrames = 0
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        self.handle = try FileHandle(forUpdating: url)
        do {
            header = try makeHeader(complete: false, footer: 0)
            try handle.write(contentsOf: header)
        } catch { try? handle.close(); throw error }
    }

    public init(resuming url: URL, checkpoint: Checkpoint, recoveringFinalization: Bool = false) throws {
        guard checkpoint.layoutVersion == 2 else {
            throw DolbyEError.unsupported("legacy MXF checkpoint uses a different essence BER layout; resume with the original writer or start a new output")
        }
        guard checkpoint.format != .pcm,
              (checkpoint.compressed ? [2, 4].contains(checkpoint.channelCount) : (1...16).contains(checkpoint.channelCount)),
              !(checkpoint.format == .mxfOPAtom && checkpoint.compressed && checkpoint.channelCount == 4),
              checkpoint.ids.count == (checkpoint.compressed && checkpoint.channelCount == 4 ? 24 : 16),
              checkpoint.ids.allSatisfy({ $0.count == 16 }), checkpoint.timestamp.count == 8,
              checkpoint.header.count == 16384 + 129 + (checkpoint.format == .mxfOPAtom ? 24 : 0),
              checkpoint.dataBytes % UInt64(checkpoint.channelCount * 3) == 0,
              checkpoint.videoFrames <= UInt64(Int64.max / 48048000) else { throw DolbyEError.malformed("invalid MXF writer checkpoint") }
        self.format = checkpoint.format; self.rate = checkpoint.rate; self.channelCount = checkpoint.channelCount
        self.compressed = checkpoint.compressed; self.ids = checkpoint.ids; self.timestamp = checkpoint.timestamp
        self.dataBytes = checkpoint.dataBytes; self.videoFrames = checkpoint.videoFrames
        self.handle = try FileHandle(forUpdating: url)
        do {
            let bytes = try readBytes(handle, at: 0, count: checkpoint.header.count)
            let completeHeader = recoveringFinalization ? try makeHeader(complete: true, footer: endOfEssence) : Data()
            guard bytes == checkpoint.header || bytes == completeHeader,
                  try handle.seekToEnd() >= endOfEssence else { throw DolbyEError.malformed("MXF output identity or durable length changed") }
            header = checkpoint.header
            try handle.seek(toOffset: 0); try handle.write(contentsOf: header)
            try handle.truncate(atOffset: endOfEssence); try handle.seek(toOffset: endOfEssence)
        } catch { try? handle.close(); throw error }
    }
    deinit { try? handle.close() }

    private func cumulativeSamples(_ index: UInt64) -> UInt64 {
        // The analysis converter consumes floor(N*r) input samples;
        // the inverse emits ceil(N*r), starting at phase zero. Preserve that
        // one-sample phase difference instead of dropping a decoded sample.
        let scaled = index * UInt64(48000 * rate.denominator)
        return (scaled + (compressed ? 0 : UInt64(rate.numerator - 1))) / UInt64(rate.numerator)
    }
    private func append(_ bytes: Data) throws {
        guard !finished, videoFrames < UInt64(Int64.max / 48048000),
              bytes.count == Int(cumulativeSamples(videoFrames + 1) - cumulativeSamples(videoFrames)) * alignment else {
            throw DolbyEError.invalidArgument("MXF edit unit does not match the rational audio cadence")
        }
        if clip { try handle.write(contentsOf: bytes) }
        else {
            for element in 0..<elementCount {
                let value: Data
                if elementCount == 1 { value = bytes }
                else {
                    var separated = Data(capacity: bytes.count / elementCount)
                    for sample in stride(from: 0, to: bytes.count, by: alignment) {
                        let start = sample + element * elementAlignment
                        separated.append(bytes[start..<(start + elementAlignment)])
                    }
                    value = separated
                }
                guard value.count <= 0xffffff else { throw DolbyEError.invalidArgument("MXF frame exceeds the ST 382 BER length") }
                let key = DolbyEMXFKLV.essence(clip: false, count: elementCount, number: element + 1)
                try handle.write(contentsOf: key + Data([0x83]) + DolbyEMXFKLV.bytes(UInt64(value.count), 3))
                try handle.write(contentsOf: value)
            }
        }
        dataBytes += UInt64(bytes.count); videoFrames += 1
    }
    public func appendCarrier(_ words: [UInt32]) throws {
        guard compressed, [2, 4].contains(channelCount), words.count <= 8192,
              words.count % channelCount == 0,
              words.allSatisfy({ $0 & 255 == 0 }) else { throw DolbyEError.invalidArgument("invalid MXF Dolby E carrier") }
        var data = Data(capacity: words.count * 3)
        for word in words { data.append(contentsOf: [UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]) }
        try append(data)
    }
    public func appendPCM(_ samples: [Double]) throws {
        guard !compressed, samples.count <= 8192 * channelCount, samples.count % channelCount == 0,
              samples.allSatisfy(\.isFinite) else { throw DolbyEError.invalidArgument("invalid MXF PCM block") }
        var data = Data(capacity: samples.count * 3)
        for sample in samples {
            let word = UInt32(bitPattern: Int32(max(-8388608, min(8388607, (sample * 8388608).rounded(.toNearestOrEven)))))
            data.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16)])
        }
        try append(data)
    }
    public func checkpoint() throws -> Checkpoint {
        guard !finished else { throw DolbyEError.invalidArgument("MXF already finalized") }
        try handle.synchronize()
        return Checkpoint(format: format, rate: rate, channelCount: channelCount, compressed: compressed,
            ids: ids, timestamp: timestamp, header: header, layoutVersion: 2, dataBytes: dataBytes, videoFrames: videoFrames)
    }
    public func finish() throws {
        guard !finished else { throw DolbyEError.invalidArgument("MXF already finalized") }
        let footer = endOfEssence
        // VBR index segments are bounded to fit the 16-bit local-item length.
        let cbr = clip || (48000 * rate.denominator) % rate.numerator == 0
        let count = clip ? cumulativeSamples(videoFrames) : videoFrames
        let entriesPerSegment: UInt64 = elementCount == 2 ? 4000 : 5000
        let segments = cbr ? 1 : max(1, (videoFrames + entriesPerSegment - 1) / entriesPerSegment)
        var indexBytes: UInt64 = 0
        for index in 0..<segments {
            let start = cbr ? 0 : index * entriesPerSegment
            let duration = cbr ? count : min(entriesPerSegment, count - start)
            indexBytes += UInt64(try makeIndex(start: start, duration: duration, constant: cbr).count)
        }
        try handle.seek(toOffset: footer)
        try handle.write(contentsOf: partition(kind: 4, complete: true, position: footer, previous: 16384, footer: footer, headerBytes: 0, indexBytes: indexBytes, bodySID: 0))
        for index in 0..<segments {
            let start = cbr ? 0 : index * entriesPerSegment
            let duration = cbr ? count : min(entriesPerSegment, count - start)
            try handle.write(contentsOf: makeIndex(start: start, duration: duration, constant: cbr))
        }
        let ripKey = DolbyEMXFKLV.ul("060e2b34020501010d01020101110100")
        let rip = DolbyEMXFKLV.bytes(0, 4) + DolbyEMXFKLV.bytes(0, 8)
            + DolbyEMXFKLV.bytes(1, 4) + DolbyEMXFKLV.bytes(16384, 8)
            + DolbyEMXFKLV.bytes(0, 4) + DolbyEMXFKLV.bytes(footer, 8) + DolbyEMXFKLV.bytes(65, 4)
        try handle.write(contentsOf: DolbyEMXFKLV.packet(ripKey, rip))
        try handle.seek(toOffset: 0); try handle.write(contentsOf: makeHeader(complete: true, footer: footer))
        try handle.synchronize(); try handle.close(); finished = true
    }

    private func partition(kind: UInt8, complete: Bool, position: UInt64, previous: UInt64,
                           footer: UInt64, headerBytes: UInt64, indexBytes: UInt64, bodySID: UInt64) -> Data {
        var key = DolbyEMXFKLV.ul("060e2b34020501010d01020101020400")
        key[13] = kind; key[14] = complete ? 4 : 1
        let b = DolbyEMXFKLV.bytes
        var payload = b(1, 2) + b(3, 2) + b(1, 4)
        payload += b(position, 8) + b(previous, 8) + b(footer, 8)
        payload += b(headerBytes, 8) + b(indexBytes, 8) + b(indexBytes > 0 ? 2 : 0, 4)
        payload += b(0, 8) + b(bodySID, 4) + DolbyEMXFKLV.operation(clip: clip)
        payload += b(1, 4) + b(16, 4) + DolbyEMXFKLV.container(clip: clip)
        return DolbyEMXFKLV.packet(key, payload)
    }
    private func makeHeader(complete: Bool, footer: UInt64) throws -> Data {
        let metadata = try makeMetadata(complete: complete)
        let fillBytes = 16384 - 129 - metadata.count
        guard fillBytes >= 25 else { throw DolbyEError.malformed("MXF metadata exceeds header reservation") }
        var data = partition(kind: 2, complete: complete, position: 0, previous: 0, footer: footer,
                             headerBytes: 16384 - 129, indexBytes: 0, bodySID: 0)
        data += metadata + DolbyEMXFKLV.packet(DolbyEMXFKLV.fill, Data(repeating: 0, count: fillBytes - 25))
        data += partition(kind: 3, complete: complete, position: 16384, previous: 0, footer: footer, headerBytes: 0, indexBytes: 0, bodySID: 1)
        if clip {
            guard dataBytes <= 0x00ff_ffff_ffff_ffff else { throw DolbyEError.invalidArgument("MXF clip exceeds the ST 382 BER length") }
            data += DolbyEMXFKLV.essence(clip: true) + Data([0x87]) + DolbyEMXFKLV.bytes(complete ? dataBytes : 0, 7)
        }
        return data
    }
    private func makeIndex(start: UInt64, duration: UInt64, constant: Bool) throws -> Data {
        let b = DolbyEMXFKLV.bytes
        let editRate = clip ? b(48000, 4) + b(1, 4) : b(UInt64(rate.numerator), 4) + b(UInt64(rate.denominator), 4)
        let unit = clip ? UInt64(alignment) : UInt64(20 * elementCount) + cumulativeSamples(1) * UInt64(alignment)
        var instance = ids[14]
        for index in 0..<8 { instance[8 + index] ^= UInt8(truncatingIfNeeded: start >> (index * 8)) }
        var fields: [(UInt16, Data)] = [(0x3c0a, instance), (0x3f0b, editRate), (0x3f0c, b(start, 8)),
            (0x3f0d, b(duration, 8)), (0x3f05, b(constant ? unit : 0, 4)), (0x3f06, b(2, 4)),
            (0x3f07, b(1, 4)), (0x3f08, b(!constant && elementCount == 2 ? 1 : 0, 1)), (0x3f0e, b(0, 1))]
        var deltas = b(UInt64(elementCount), 4) + b(6, 4) + Data(repeating: 0, count: 6)
        if elementCount == 2 {
            let offset = constant ? 20 + cumulativeSamples(1) * UInt64(elementAlignment) : 0
            deltas += Data([0, constant ? 0 : 1]) + b(offset, 4)
        }
        fields.append((0x3f09, deltas))
        if !constant {
            var entries = b(duration, 4) + b(elementCount == 2 ? 15 : 11, 4)
            for index in start..<(start + duration) {
                entries += Data([0, 0, 128]) + b(index * UInt64(20 * elementCount) + cumulativeSamples(index) * UInt64(alignment), 8)
                if elementCount == 2 {
                    let samples = cumulativeSamples(index + 1) - cumulativeSamples(index)
                    entries += b(20 + samples * UInt64(elementAlignment), 4)
                }
            }
            fields.append((0x3f0a, entries))
        }
        return try localPacket(key: DolbyEMXFKLV.ul("060e2b34025301010d01020101100100"), fields: fields)
    }
    private func localPacket(key: Data, fields: [(UInt16, Data)]) throws -> Data {
        var value = Data()
        for (tag, field) in fields {
            guard field.count <= 65535 else { throw DolbyEError.malformed("MXF local item too large") }
            value += DolbyEMXFKLV.bytes(UInt64(tag), 2) + DolbyEMXFKLV.bytes(UInt64(field.count), 2) + field
        }
        guard value.count <= 0x00ff_ffff else { throw DolbyEError.malformed("MXF local set exceeds four-byte BER capacity") }
        return key + Data([0x83]) + DolbyEMXFKLV.bytes(UInt64(value.count), 3) + value
    }
    private func makeMetadata(complete: Bool) throws -> Data {
        let b = DolbyEMXFKLV.bytes
        func batch(_ values: [Data], width: Int = 16) -> Data { b(UInt64(values.count), 4) + b(UInt64(width), 4) + values.reduce(Data(), +) }
        func string(_ text: String) -> Data { text.utf16.reduce(Data()) { $0 + b(UInt64($1), 2) } + b(0, 2) }
        func umid(_ index: Int) -> Data { DolbyEMXFKLV.ul("060a2b340101010501010f2013000000") + ids[index] }
        let operation = DolbyEMXFKLV.operation(clip: clip), container = DolbyEMXFKLV.container(clip: clip)
        let duration = complete ? (clip ? cumulativeSamples(videoFrames) : videoFrames) : UInt64.max
        let editRate = clip ? b(48000, 4) + b(1, 4) : b(UInt64(rate.numerator), 4) + b(UInt64(rate.denominator), 4)
        var sets: [(UInt8, [(UInt16, Data)])] = []
        sets.append((0x2f, [(0x3c0a, ids[0]), (0x3b02, timestamp), (0x3b05, b(0x0103, 2)), (0x3b07, b(1, 4)),
            (0x3b06, batch([ids[1]])), (0x3b03, ids[2]), (0x3b08, ids[clip ? 4 : 3]),
            (0x3b09, operation), (0x3b0a, batch([container])), (0x3b0b, batch([]))]))
        sets.append((0x30, [(0x3c0a, ids[1]), (0x3c09, ids[13]), (0x3c01, string("libdolbye")),
            (0x3c02, string("libdolbye")), (0x3c04, string("1.0")), (0x3c05, DolbyEMXFKLV.ul("972e01df8ad749d7a73c7ec324b90985")), (0x3c06, timestamp)]))
        sets.append((0x18, [(0x3c0a, ids[2]), (0x1901, batch([ids[3], ids[4]])), (0x1902, batch([ids[5]]))]))
        sets.append((0x23, [(0x3c0a, ids[5]), (0x2701, umid(12)), (0x3f06, b(2, 4)), (0x3f07, b(1, 4))]))
        for index in 0..<2 {
            let package = index == 0 ? 3 : 4
            let trackIDs = elementCount == 1 ? [index == 0 ? 6 : 7] : (index == 0 ? [6, 16] : [7, 17])
            var packageFields: [(UInt16, Data)] = [(0x3c0a, ids[package]), (0x4401, umid(index == 0 ? 15 : 12)),
                (0x4402, string(compressed ? (channelCount == 4 ? "Dolby ED2" : "Dolby E") : "Decoded PCM")),
                (0x4405, timestamp), (0x4404, timestamp), (0x4403, batch(trackIDs.map { ids[$0] }))]
            if index == 1 { packageFields.append((0x4701, ids[elementCount == 2 ? 23 : 13])) }
            sets.append((index == 0 ? 0x36 : 0x37, packageFields))
            for element in 0..<elementCount {
                let track = trackIDs[element]
                let sequence = element == 0 ? (index == 0 ? 8 : 9) : (index == 0 ? 18 : 19)
                let sourceClip = element == 0 ? (index == 0 ? 10 : 11) : (index == 0 ? 20 : 21)
                let key = DolbyEMXFKLV.essence(clip: clip, count: elementCount, number: element + 1)
                let number = try key.integer(at: 12, bytes: 4, bigEndian: true)
                sets.append((0x3b, [(0x3c0a, ids[track]), (0x4801, b(UInt64(element + 1), 4)),
                    (0x4804, b(index == 0 ? 0 : number, 4)),
                    (0x4803, ids[sequence]), (0x4b01, editRate), (0x4b02, b(0, 8))]))
                sets.append((0x0f, [(0x3c0a, ids[sequence]), (0x0201, DolbyEMXFKLV.sound),
                    (0x0202, b(duration, 8)), (0x1001, batch([ids[sourceClip]]))]))
                sets.append((0x11, [(0x3c0a, ids[sourceClip]), (0x0201, DolbyEMXFKLV.sound), (0x0202, b(duration, 8)),
                    (0x1201, b(0, 8)), (0x1101, index == 0 ? umid(12) : Data(repeating: 0, count: 32)),
                    (0x1102, b(index == 0 ? UInt64(element + 1) : 0, 4))]))
            }
        }
        for element in 0..<elementCount {
            var descriptor: [(UInt16, Data)] = [(0x3c0a, ids[element == 0 ? 13 : 22]),
                (0x3001, editRate), (0x3002, b(duration, 8)), (0x3004, container),
                (0x3d03, b(48000, 4) + b(1, 4)),
                (0x3d07, b(compressed ? 8 : UInt64(channelCount), 4)),
                (0x3d01, b(24, 4)), (0x3d0a, b(UInt64(elementAlignment), 2)),
                (0x3d09, b(UInt64(48000 * elementAlignment), 4)), (0x3d02, b(1, 1))]
            if elementCount == 2 { descriptor.append((0x3006, b(UInt64(element + 1), 4))) }
            if compressed { descriptor.append((0x3d06, DolbyEMXFKLV.dolbyE)) }
            sets.append((0x48, descriptor))
        }
        if elementCount == 2 {
            sets.append((0x44, [(0x3c0a, ids[23]), (0x3001, editRate), (0x3002, b(duration, 8)),
                (0x3004, container), (0x3f01, batch([ids[13], ids[22]]))]))
        }
        let tags = Set(sets.flatMap { $0.1.map { $0.0 } }).sorted()
        var primer = b(UInt64(tags.count), 4) + b(18, 4)
        for tag in tags {
            guard let label = DolbyEMXFPropertyLabels.values[tag] else { throw DolbyEError.malformed("unregistered MXF property \(tag)") }
            primer += b(UInt64(tag), 2) + label
        }
        var result = DolbyEMXFKLV.packet(DolbyEMXFKLV.primer, primer)
        for (kind, fields) in sets {
            var key = DolbyEMXFKLV.ul("060e2b34025301010d01010101010000"); key[14] = kind
            result += try localPacket(key: key, fields: fields)
        }
        return result
    }
}

/// Bounded ST 382 BWF extraction. The logical byte position spans KLV values
/// without copying a full track or retaining an unbounded per-frame index.
public final class DolbyEMXFReader {
    public let info: WavePCMInfo
    public let compressed: Bool
    private let handle: FileHandle
    private let fileSize: UInt64
    private struct Track {
        let key: Data
        let dataBytes: UInt64
        let alignment: Int
        let compressed: Bool
        var scanOffset: UInt64 = 0
        var logicalStart: UInt64 = 0
        var current: DolbyEMXFKLV.Item?
    }
    private var tracks: [Track]

    /// Without an explicit track selection, two synchronized Dolby E sound
    /// elements are presented as four logical carrier channels. The physical
    /// essence remains in separate ST 382 tracks; this reader interleaves only
    /// the caller's bounded read window.
    public init(url: URL, trackNumber: UInt32? = nil) throws {
        let file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd()
            var offset: UInt64 = 0
            var descriptors: [Data: [UInt16: Data]] = [:]
            var trackNumbers: [UInt64: Set<UInt64>] = [:]
            var totals: [Data: UInt64] = [:]
            var primer: [UInt16: UInt16] = [:]
            var metadataBytes: UInt64 = 0
            let setPrefix = DolbyEMXFKLV.ul("060e2b34025301010d0101010101")
            let essencePrefix = DolbyEMXFKLV.ul("060e2b34010201010d010301")
            while offset < size {
                try Task.checkCancellation()
                let item = try DolbyEMXFKLV.read(file, at: offset, limit: size)
                if item.key == DolbyEMXFKLV.primer {
                    guard item.length <= 16 * 1024 * 1024 else { throw DolbyEError.malformed("MXF primer exceeds bound") }
                    let value = try DolbyEReadMXFBytes(file, at: item.start, count: Int(item.length))
                    let count = try value.integer(at: 0, bytes: 4, bigEndian: true)
                    guard try value.integer(at: 4, bytes: 4, bigEndian: true) == 18, count <= UInt64((value.count - 8) / 18) else { throw DolbyEError.malformed("invalid MXF primer") }
                    let reverse = Dictionary(uniqueKeysWithValues: DolbyEMXFPropertyLabels.values.map { ($0.value, $0.key) })
                    for index in 0..<Int(count) {
                        let start = 8 + index * 18
                        let tag = UInt16(try value.integer(at: start, bytes: 2, bigEndian: true))
                        if let canonical = reverse[Data(value[(start + 2)..<(start + 18)])] { primer[tag] = canonical }
                    }
                } else if item.key.prefix(14) == setPrefix, [0x48, 0x3b].contains(item.key[14]) {
                    metadataBytes += item.length
                    guard metadataBytes <= 16 * 1024 * 1024 else { throw DolbyEError.malformed("MXF sound metadata exceeds bound") }
                    let fields = try DolbyEMXFKLV.local(DolbyEReadMXFBytes(file, at: item.start, count: Int(item.length)))
                    var canonical: [UInt16: Data] = [:]
                    for (tag, value) in fields { canonical[primer[tag] ?? tag] = value }
                    if item.key[14] == 0x3b {
                        if let id = canonical[0x4801], let number = canonical[0x4804], id.count == 4, number.count == 4 {
                            let value = try number.integer(at: 0, bytes: 4, bigEndian: true)
                            if value != 0 {
                                let trackID = try id.integer(at: 0, bytes: 4, bigEndian: true)
                                trackNumbers[trackID, default: []].insert(value)
                            }
                        }
                        offset = item.end
                        continue
                    }
                    guard let identifier = canonical[0x3c0a], identifier.count == 16 else {
                        throw DolbyEError.malformed("MXF sound descriptor has no instance identifier")
                    }
                    if let previous = descriptors[identifier] {
                        let structuralTags: [UInt16] = [0x3004, 0x3006, 0x3d06, 0x3d03, 0x3d01, 0x3d07, 0x3d0a, 0x3d09]
                        guard structuralTags.allSatisfy({ previous[$0] == canonical[$0] }) else {
                            throw DolbyEError.malformed("MXF sound descriptor properties change between partitions")
                        }
                    }
                    descriptors[identifier] = canonical
                } else if item.key.prefix(12) == essencePrefix, item.key[12] == 0x16,
                          [1, 2].contains(item.key[14]), (1...127).contains(item.key[13]), item.key[15] < 128 {
                    let next = (totals[item.key] ?? 0).addingReportingOverflow(item.length)
                    guard !next.overflow else { throw DolbyEError.malformed("MXF audio length overflow") }
                    totals[item.key] = next.partialValue
                    guard totals.count <= 128 else { throw DolbyEError.malformed("too many MXF sound elements") }
                }
                offset = item.end
            }
            var keys = totals.keys.sorted { $0.lexicographicallyPrecedes($1) }
            if let trackNumber {
                keys = try keys.filter { try $0.integer(at: 12, bytes: 4, bigEndian: true) == UInt64(trackNumber) }
                guard !keys.isEmpty else { throw DolbyEError.invalidArgument("requested MXF sound track is absent") }
            }
            guard !keys.isEmpty, keys.count <= 2, !descriptors.isEmpty else {
                throw DolbyEError.unsupported("select a supported ST 382 sound track")
            }
            var tracks: [Track] = []
            for key in keys {
                let number = try key.integer(at: 12, bytes: 4, bigEndian: true)
                var candidates = try descriptors.values.filter { descriptor in
                    guard let linked = descriptor[0x3006], linked.count == 4 else { return false }
                    let id = try linked.integer(at: 0, bytes: 4, bigEndian: true)
                    return trackNumbers[id]?.contains(number) == true
                }
                if candidates.isEmpty, descriptors.count == 1, totals.count == 1 { candidates = Array(descriptors.values) }
                guard candidates.count == 1, let descriptor = candidates.first, let total = totals[key], total > 0 else {
                    throw DolbyEError.unsupported("MXF sound descriptor cannot be associated unambiguously with its essence track")
                }
                func field(_ tag: UInt16, _ length: Int) throws -> UInt64 {
                    guard let value = descriptor[tag], value.count == length else { throw DolbyEError.malformed("missing or short MXF descriptor property \(tag)") }
                    return try value.integer(at: 0, bytes: length, bigEndian: true)
                }
                let compressed = descriptor[0x3d06] == DolbyEMXFKLV.dolbyE
                guard compressed || descriptor[0x3d06] == nil || descriptor[0x3d06] == DolbyEMXFKLV.ul("060e2b34040101010402020101000000") else { throw DolbyEError.unsupported("MXF sound compression") }
                guard descriptor[0x3d03] == DolbyEMXFKLV.bytes(48000, 4) + DolbyEMXFKLV.bytes(1, 4),
                      descriptor[0x3004] == DolbyEMXFKLV.container(clip: key[14] == 2),
                      try field(0x3d01, 4) == 24 else { throw DolbyEError.unsupported("MXF must carry 48 kHz packed 24-bit ST 382 audio") }
                let alignment = Int(try field(0x3d0a, 2)), channels = Int(try field(0x3d07, 4))
                guard alignment > 0, alignment % 3 == 0, total % UInt64(alignment) == 0,
                      (compressed ? alignment == 6 && channels == 8 : alignment == channels * 3 && (1...256).contains(channels)) else {
                    throw DolbyEError.malformed("MXF channel count and AES carrier block alignment disagree")
                }
                tracks.append(Track(key: key, dataBytes: total, alignment: alignment, compressed: compressed))
            }
            if tracks.count == 2 {
                guard tracks.allSatisfy({ $0.compressed && $0.key[13] == 2 && $0.key[14] == 1 }),
                      tracks[0].dataBytes == tracks[1].dataBytes else {
                    throw DolbyEError.unsupported("automatic paired MXF input requires two equally long frame-wrapped Dolby E tracks")
                }
            }
            let first = tracks[0], alignment = tracks.reduce(0) { $0 + $1.alignment }
            let total = tracks.reduce(UInt64(0)) { $0 + $1.dataBytes }
            self.info = WavePCMInfo(sampleRate: 48000, channelCount: alignment / 3, containerBits: 24, validBits: 24,
                channelMask: 0, floatingPoint: false, frameCount: first.dataBytes / UInt64(first.alignment), hasADM: false,
                hasChannelAssignment: false, hasDolbyMetadata: first.compressed, dataOffset: 0, dataBytes: total)
            self.compressed = first.compressed; self.handle = file; self.fileSize = size; self.tracks = tracks
        } catch { try? file.close(); throw error }
    }
    deinit { try? handle.close() }
    public func readBytes(atByte position: UInt64, count: Int) throws -> Data {
        guard position <= info.dataBytes, count >= 0, count <= 8192 * info.channelCount * 3,
              UInt64(count) <= info.dataBytes - position else { throw DolbyEError.invalidArgument("MXF audio read exceeds bounds") }
        if tracks.count == 1 { return try readTrack(0, atByte: position, count: count) }
        guard count > 0 else { return Data() }
        let startSample = position / 12, leading = Int(position % 12)
        let samples = (leading + count + 11) / 12
        let first = try readTrack(0, atByte: startSample * 6, count: samples * 6)
        let second = try readTrack(1, atByte: startSample * 6, count: samples * 6)
        var combined = Data(capacity: samples * 12)
        for sample in 0..<samples {
            let range = (sample * 6)..<(sample * 6 + 6)
            combined.append(first[range]); combined.append(second[range])
        }
        return Data(combined[leading..<(leading + count)])
    }

    private func readTrack(_ index: Int, atByte position: UInt64, count: Int) throws -> Data {
        var track = tracks[index]
        defer { tracks[index] = track }
        guard position <= track.dataBytes, count >= 0, count <= 8193 * track.alignment,
              UInt64(count) <= track.dataBytes - position else { throw DolbyEError.invalidArgument("MXF physical track read exceeds bounds") }
        if position < track.logicalStart { track.scanOffset = 0; track.logicalStart = 0; track.current = nil }
        var result = Data(capacity: count)
        var cursor = position
        while result.count < count {
            if track.current == nil {
                while track.scanOffset < fileSize {
                    let item = try DolbyEMXFKLV.read(handle, at: track.scanOffset, limit: fileSize)
                    track.scanOffset = item.end
                    if item.key == track.key { track.current = item; break }
                }
            }
            guard let item = track.current else { throw DolbyEError.malformed("MXF audio ran out before descriptor duration") }
            if cursor >= track.logicalStart + item.length { track.logicalStart += item.length; track.current = nil; continue }
            let offset = cursor - track.logicalStart
            let amount = Int(min(UInt64(count - result.count), item.length - offset))
            result += try DolbyEReadMXFBytes(handle, at: item.start + offset, count: amount)
            cursor += UInt64(amount)
        }
        return result
    }
}

// Avoid shadowing the shared file read helper inside DolbyEMXFReader.
private func DolbyEReadMXFBytes(_ file: FileHandle, at offset: UInt64, count: Int) throws -> Data {
    try readBytes(file, at: offset, count: count)
}
