// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Darwin
import DolbyEEncoder

/// The callback runs on the file worker; error cleanup runs on the CLI task.
/// One lock owns terminal state and serializes writes across those callers.
final class DolbyECLIEncodingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled = isatty(STDERR_FILENO) == 1
    private var previousWidth = 0
    private var active = false

    func update(_ progress: DolbyEEncodingProgress) {
        guard enabled else { return }
        lock.withLock {
            let label: String
            switch progress.phase {
            case .preparing: label = "Preparing"
            case .measuringLoudness: label = "Measuring loudness"
            case .normalizingLoudness: label = "Normalizing (pass \(progress.pass))"
            case .profiling: label = "Profiling"
            case .encoding: label = "Encoding"
            case .finalizing: label = "Finalizing"
            case .completed: label = "Completed"
            @unknown default: label = "Processing"
            }
            let filled = Int(progress.fractionCompleted * 24)
            let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: 24 - filled)
            let line = String(format: "Encode [%@] %5.1f%%  %@", bar, progress.fractionCompleted * 100, label)
            let padding = String(repeating: " ", count: max(0, previousWidth - line.count))
            let complete = progress.phase == .completed
            try? FileHandle.standardError.write(contentsOf: Data(("\r" + line + padding + (complete ? "\n" : "")).utf8))
            previousWidth = line.count
            active = !complete
        }
    }

    func endLine() {
        guard enabled else { return }
        lock.withLock {
            if active { try? FileHandle.standardError.write(contentsOf: Data([10])) }
            active = false
        }
    }
}
