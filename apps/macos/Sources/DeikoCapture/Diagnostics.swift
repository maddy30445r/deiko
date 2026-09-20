import AppKit
import Foundation
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// DIAGNOSTICS — one paste that answers most of "it didn't work"
//
// Written for a team rollout. Without this, a report is "Deiko broke"; with it,
// the version, the grants and which transcriber would have run arrive in one
// block, and most questions are answered before anybody asks.
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

    /// The most recent classified pipeline failure, remembered so the report
    /// can name it.
    ///
    /// `report(lastFailure:)` has always been able to print this, and nothing
    /// ever passed it: the block a user copies out of Settings described their
    /// whole install and omitted the one thing they were writing in about.
    /// Storing it here rather than threading it through means every caller
    /// gets it, including the ones that have no idea a session just failed.
    static var lastFailure: PipelineFailure?

    /// The block the Settings button copies.
    static func report(lastFailure: PipelineFailure? = nil) -> String {
        let lastFailure = lastFailure ?? Self.lastFailure
        var lines: [String] = []

        lines.append("Deiko \(DeikoVersion.current) (build \(DeikoVersion.build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("installed at \(Bundle.main.bundleURL.path)")
        lines.append("")

        lines.append("permissions")
        for permission in Permission.allCases {
            lines.append("  \(permission.isGranted ? "✓" : "✗") \(permission.rawValue)")
        }
        // TCC answers about the RESPONSIBLE process, and for a binary invoked
        // from a shell that is the terminal — which has never asked for Speech
        // Recognition, so it reads as denied however thoroughly Deiko.app was
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
            lines.append("   terminal, not to Deiko.app. Settings reports them correctly.)")
        }
        lines.append("")

        lines.append("transcription: \(transcriberDescription())")
        lines.append("narration: \(Narration.selected.rawValue) · offline recogniser: \(SpeechLocale.selected)")
        lines.append("relay configured: \(Credentials.relayURL ?? "none — this build has no relay")")
        // ALL FOUR STAMPED VALUES, because the one that was wrong was the one
        // nobody printed. Each decides whether an entire affordance exists —
        // the update check, the Get Pro button, "Send feedback…" — and a build
        // that silently lost its relay transcribed a day of sessions on-device
        // while the brief said nothing was degraded. This is the block a user
        // pastes; it should be able to answer "what was this app built with".
        lines.append("site configured: \(Credentials.siteURL?.absoluteString ?? "none — no update check")")
        lines.append("buy configured: \(Credentials.buyURL?.absoluteString ?? "none — Pro not purchasable")")
        lines.append("support configured: \(Credentials.supportEmail ?? "none — no feedback affordance")")
        // WHICH SUBJECT THE QUOTA IS COUNTED AGAINST. A PREFIX ONLY, matching
        // what the relay logs — enough to line a bug report up with a row in
        // the usage table, and not the whole bearer, which a diagnostics blob
        // gets pasted into public issue trackers.
        lines.append("plan: \(License.isPro ? "Pro" : "Free") · subject \(License.bearerToken().prefix(12))…")
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

        // THE OTHER HALF OF "IT DIDN'T WORK". `lastFailure` covers the brief
        // pipeline; this covers the throw, which had no record of any kind —
        // the refusal path threw a sentence into the orb and wrote nothing.
        // A slug, never that sentence: see `FlingReport.diagnosticLine`.
        if let fling = Handoff.lastFlingLine {
            lines.append("last fling: \(fling)")
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
        // `willUse`, NOT `exists` — they agree today, and asking the question
        // the pipeline asks is what keeps this line honest if they ever diverge
        // again. The name was `SARVAM_API_KEY` until Whisper replaced Sarvam,
        // and since that name left `Credentials.names` this check could never
        // fire at all: a machine using its own Groq key was reported as using
        // the relay for as long as that lasted.
        if Credentials.willUse("GROQ_API_KEY") { return "your own Groq key" }
        if let relay = Credentials.relayURL { return "Deiko relay (\(relay))" }
        return "on-device only — lower accuracy, no upload"
    }

    /// How many sessions exist. A number, never a name.
    ///
    /// `Sessions.list` rather than a directory count of its own: that version
    /// counted every non-dot entry, so anything a person had dropped in the
    /// folder inflated the one number in this report that says whether the app
    /// has ever successfully recorded anything.
    ///
    /// Still the DEFAULT root, which is what a shipped app always uses. A run
    /// started with `--out` reports 0 here — a development path, and not worth
    /// threading a root through a type that has no other reason to know one.
    private static func sessionCount() -> Int {
        Sessions.list().count
    }

    /// A bug report with the answers already in it.
    ///
    /// Nil when this build carries no address; callers hide their buttons then.
    /// The crash alert has always offered to copy diagnostics without ever
    /// saying where they should go, and an item that opened an empty compose
    /// window would be that same dead end wearing a button.
    ///
    /// The body is `report()`, which by construction carries nothing from
    /// inside a session — no narration, no window titles, no OCR, no session
    /// ids. See this file's header for why that is a property of how the code
    /// is arranged rather than a rule somebody has to remember.
    static func feedbackURL() -> URL? {
        guard let address = Credentials.supportEmail else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Deiko \(DeikoVersion.current) — feedback"),
            URLQueryItem(
                name: "body",
                value: "\n\n— what happened —\n\n\n"
                    + "— diagnostics, so this can be answered —\n\n" + report()
            ),
        ]
        return components.url
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
