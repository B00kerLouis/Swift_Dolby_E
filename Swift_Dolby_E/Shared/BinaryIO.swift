// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Detach Cocoa/NSData backing at persistence boundaries. Re-encoding a
/// long-lived Cocoa bookmark into thousands of model snapshots can otherwise
/// build a recursive Data/NSData ownership chain on supported macOS versions.
/// Only bounded metadata is copied; this is never used to stage source media.
func DolbyEOwnedMetadata(_ data:Data)->Data {
    data.withUnsafeBytes {bytes in
        guard let base=bytes.baseAddress,!bytes.isEmpty else{return Data()}
        return Data(bytes:base,count:bytes.count)
    }
}

extension Data {
    func integer(at offset: Int, bytes: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, (1...8).contains(bytes), offset <= count, bytes <= count - offset else {
            throw DolbyEError.malformed("integer outside buffer at byte \(offset)")
        }
        var result: UInt64 = 0
        for index in 0..<bytes {
            let shift = bigEndian ? (bytes - index - 1) * 8 : index * 8
            result |= UInt64(self[startIndex + offset + index]) << shift
        }
        return result
    }

    func ascii(at offset: Int, count length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw DolbyEError.malformed("text outside buffer")
        }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + length)], as: UTF8.self)
    }
}

/// Each read is bounded by its caller. Chunk sizes from an untrusted file must be checked first.
func readBytes(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
    guard count >= 0, count <= 16 * 1024 * 1024 else {
        throw DolbyEError.malformed("read exceeds 16 MiB parser bound")
    }
    try handle.seek(toOffset: offset)
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
        guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
            throw DolbyEError.malformed("unexpected EOF at byte \(offset + UInt64(data.count))")
        }
        data.append(part)
    }
    return data
}
