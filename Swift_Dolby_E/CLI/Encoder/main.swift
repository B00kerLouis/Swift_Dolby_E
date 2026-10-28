// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import DolbyEEncoder

configureCLIDiagnostics()
let encodingProgress = DolbyECLIEncodingProgress()

if CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().contains("--help") {
    print("""
    dolbye-encode -i INPUT -o OUTPUT -f pcm|mxf-op1a|mxf-opatom -p 5.1+2|7.1-scrn
      --encode-vision e|ed2             codec generation (default e)
        ED2 WAV: -o OUTPUT.wav writes OUTPUT_AES1.wav (pri) and OUTPUT_AES2.wav (exp).
        ED2 OP-Atom uses the same _AES1/_AES2 naming; OP-1A keeps one output file.
      --dialogue-source none|bed-c      extract bed C into one ED2 Dialogue Object
      --frame-rate 24000/1001|24|25|30000/1001|30   (default: master rate; PCM WAVE 25)
      --input-layout auto|5.1|5.1.2|7.1|7.1-scrn|5.1+2
      --probe     identify input container; no output file is created
      --plan      report processing requirements as JSON
      --progam    accepted alias for --program
      --metadata FILE.json             AC-3 program metadata array (see --plan)
        ED2: 1 shared, 8 repeated-per-AES, or 16 independent signal records.
      --dialnorm -24                   dialogue level, -31...-1
      --ac3-bitrate 384,192             downstream AC-3 target rates in kbps
        ED2 global options use one shared mono setting (one bitrate value).
      --rf-profile "film standard"     film standard|film light|music light|music standard
      --downmix-mode ltrt|loro          generated Stereo matrix (default ltrt)
      --line-profile "film standard"   none|film standard|film light|music standard|music light|speech
      --json                          print the final encoding result as JSON
      --workers 0                     0 bounded automatic,1 serial,2...16 worker budget
      --loudness off|measure|normalize programme-relative measurement/correction (default off)
      --loudness-target -23            target LUFS; E programmes measured separately
      --loudness-ceiling -2.5          maximum programme true peak dBTP
      --loudness-layout 5.1            ED2 Main measurement layout (default 5.1)
      --loudness-version 0|1           legacy0basic or standard1extended ED2 payload1
      --loudness-tolerance 0.2         offline target tolerance LU

    Native Swift encoding: PCM WAVE / ADM BWF / DAMF / IAB, recoverable BWF/RF64 or MXF output.
    """)
    exit(0)
}

do {
    let options = try CommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    guard let input = options.input else { throw DolbyEError.invalidArgument("-i / --input is required") }
    if options.probe {
        try printJSON(DolbyEMasterProbe.inspect(input))
    } else {
        let output = options.output ?? input.deletingLastPathComponent().appendingPathComponent("planned-output.wav")
        let request = DolbyERequest(inputURL: input, outputURL: output, format: options.format,
                                   program: options.program, frameRate: options.rate, inputLayout: options.inputLayout,
                                   ac3Metadata: options.metadata, downmixMode: options.downmixMode,
                                   encodeVision: options.encodeVision, dialogueSource: options.dialogueSource,maximumParallelism:options.encoderWorkers,loudness:options.loudness)
        if options.plan {
            try printJSON(DolbyEEncoding.prepare(request))
        } else {
            let result = try await DolbyEEncoding.encode(request) { encodingProgress.update($0) }
            if options.jsonResult { try printJSON(result) }
        }
    }
} catch {
    encodingProgress.endLine()
    reportFailure(error)
    exit(1)
}
