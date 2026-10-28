// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import DolbyEDecoder

configureCLIDiagnostics()

if CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().contains("--help") {
    print("""
    Dolby E: dolbye-decode --input INPUT -o OUTPUT
    ED2:     dolbye-decode --input-pri AES1 --input-exp AES2 -o OUTPUT
      -f pcm|mxf-op1a|mxf-opatom -p 5.1+2|7.1-scrn
      --probe     validate the first Dolby E frame and report program/AC-3 metadata
      --play      open the native QC player (input is optional)
      --presentation all|main|stereo    E: 8/main/2ch; ED2: 16 signals + JSONL / 5.1.2 / Stereo
      --input-pri AES1 --input-exp AES2 ED2 primary topology stream and expansion stream
      --input INPUT                   Dolby E or a multiplexed ED2 WAVE/MXF carrier
      --secondary-input AES2           legacy companion option for --input
      --layout auto|2.0|5.1|7.1|7.1-scrn|5.1.2|5.1.4|7.1.2|7.1.4|7.1.6|9.1.6
                   playback layout, or explicit ED2 --presentation main file rendering
      --mute      open playback with the monitor muted
      --monitor direct|downmix|meters  listener routing (default direct)

    Native Swift decoding includes section CRC validation and recoverable BWF/RF64 PCM output.
    """)
    exit(0)
}

do {
    let options = try CommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    if options.play {
        let layout = options.playbackLayout == "auto" ? nil : DolbyEPlaybackLayout(rawValue: options.playbackLayout)
        guard options.playbackLayout == "auto" || layout != nil else { throw DolbyEError.invalidArgument("unknown playback layout") }
        runDolbyEPlayer(input: options.input, muted: options.muted, layout: layout,
            selection: options.decodeSelection, secondaryURL: options.secondaryInput, monitorMode: DolbyEMonitorMode(rawValue: options.monitorMode)!)
    } else if options.probe {
        guard let input = options.input else { throw DolbyEError.invalidArgument("--input or --input-pri/--input-exp is required") }
        let first = try DolbyECarrierProbe(url: input)
        if options.secondaryInput != nil || (first.encodeVision == .ed2 && (first.carrier.channelCount == 4
            || DolbyED2CompanionFile.existingURL(for: input) != nil)) {
            try printJSON(DolbyED2CarrierProbe(url: input, secondaryURL: options.secondaryInput))
        } else { try printJSON(first) }
    } else {
        guard let input = options.input else { throw DolbyEError.invalidArgument("--input or --input-pri/--input-exp is required") }
        guard let output = options.output else { throw DolbyEError.invalidArgument("-o / --output is required") }
        let request = DolbyERequest(inputURL: input, outputURL: output, format: options.format,
                                   program: options.program, frameRate: options.rate, decodeSelection: options.decodeSelection,
                                   secondaryInputURL: options.secondaryInput,
                                   decodeLayout: options.playbackLayout == "auto" ? nil : DolbyEPlaybackLayout(rawValue: options.playbackLayout))
        // File decoding owns asynchronous workers; playback enters AppKit
        // synchronously above so its event loop stays on the process main thread.
        Task {
            do {
                try await printJSON(DolbyEDecoding.decode(request))
                exit(0)
            } catch {
                reportFailure(error)
                exit(1)
            }
        }
        dispatchMain()
    }
} catch {
    reportFailure(error)
    exit(1)
}
