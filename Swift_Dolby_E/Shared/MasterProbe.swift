// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyEMasterFamily: String, Codable, Sendable {
    case pcm
    case admBWF = "adm-bwf"
    case damf
    case imfIAB = "imf-iab"
}

public struct DolbyEMasterInfo: Codable, Sendable {
    public let family: DolbyEMasterFamily
    public let wave: WavePCMInfo?
    public let associatedFiles: [String]
    public let notes: [String]
}

/// Container identification only; recognition does not establish complete object rendering.
public enum DolbyEMasterProbe {
    static func resolveDAMFMember(descriptor: URL, name: String, kind: String) throws -> URL {
        let declared = descriptor.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        if FileManager.default.fileExists(atPath: declared.path) { return declared }
        // Renamed bundles occasionally retain their old member names. Accept
        // only one same-stem sibling; the actual CAF/metadata parsers still
        // validate its type, channel IDs and source identity before processing.
        let candidates = [descriptor.appendingPathExtension(kind), descriptor.deletingPathExtension().appendingPathExtension(kind)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard candidates.count == 1 else { throw DolbyEError.malformed("missing or ambiguous DAMF \(kind) member: \(name)") }
        return candidates[0]
    }
    public static func inspect(_ url: URL) throws -> DolbyEMasterInfo {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 4 else { throw DolbyEError.malformed("empty or short source") }
        let prefix = try readBytes(file, at: 0, count: Int(min(size, 16)))
        let magic = try prefix.ascii(at: 0, count: 4)
        if ["RIFF", "RF64", "BW64"].contains(magic) {
            let wave = try WavePCMReader(url: url).info
            return DolbyEMasterInfo(family: wave.hasADM ? .admBWF : .pcm, wave: wave,
                                    associatedFiles: [], notes: wave.hasADM
                                    ? ["ADM channel and object metadata detected."] : [])
        }
        if prefix.starts(with: [0x06, 0x0e, 0x2b, 0x34]) {
            return try inspectMXF(file, size: size)
        }
        if url.pathExtension.lowercased() == "atmos" {
            guard size <= 16 * 1024 * 1024 else { throw DolbyEError.malformed("DAMF descriptor exceeds parser bound") }
            let descriptor = String(decoding: try readBytes(file, at: 0, count: Int(size)), as: UTF8.self)
            var members: [String] = []
            for key in ["audio", "metadata"] {
                let lines = descriptor.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let line = lines.first(where: { $0.hasPrefix(key + ":") }) else {
                    throw DolbyEError.malformed("DAMF descriptor missing \(key) member")
                }
                var name = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
                guard !name.isEmpty else { throw DolbyEError.malformed("empty DAMF \(key) member") }
                let member = try resolveDAMFMember(descriptor: url, name: name, kind: key == "audio" ? "audio" : "metadata")
                let memberFile = try FileHandle(forReadingFrom: member)
                defer { try? memberFile.close() }
                if key == "audio" {
                    let caf = try readBytes(memberFile, at: 0, count: 8)
                    guard try caf.ascii(at: 0, count: 4) == "caff" else {
                        throw DolbyEError.unsupported("DAMF audio must be a CAF sidecar")
                    }
                }
                members.append(member.path)
            }
            return DolbyEMasterInfo(family: .damf, wave: nil, associatedFiles: members,
                                    notes: ["First DAMF presentation and audio/metadata sidecars identified."])
        }
        throw DolbyEError.unsupported("source is not PCM WAVE, ADM BWF, DAMF, or IMF IAB MXF")
    }

    private static func inspectMXF(_ file: FileHandle, size: UInt64) throws -> DolbyEMasterInfo {
        let essenceKey = Data([0x06, 0x0e, 0x2b, 0x34, 0x01, 0x02, 0x01, 0x01,
                              0x0d, 0x01, 0x03, 0x01, 0x16, 0x01, 0x0d, 0x01])
        var offset: UInt64 = 0
        var found = false
        while offset < size {
            guard size - offset >= 17 else { throw DolbyEError.malformed("truncated MXF KLV") }
            let klv = try readBytes(file, at: offset, count: 17)
            guard klv.starts(with: [0x06, 0x0e, 0x2b, 0x34]) else {
                throw DolbyEError.malformed("invalid MXF key at byte \(offset)")
            }
            let first = klv[16]
            var length = UInt64(first)
            var headerBytes: UInt64 = 17
            if first & 0x80 != 0 {
                let count = Int(first & 0x7f)
                guard (1...8).contains(count), UInt64(count) <= size - offset - 17 else {
                    throw DolbyEError.malformed("invalid BER length at byte \(offset)")
                }
                length = try readBytes(file, at: offset + 17, count: count).integer(at: 0, bytes: count, bigEndian: true)
                headerBytes += UInt64(count)
            }
            guard headerBytes <= size - offset, length <= size - offset - headerBytes else {
                throw DolbyEError.malformed("MXF value exceeds source bounds")
            }
            if Data(klv.prefix(16)) == essenceKey, length > 0 { found = true }
            offset += headerBytes + length
        }
        guard found else { throw DolbyEError.unsupported("MXF has no IMF IAB essence key") }
        return DolbyEMasterInfo(family: .imfIAB, wave: nil, associatedFiles: [],
                                notes: ["IMF IAB audio essence identified."])
    }
}
