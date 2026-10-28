<!-- Copyright © 2026 B00kerLouis. -->
<!-- SPDX-License-Identifier: LGPL-3.0-or-later -->
# Encoder execution and1X output

Owner: B00kerLouis. Requires macOS12+, Swift6. The APIs are exported by the self-contained static `DolbyEEncoder` Xcode Framework.

`DolbyERequest.maximumParallelism` and the frame APIs' trailing argument select a worker budget:0=bounded automatic (currently up to8),1=serial,2...16=maximum workers, capped by available processors. CLI uses `--workers`. This affects execution only; encoded syntax and the v18 recovery signature are unchanged. File jobs keep whole-programme profiling, SwiftData/Core Data recovery, bounded external reads and atomic output publication.

`DolbyERealtimeEncoder` accepts one complete48kHz PCM block at a time and publishes complete carrier edit units at1X using a monotonic sample clock. Use `requiredInputFrames()` for each call, including fractional cadences. E input has8signals; ED2 has16signals plus actual `DolbyED2SceneMetadata`. ED2 returns separate `primaryWords` and `expansionWords`, each a two-channel AES pair. Words are UInt32 with20significant bits left-aligned, matching `DolbyEWaveWriter.appendCarrier`.

```swift
import DolbyEEncoder

func publishE(
    source: @Sendable (Int) async throws -> [Double]?,
    sink: @Sendable (DolbyERealtimeFrame) async throws -> Void
) async throws {
    let encoder = try DolbyERealtimeEncoder(frameRate: .fps24)
    while true {
        let count = try await encoder.requiredInputFrames()
        guard let pcm = try await source(count) else { break }
        let packet = try await encoder.encodeNext(pcm)
        try await sink(packet)
    }
}
```

ED2 prepared signals and actual metadata use the corresponding call:

```swift
func publishPreparedED2(
    rate: DolbyEFrameRate,
    shifts: [Int],
    source: @Sendable (Int) async throws -> (samples: [Double], scene: DolbyED2SceneMetadata)?,
    sink: @Sendable (DolbyERealtimeFrame) async throws -> Void
) async throws {
    let encoder = try DolbyERealtimeEncoder(
        encodeVision: .ed2, frameRate: rate, spectralShifts: shifts
    )
    while true {
        let count = try await encoder.requiredInputFrames()
        guard let block = try await source(count) else { break }
        let packet = try await encoder.encodeNext(
            block.samples, scene: block.scene, preparedObjectPCM: true
        )
        try await sink(packet)
    }
}
```

Set `preparedObjectPCM` only when authored object gain/windows/zones are already applied into PCM, as in the file adapter. Otherwise retain false so the supplied scene describes the raw signals correctly. Routing and limiter preparation must match the intended programme. The live API does not silently render arbitrary source tracks, import IAB/DAMF, perform whole-file analysis, or add another limiter to ready PCM.

The source supplies complete blocks, including explicit final-block padding and codec tail for a finite programme; nil means no more blocks to encode. These frame-level APIs do not silently discard a partial last block or manufacture an end-of-stream trajectory.

For known media, `DolbyESpectralProfiler` accepts the same complete routed/limited PCM blocks, preserves bounded DSP history and returns one `spectralShifts()` vector. Feed the complete programme (including intended tail), then initialize a fresh encoder with those fixed shifts. A first silent block is not a programme profile. For an unknown future live signal, nil shifts means a neutral all-zero shift vector; it does not automatically reproduce the offline encoder's measured quiet-signal normalization. Same PCM, scene/prepared flag, shifts and metadata produce the same carrier in serial/parallel/realtime execution.

`startupLeadFrames` defaults to3 and is scheduling lead time, not an unbounded pre-encoded queue. `maximumLateness` defaults to20ms. Encoding and publication overruns throw `DolbyEError.outputUnavailable` without committing that frame's DSP. No packet is replaced by silence, repeated or skipped. Cancellation while waiting similarly leaves the failed frame uncommitted. Call `resynchronizeClock()` after cancelling a pending call or after a pause/overrun to rebase wall time while retaining all DSP, counters and rational resampler phase. Concurrent `encodeNext` calls are rejected.

`checkpoint()` returns bounded versioned codec history plus logical frame/sample positions. The clock instant is excluded; `init(checkpoint:...)` starts a new publication epoch. Caller file/source identity, source cursor and corresponding durable output position must be persisted together in the platform job store. Save a checkpoint only after its packet is durable; after a sink failure restore the last durable source/codec checkpoint. Checkpoint/resynchronization requests during an in-flight frame are rejected.

`deadline`, `encodingDuration` and `lateness` expose actual timing. The publication period derives from cumulative carrier samples/48000 with integer arithmetic. These are packet-publication APIs, not physical CoreAudio AES3 C/U/V/P generation or video genlock. A hardware sink needs its own buffering and device clock integration. Sustained1X requires encoder plus caller processing to fit the period; deadline errors make an overloaded host visible. Full IAB/DAMF preparation and whole-file profiling are separate stages and must be budgeted independently.

## File encoding progress

Both `DolbyEEncoder` and `DolbyEEncoderDynamic` export the same file progress API:

```swift
let result = try await DolbyEEncoding.encode(request) { progress in
    // This synchronous callback runs on the encoding worker.
    // Send this immutable value to the UI's main actor when needed.
    print(progress.phase.rawValue, progress.fractionCompleted)
}
```

The original `encode(_:)` overload remains available. The callback receives
`DolbyEEncodingProgress` with `phase`, `fractionCompleted` (0...1),
`processedSourceFrames`, `totalSourceFrames`, and a one-based analysis `pass`
(zero outside analysis). Callbacks are synchronous, serialized within that job,
and limited to five per second apart from phase/pass changes. Keep callbacks
short; they receive no file handles or mutable DSP state. Catch thrown errors
from `encode` as before. A failed or cancelled invocation never emits `completed`.

Phases cover preparing, measuring loudness, normalizing loudness, profiling,
encoding, finalizing and completed. Source analysis reserves 49% of the total,
encoding 50%, and successful finalization 1%. Normalize reserves its bounded five
analysis passes; convergence can skip unused budget. This work estimate is
monotonic within an invocation, including restored checkpoints, and is not an
elapsed-time estimate. Resume starts with preparing and then advances to restored
work. Source indexing remains preparing until its frame count is known. Completed
and 100% are emitted only after output validation, atomic publication and the
completed job save. Progress is observational and does not change recovery
signatures, checkpoint cadence, codec state or worker budgets.

CLI terminal encoding displays this total on stderr. Successful encoding is quiet
on stdout unless `--json` is supplied; `--probe`/`--plan` retain JSON output. When
stderr is redirected there is no progress animation. Release CLI routes Core Data
diagnostics to the macOS unified log using process-local settings; returned errors
still print `error:` and exit nonzero. Frameworks do not change host logging settings.

## macOS 12 timing and recovery

`maximumLatenessNanoseconds` (default 20,000,000) and packet fields
`deadlineUptimeNanoseconds`, `encodingDurationNanoseconds` and `latenessNanoseconds`
are available on macOS 12+. Deadlines use the continuous monotonic nanosecond clock;
wall-clock changes do not affect scheduling. On macOS 13+, the `maximumLateness:
Duration` initializer and `deadline`, `encodingDuration`, `lateness` convenience
properties remain available. File recovery uses Core Data on macOS 12/13 and the
original SwiftData schema on macOS 14+, including one-time import of active
compatibility-store jobs after upgrade.
