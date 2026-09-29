import AppKit
import Foundation
import DeikoHandoff

/// One paste that answers most of "it didn't work": version, permissions, transcriber and build-stamped values.
///
/// It must never contain anything from inside a session: no narration, window titles, accessibility text,
/// OCR, crop paths or session ids. People paste this into group chats. A session count is fine; a session
/// name is not, because ids are timestamps and timestamps record when somebody was working.
@MainActor
enum Diagnostics {

    /// The most recent classified pipeline failure, remembered so `report` can name it.
    /// Stored here rather than threaded through so every caller gets it.
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
        // TCC attributes permissions to the responsible process, which for a binary run from a shell is
        // the terminal. It has never asked for Speech Recognition, so that reads as denied however
        // thoroughly Deiko.app was granted it. Any of the three streams counts, not stdout alone, so the
        // caveat survives `| pbcopy`.
        if isatty(STDOUT_FILENO) == 1 || isatty(STDERR_FILENO) == 1 || isatty(STDIN_FILENO) == 1 {
            lines.append("  (run from a terminal — these are attributed to your")
            lines.append("   terminal, not to Deiko.app. Settings reports them correctly.)")
        }
        lines.append("")

        lines.append("transcription: \(transcriberDescription())")
        lines.append("narration: \(Narration.selected.rawValue) · offline recogniser: \(SpeechLocale.selected)")
        lines.append("relay configured: \(Credentials.relayURL ?? "none — this build has no relay")")
        // All four stamped values are printed: each decides whether a whole affordance exists (update
        // check, Pro button, feedback), and this block answers "what was this app built with".
        lines.append("site configured: \(Credentials.siteURL?.absoluteString ?? "none — no update check")")
        lines.append("buy configured: \(Credentials.buyURL?.absoluteString ?? "none — Pro not purchasable")")
        lines.append("support configured: \(Credentials.supportEmail ?? "none — no feedback affordance")")
        // A prefix only, matching what the relay logs: enough to line a report up with the usage table,
        // not the whole bearer.
        lines.append("plan: \(License.isPro ? "Pro" : "Free") · subject \(License.bearerToken().prefix(12))…")
        lines.append("runtime: \(NodeRuntime.resolve()?.path ?? "NOT FOUND")")
        lines.append("layout: \(Layout.resolve().map(String.init(describing:)) ?? "NOT FOUND")")
        lines.append("sessions recorded: \(sessionCount())")
        lines.append("log: \(Paths.launchLog)")

        if let lastFailure {
            lines.append("")
            // The classified sentence, never `raw`: provider errors can echo the request back, and the
            // request is the audio.
            lines.append("last failure: \(lastFailure.kind) — \(lastFailure.message)")
        }

        // The throw path's record: a slug, never the refusal sentence (see `FlingReport.diagnosticLine`).
        if let fling = Handoff.lastFlingLine {
            lines.append("last fling: \(fling)")
        }

        return lines.joined(separator: "\n")
    }

    /// Which transcriber a session would use right now: the most useful line when the words came out wrong.
    ///
    /// Reported alongside the configured relay, not instead of it: a personal key outranks the relay, so
    /// this line alone cannot show whether a build was stamped with a relay URL.
    private static func transcriberDescription() -> String {
        // `willUse`, not `exists`: it asks the question the pipeline asks, so this line stays honest if
        // the two diverge.
        if Credentials.willUse("GROQ_API_KEY") { return "your own Groq key" }
        if let relay = Credentials.relayURL { return "Deiko relay (\(relay))" }
        return "on-device only — lower accuracy, no upload"
    }

    /// How many sessions exist: a number, never a name.
    ///
    /// Uses `Sessions.list` so stray files in the folder do not inflate the count. Counts the default
    /// root only, so a run started with `--out` reports 0.
    private static func sessionCount() -> Int {
        Sessions.list().count
    }

    /// A bug report with the answers already in it. Nil when this build carries no address; callers
    /// hide their buttons then.
    ///
    /// The body is `report()`, which carries nothing from inside a session (see the type's doc comment).
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
