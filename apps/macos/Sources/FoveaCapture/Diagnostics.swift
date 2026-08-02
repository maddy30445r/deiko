import AppKit
import Foundation
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// DIAGNOSTICS — one paste that answers most of "it didn't work"
//
// Written for a team rollout. Without this, a report is "Fovea broke"; with it,
// the version, the grants, the connectors and which transcriber would have run
// arrive in one block, and most questions are answered before anybody asks.
//
// WHAT THIS MUST NEVER CONTAIN, and the reason the code is arranged so that
// adding it would be a deliberate act rather than an oversight: nothing from
// inside a session. No narration, no window titles, no accessibility text, no
// OCR, no crop paths, no session ids. People paste this into a group chat.
//
// A count of sessions is fine — it says whether the app has ever worked. The
// name of one is not, because session ids are timestamps and timestamps are a
// record of when somebody was working.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum Diagnostics {

    /// The block the Settings button copies.
    static func report(lastFailure: PipelineFailure? = nil) -> String {
        var lines: [String] = []

        lines.append("Fovea \(FoveaVersion.current) (build \(FoveaVersion.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("installed at \(Bundle.main.bundleURL.path)")
        lines.append("")

        lines.append("permissions")
        for permission in Permission.allCases {
            lines.append("  \(permission.isGranted ? "✓" : "✗") \(permission.rawValue)")
        }
        // TCC answers about the RESPONSIBLE process, and for a binary invoked
        // from a shell that is the terminal — which has never asked for Speech
        // Recognition, so it reads as denied however thoroughly Fovea.app was
        // granted it. Saying so beats sending somebody to hunt a permission
        // they already have.
        //
        // ANY of the three streams, not stdout alone. Gating on stdout meant
        // the caveat vanished the moment the report was piped — and piping is
        // how it is actually used: `| grep`, `| pbcopy` to paste into a chat.
        // So the warning disappeared in precisely the case that produces a bug
        // report, and what got pasted was a bare "✗ Speech Recognition" for a
        // permission the app holds. stderr survives a pipe on stdout; the app
        // launched from Finder, and the Settings button that calls this
        // in-process, have a TTY on none of them.
        if isatty(STDOUT_FILENO) == 1 || isatty(STDERR_FILENO) == 1 || isatty(STDIN_FILENO) == 1 {
            lines.append("  (run from a terminal — these are attributed to your")
            lines.append("   terminal, not to Fovea.app. Settings reports them correctly.)")
        }
        lines.append("")

        lines.append("coding agents")
        for connector in Connectors.all {
            let state =
                connector.isConnected
                ? "connected" : (connector.isInstalled ? "installed, not connected" : "not found")
            lines.append("  \(connector.name): \(state)")
        }
        lines.append("")

        lines.append("transcription: \(transcriberDescription())")
        lines.append("relay configured: \(Credentials.relayURL ?? "none — this build has no relay")")
        lines.append("runtime: \(NodeRuntime.resolve()?.path ?? "NOT FOUND")")
        lines.append("layout: \(Layout.resolve().map(String.init(describing:)) ?? "NOT FOUND")")
        lines.append("sessions recorded: \(sessionCount())")
        lines.append("log: \(Paths.launchLog)")

        if let lastFailure {
            lines.append("")
            // The classified sentence, never `raw` — provider errors have been
            // known to echo the request back, and the request is the audio.
            lines.append("last failure: \(lastFailure.kind) — \(lastFailure.message)")
        }

        return lines.joined(separator: "\n")
    }

    /// Which transcriber a session would use right now — the single most
    /// useful line when somebody says the words came out wrong.
    ///
    /// Reported ALONGSIDE the configured relay, never instead of it. This line
    /// answers "what will happen", and a personal Sarvam key outranks the relay,
    /// so on a machine that has one it says the same thing whether the build was
    /// given a relay or not. That made it useless for the question it kept being
    /// used for — did `make release RELAY_URL=…` actually stamp the URL — and a
    /// check that cannot fail is worse than no check, because it is trusted.
    private static func transcriberDescription() -> String {
        if Credentials.exists("SARVAM_API_KEY") { return "your own Sarvam key" }
        if let relay = Credentials.relayURL { return "Fovea relay (\(relay))" }
        return "on-device only — lower accuracy, no upload"
    }

    /// How many sessions exist. A number, never a name.
    private static func sessionCount() -> Int {
        let root = "\(NSHomeDirectory())/Documents/Fovea"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.filter { !$0.hasPrefix(".") }.count
    }

    /// Copy, and reveal the log — a report and the file that backs it up.
    static func copyToPasteboard(lastFailure: PipelineFailure? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report(lastFailure: lastFailure), forType: .string)
    }

    static func revealLog() {
        let url = URL(fileURLWithPath: Paths.launchLog)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
