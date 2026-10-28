// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

public enum DolbyEEncodingPhase: String, Codable, Sendable {
    case preparing, measuringLoudness, normalizingLoudness, profiling, encoding, finalizing, completed
}

/// A value snapshot of file encoding. Only completed work advances progress;
/// 100 percent means validated output publication and job completion succeeded.
public struct DolbyEEncodingProgress: Sendable {
    public let phase: DolbyEEncodingPhase
    public let fractionCompleted: Double
    public let processedSourceFrames: UInt64
    public let totalSourceFrames: UInt64
    /// One-based analysis pass; zero outside whole-programme analysis.
    public let pass: Int
}

/// Called synchronously on the processing worker. Dispatch UI updates onto the
/// main actor; keep this callback short. It never receives mutable codec state.
public typealias DolbyEEncodingProgressHandler = @Sendable (DolbyEEncodingProgress) -> Void

/// Owned by one file worker. Two equal work budgets cover source analysis and
/// encoding; normalization reserves its bounded five passes without regressions.
final class DolbyEEncodingProgressReporter {
    static let maximumNormalizationPasses = 5

    private let handler: DolbyEEncodingProgressHandler?
    private let normalization: Bool
    private var lastFraction = 0.0
    private var lastPhase: DolbyEEncodingPhase?
    private var lastPass = -1
    private var lastEmission: UInt64?

    init(request: DolbyERequest, handler: DolbyEEncodingProgressHandler?) {
        self.handler = handler
        normalization = request.loudness?.mode == .normalize
        emit(.preparing, processed: 0, total: 0)
    }

    func emit(_ phase: DolbyEEncodingPhase, processed: UInt64, total: UInt64, pass: Int = 0) {
        guard let handler else { return }
        let sourceFraction = total == 0 ? 0 : Double(min(processed, total)) / Double(total)
        let fraction: Double
        switch phase {
        case .preparing: fraction = 0
        case .measuringLoudness, .normalizingLoudness:
            fraction = 0.49 * (Double(max(0, pass - 1)) + sourceFraction) / Double(normalization ? Self.maximumNormalizationPasses : 1)
        case .profiling: fraction = 0.49 * sourceFraction
        case .encoding: fraction = 0.49 + 0.5 * sourceFraction
        case .finalizing: fraction = 0.99
        case .completed: fraction = 1
        }
        let now = DolbyEMonotonicTime.now
        if phase == lastPhase, pass == lastPass, let lastEmission,
           now - lastEmission < 200_000_000 { return }
        lastFraction = max(lastFraction, fraction)
        lastPhase = phase; lastPass = pass; lastEmission = now
        handler(.init(phase: phase, fractionCompleted: lastFraction,
                      processedSourceFrames: min(processed, total), totalSourceFrames: total, pass: pass))
    }
}
