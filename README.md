<!-- Copyright © 2026 B00kerLouis. -->
<!-- SPDX-License-Identifier: LGPL-3.0-or-later -->
# Swift_Dolby_E

Native Swift 6 Dolby E / ED2 encoder, decoder and QC player for macOS 14+.
The Xcode project builds two self-contained static frameworks, two command-line
programs and a native QC application. Production products use system frameworks;
no external codec executable or library is required.

## Build

Use Xcode 26.3 (17C529), Swift language mode 6, and the macOS SDK included with it.

```sh
xcodebuild -project Swift_Dolby_E.xcodeproj -scheme DolbyEEncoderCLI -configuration Release -derivedDataPath Build build
xcodebuild -project Swift_Dolby_E.xcodeproj -scheme DolbyEDecoderCLI -configuration Release -derivedDataPath Build build
xcodebuild -project Swift_Dolby_E.xcodeproj -scheme DolbyEPlayer -configuration Release -derivedDataPath Build build
```

Release builds include arm64 and x86_64. Products are in `Build/Products/Release/`:
`DolbyEEncoder.framework`, `DolbyEDecoder.framework`, `dolbye-encode`,
`dolbye-decode`, and `Dolby E QC.app`. Each framework contains its own shared DSP
and I/O implementation and can be linked independently.

## Encoding

```sh
Build/Products/Release/dolbye-encode -i master.mxf -o main.wav --encode-vision e -p 5.1+2 --downmix-mode loro
Build/Products/Release/dolbye-encode -i master.atmos -o main.AES1.wav --encode-vision ed2 --dialogue-source none
Build/Products/Release/dolbye-encode -i master.atmos -o measured.AES1.wav --encode-vision ed2 --loudness measure
Build/Products/Release/dolbye-encode -i master.atmos -o normalized.AES1.wav --encode-vision ed2 --loudness normalize
```

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

```sh
Build/Products/Release/dolbye-decode --input encoded.wav -o decoded.wav
Build/Products/Release/dolbye-decode --input-pri main.AES1.wav --input-exp main.AES2.wav -o rendered.wav --presentation main --layout 9.1.6
Build/Products/Release/dolbye-decode --input-pri main.AES1.wav --input-exp main.AES2.wav -o stereo.wav --presentation stereo
Build/Products/Release/dolbye-decode --input-pri main.AES1.wav --input-exp main.AES2.wav --play
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
