<!-- Copyright © 2026 B00kerLouis. -->
<!-- SPDX-License-Identifier: LGPL-3.0-or-later -->
# Programme loudness and offline correction

Owner: B00kerLouis. Native Swift6/macOS12+, exported by both self-contained static Frameworks for measurement and by DolbyEEncoder for file correction.

```swift
import Foundation
import DolbyEEncoder

func normalizeMaster(input: URL, output: URL) async throws -> DolbyEFileResult {
    let settings = DolbyEOfflineLoudnessConfiguration(
        mode: .normalize, targetLUFS: -23, maximumTruePeakDBTP: -2.5,
        ed2Layout: .fiveOne, payloadVersion: .standard1
    )
    let request = DolbyERequest(
        inputURL: input, outputURL: output, encodeVision: .ed2,
        maximumParallelism: 4, loudness: settings
    )
    return try await DolbyEEncoding.encode(request)
}
```

Frame rate remains automatic from IAB/DAMF unless explicitly overridden. Nil `request.loudness` preserves the established processing profile. Decoder requests reject this encoder option; use the analyzer on decoded PCM. CLI equivalents:

```
--loudness measure|normalize
--loudness-target -23 --loudness-ceiling -2.5
--loudness-layout 5.1 --loudness-version 0|1
--loudness-tolerance 0.2 --workers 4
```

The ED2measurement layout defaults to5.1 in both CLI and Framework. Explicit9.1.6 or another discrete layout remains supported; this changes the measurement/correction reference, not the encoded bed or QCplayback layout. Existing checkpoints contain their explicit layout and remain owned by those settings; to resume a prior9.1.6job, specify9.1.6. Nil request.loudness stays off; --loudness measure measures/reports without normalization, while normalize enables correction. Target/ceiling/version defaults are-23LUFS/-2.5dBTP/standard1; dependent loudness settings require an enabled mode.

The workflow measures full-programme relative-gated loudness. It does not substitute a level gate for speech detection. Dolby E5.1+2 programmes are measured/corrected independently and receive measured programme dialnorm. ED2 measures the selected discrete Main render; its two AES pairs receive linked programme gain. Other target renders such as Stereo have separate measurements and are not implicitly certified at the same target. Per-signal mono instructions are not assigned a rendered Main loudness. `result.loudness` reports actual before/after values, layout, fixed gain and target status.

Correction uses a fixed whole-programme gain and smooth linked peak protection, followed by complete remeasurement. It never normalizes from a first silent frame or resets gain at frame boundaries. Corrected PCM is spectrally profiled with bounded state during the same completed analysis pass, so encoding can reuse its fixed shifts rather than reread/render the source for another profile. Completed old analysis plans without shifts retain the safe profiling pass. Source/sidecar identity and all DSP/energy/writer checkpoints are retained in SwiftData on macOS14+ or the Core Data compatibility store on macOS12/13; energy records remain beside the destination. No source PCM is staged.

`maximumParallelism` is a maximum budget, not a promise to occupy all threads in every stage. Channel measurement, spectral analysis and codec allocation/assembly use bounded independent workers with ordered commits. Real-window benchmarking rejected parallel full-speaker object buffers as slower; object rendering remains ordered/in-place. Assign budgets across simultaneous jobs instead of giving each process all cores. Same PCM/settings produce the same carrier words across tested serial/parallel execution.

For direct measurement, create `DolbyELoudnessAnalyzer(url:channelWeights:)` with a new energy-record URL on the source/output storage. Feed complete interleaved48kHz PCM blocks of1...8192frames through `append(_:maximumParallelism:)`. `DolbyELoudnessMeter.weights(speakers:)` applies the declared speaker directions; custom weights can be supplied explicitly. LFE contributes0to loudness but remains included in true-peak measurement. For objects, render the selected presentation before analysis and record the renderer/layout.

`measurement()` returns integrated loudness, maximum momentary/short-term loudness, LRA and programme true peak. Undefined values are nil. It does not load every gating block into RAM: externally recorded linear powers provide exact relative-gate scans and bounded radix percentile selection. This API owns its handle and is not Sendable. `checkpoint()` synchronizes and returns bounded filters/windows, record count, file identity and digest. Persist it together with the matching durable source position; `init(url:checkpoint:)` checks the complete committed energy prefix and truncates uncommitted tail data. Remove the caller-owned energy file only after its measurement/checkpoint is no longer needed.

`DolbyEProgrammeLoudness` models payload1. `.legacy0` implements the supplied reference's observed basic-field profile; unsupported extended legacy fields fail explicitly. `.standard1` implements the public AnnexH presence bits, fine/extended precision, programme boundary, maxima and LRA fields. Base legacy measurements quantize to0.5LU; standard1can report0.1LU. Nil means absent. Whole-programme maxima use their dedicated fields, never the interval-peak field. Reserved values and inconsistent presence/control fields reject instead of silently dropping data.

`DolbyED2MetadataContainer.programmeLoudness()` keeps codec-specific records separate and exposes timing, group and processing permission with the typed body. Unknown payload bytes/configuration stay available in the container. CRC/authentication validation is separate from typed semantic support. ED2 frame encoding and `DolbyERealtimeEncoder.encodeNext` accept an optional `programmeLoudness` value and reserve its exact size before audio allocation/authentication. Live callers must supply real measured data; this argument does not invent future whole-programme values. New file output uses the selected version, with a separate measurement-absent compatibility record. Payload21is not synthesized or copied as an unexplained constant.

Ordinary Dolby E retains its native programme metadata; it is not relabelled ED2 merely to add payload1. Full independent ED2 MGI/presentation qualification and general payload21body semantics remain separate from this implemented loudness workflow. Local complete-source validation records are retained separately from the source repository.
