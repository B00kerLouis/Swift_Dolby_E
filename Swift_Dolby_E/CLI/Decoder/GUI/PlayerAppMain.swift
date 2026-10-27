// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import AppKit
import DolbyEDecoder

/// A synchronous AppKit entry point keeps the desktop event loop independent
/// of the command-line file processing task and its lifecycle.
@main
private struct DolbyEPlayerMain {
    @MainActor static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
            if !arguments.contains("--play") { arguments.insert("--play", at: 0) }
            let options = try CommandLineOptions(arguments: arguments)
            let layout = options.playbackLayout == "auto" ? nil : DolbyEPlaybackLayout(rawValue: options.playbackLayout)
            guard options.playbackLayout == "auto" || layout != nil else {
                throw DolbyEError.invalidArgument("unknown playback layout")
            }
            runDolbyEPlayer(input: options.input, muted: options.muted, layout: layout, selection: options.decodeSelection,
                secondaryURL: options.secondaryInput, monitorMode: DolbyEMonitorMode(rawValue: options.monitorMode)!)
        } catch {
            reportFailure(error)
            let alert = NSAlert()
            alert.messageText = "Dolby E QC"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
