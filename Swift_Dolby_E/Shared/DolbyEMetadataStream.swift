// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// A metadata chunk can be large while each physical read remains bounded.
/// XMLParser receives only this byte range, never adjacent audio or RIFF data.
final class DolbyEMetadataStream: InputStream {
    private let file: FileHandle
    private let range: Range<UInt64>
    private var position: UInt64
    private var state: Stream.Status = .notOpen
    private var failure: (any Error)?
    init(url: URL, range: Range<UInt64>) throws {
        let file = try FileHandle(forReadingFrom: url)
        guard range.upperBound <= (try file.seekToEnd()) else { try? file.close(); throw DolbyEError.malformed("metadata range exceeds source") }
        self.file = file; self.range = range; self.position = range.lowerBound
        super.init(data: Data())
    }
    override func open() { if state == .notOpen { state = .open } }
    override func close() { try? file.close(); state = .closed }
    override var streamStatus: Stream.Status { state }
    override var streamError: (any Error)? { failure }
    override var hasBytesAvailable: Bool { (state == .open || state == .notOpen) && position < range.upperBound }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>) -> Bool { false }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if state == .notOpen { open() }
        guard state == .open, len > 0 else { return state == .error ? -1 : 0 }
        if position == range.upperBound { state = .atEnd; return 0 }
        do {
            let count = Int(min(UInt64(min(len, 65536)), range.upperBound - position))
            let bytes = try readBytes(file, at: position, count: count)
            bytes.copyBytes(to: buffer, count: count); position += UInt64(count)
            return count
        } catch { failure = error; state = .error; return -1 }
    }
    deinit { try? file.close() }
}
