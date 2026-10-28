<!-- Copyright © 2026 B00kerLouis. -->
<!-- SPDX-License-Identifier: LGPL-3.0-or-later -->
# Swift_Dolby_E

Native Swift 6 Dolby E / ED2 encoder, decoder and QC player for macOS 12+.
The Xcode project builds two self-contained static frameworks, two matching dynamic
frameworks and two command-line programs. The CLI tools statically link the codec;
`dolbye-decode --play` includes its native QC window in the executable. All runtime
dependencies come from macOS; no external codec executable or library is required.

## Build

Use Xcode 26.3 (17C529), Swift language mode 6, and the macOS SDK included with it.

```sh
xcodebuild -project Swift_Dolby_E.xcodeproj -scheme "Build ALL" -configuration Release -derivedDataPath Build build
```

`Build ALL` is an aggregate Target with a shared Scheme. Individual schemes remain
available: `DolbyEEncoder`, `DolbyEDecoder`, `DolbyEEncoderCLI`,
`DolbyEDecoderCLI`, `DolbyEEncoderDynamic` and `DolbyEDecoderDynamic`.
The deployment floor is macOS 12.0, with no configured upper OS bound.
`SDKROOT=macosx` uses the SDK supplied by the selected Xcode. Release builds include
arm64 and x86_64:

| Product | Location under `Build/Products/Release/` | Linkage |
| --- | --- | --- |
| Encoder framework | `DolbyEEncoder.framework` | Static archive |
| Decoder framework | `DolbyEDecoder.framework` | Static archive |
| Encoder CLI | `dolbye-encode` | Codec statically included |
| Decoder CLI / QC | `dolbye-decode` | Codec and QC window statically included |
| Encoder dynamic framework | `Dynamic/DolbyEEncoderDynamic.framework` | Dynamic library |
| Decoder dynamic framework | `Dynamic/DolbyEDecoderDynamic.framework` | Dynamic library |

Each framework contains its own shared DSP and I/O implementation and can be linked
independently. Both linkage variants compile the same physical Swift sources and
expose the same public APIs. Static consumers import `DolbyEEncoder` or
`DolbyEDecoder`; dynamic consumers import `DolbyEEncoderDynamic` or
`DolbyEDecoderDynamic`. Distinct module names keep Xcode dependency scanning
unambiguous when all variants build together.
To use dynamic linking in another Xcode project, link and embed the frameworks from
`Dynamic/`; their install names use `@rpath`. CLI targets link only the static
framework products and require no adjacent framework or app bundle.

To repeat the product linkage audit after building:

```sh
xcrun swift Scripts/CI/CheckProducts.swift Build/Products/Release
```

The audit verifies both architectures, macOS 12.0 deployment commands,
archive/executable/dylib types, weak linking for newer OS frameworks, dynamic install
names and the absence of runtime dependencies outside macOS system libraries.

On macOS 14 and later, recovery retains the original SwiftData stores. macOS 12/13
uses a separate Core Data `*.compat.store` with bounded metadata and the same codec
checkpoints. Active older-system jobs are imported into SwiftData on first access
after an OS upgrade. Bookmarks remain Base64 strings and source media stays in place.
The QC window uses SwiftUI/Combine on all supported versions.

## Encoding

```sh
Build/Products/Release/dolbye-encode -i master.mxf -o main.wav --encode-vision e -p 5.1+2 --downmix-mode loro
Build/Products/Release/dolbye-encode -i master.atmos -o main.wav --encode-vision ed2 --dialogue-source none
Build/Products/Release/dolbye-encode -i master.atmos -o measured.wav --encode-vision ed2 --loudness measure
Build/Products/Release/dolbye-encode -i master.atmos -o normalized.wav --encode-vision ed2 --loudness normalize
```

ED2 `pcm` and `mxf-opatom` treat `-o` as the shared base name: `-o main.wav`
writes `main_AES1.wav` for the primary stream and `main_AES2.wav` for expansion.
An existing `_AES1`/`_AES2` suffix is normalized without duplication. A supplied
output name ending in `.AES1` also produces underscore names. `mxf-op1a` remains a single
file at the requested path. `--plan` and `--json` report the actual output paths.
Older `.AES1`/`.AES2` input pairs remain readable; existing files are not renamed.

Input paths support discrete PCM WAVE, ADM BWF, DAMF and implemented IAB profiles.
Read source audio directly from its original storage. Output formats are `pcm`
(24-bit BWF/RF64 containing a 20-bit carrier), `mxf-op1a` and `mxf-opatom`.
Processing uses bounded reads, stateful DSP, durable job checkpoints and atomic
publication without overwriting an existing destination.

- Dolby E programme configurations: `5.1+2`, `7.1-scrn`, and low-level `8x1`.
  The `+2` is an independent Stereo programme; Screen uses extra front channels.
- ED2 file encoding currently routes a 5.1.2 bed plus eight aggregate object slots
  into two synchronized eight-signal substreams. Reduction of more source objects
  is spatially lossy. Flexible file-level bed/object/Stereo allocation is unfinished.
- `--dialogue-source none|bed-c` defaults to `none`. Center extraction must only
  be selected when that source channel is intended to be separate dialogue.
- `--frame-rate 24000/1001|24|25|30000/1001|30` overrides the source cadence.
  Otherwise supported DAMF/IAB sources use their embedded rate; ordinary PCM uses25.
- Audio input is48kHz. Other carrier widths, sample rates and programme
  configurations are outside the implemented product profile.
- `--input-layout auto|5.1|5.1.2|7.1|7.1-scrn|5.1+2` identifies PCM semantics.
  ED2 plain PCM currently accepts6ch5.1 or explicit8ch5.1.2.
- `--downmix-mode ltrt|loro` defaults to `ltrt` for generated Stereo.
- Encoding shows one total progress bar on an interactive terminal, covering
  analysis, encoding and finalization. Release CLI keeps Core Data diagnostics
  in the macOS unified log and reports actual failures on stderr with a nonzero
  exit status. Redirected stderr has no progress animation.
- `--json` opts into the final encoding result on stdout. `--probe` and `--plan`
  continue to return JSON. Ordinary successful encoding prints only its progress bar.
- Framework file clients can use `DolbyEEncoding.encode(_:progress:)`; see the
  [progress API](Swift_Dolby_E/Encoder/REALTIME-API.md#file-encoding-progress).
- `--workers 0` is optional bounded automatic execution, up to8 available workers;
  `1` is serial and `2...16` supplies a maximum budget capped by available CPUs.
- Loudness is off unless `--loudness measure|normalize` is supplied. Enabled ED2
  measurement defaults to a5.1Main render, -23LUFS, -2.5dBTP and payload1version1.
  Eprogrammes are measured independently. Use `--loudness-layout` to override the
  measurement render. This does not change the encoded bed or playback layout.

[Programme loudness API](Swift_Dolby_E/Encoder/LOUDNESS-API.md) and
[parallel/1X API](Swift_Dolby_E/Encoder/REALTIME-API.md) document framework usage.
The1X interface accepts ready PCM and scenes; full source preparation is separate.

## Decoding and QC

`--play` opens AppKit/SwiftUI directly in the CLI process, including when no input
is provided. There is no application Target or companion `.app` requirement.

Direct monitoring sends renderer channel N to output-driver channel N, within
channels 1–16, without speaker-label detection or speaker-order remapping. Unlabelled
virtual devices such as Pro Tools Audio Bridge 16 are supported. Driver channels
beyond the render count receive zero; a smaller driver receives the matching first
channels. Select Downmix explicitly to fold the render into the endpoint layout;
unlabelled endpoints default to stereo on outputs 1–2 in that mode. Meters Only
keeps the renderer active without opening an audio device.

Meters use an independent display clock and one Canvas for the channel bank.
Only display start/stop/topology changes invalidate that schedule. Real rendered
frame peaks arrive through `DolbyEPlaybackSession.meterUpdates()`, a newest-value
stream bounded to one pending event; full metadata snapshots do not drive meter
redraws. Display-only attack/release ballistics do not change audio samples.
`Clear Pair` unloads both inputs, stops playback, cancels pending navigation and
clears the meter epoch before another pair is imported. Late replies from the old
source cannot overwrite the new source's controls or levels.

```sh
Build/Products/Release/dolbye-decode --input encoded.wav -o decoded.wav
Build/Products/Release/dolbye-decode --input-pri main_AES1.wav --input-exp main_AES2.wav -o rendered.wav --presentation main --layout 9.1.6
Build/Products/Release/dolbye-decode --input-pri main_AES1.wav --input-exp main_AES2.wav -o stereo.wav --presentation stereo
Build/Products/Release/dolbye-decode --input-pri main_AES1.wav --input-exp main_AES2.wav --play
```

ED2 `all` exports sixteen raw transport signals and a scene sidecar. Main file
rendering defaults to5.1.2; explicit `--layout` selects another implemented speaker
layout. QCMain defaults to9.1.6 independently of the encoded bed. Stereo rendering
and independent Stereo carriage are distinct concepts.

Implemented layout choices reach9.1.6. Full independent ED2MGI/presentation
qualification, generic payload21semantics and proprietary-renderer equivalence
remain open; native round trips and successful builds are not certification.

## Implementation basis

This is an open-source implementation developed against the applicable Dolby E / ED2
white papers and SMPTE specifications. It is independently developed and is not an
official implementation or certification statement.

## License

Copyright ©2026 B00kerLouis.

All first-party code, build configuration and documentation in this
repository are licensed under **GNU LGPL version3 or any later version**
(`LGPL-3.0-or-later`). See [LICENSE](LICENSE) for the LGPL additional permissions
and the incorporated GPLv3 terms. The license texts retain
their original notices. Third-party materials, if separately provided, retain
their own terms and are not relicensed by this statement.

Static linking is supported technically; downstream distributors must satisfy
the applicable LGPL source, notice and relinking requirements. This project does
not grant third-party trademark rights or represent product certification.
