import Foundation

/// Turns a pipeline stage's output into a short, actionable message. Every
/// case matches strings the scripts actually print
/// (`packages/core/src/transcribe.mjs`, `render-brief.mjs` and
/// `lib/redact.mjs`). The raw text is always kept for bug reports; the orb
/// shows it behind a disclosure.
///
/// Pure string work, so the whole taxonomy is testable without a pipeline.
public struct PipelineFailure: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// The key exists and the service rejected it.
        case authRejected
        /// A cap is spent: the caller's own, or the service's for the day.
        case quotaExhausted
        /// DNS, no route, TLS — the machine could not reach the service.
        case offline
        /// The mic delivered nothing, or nothing that was speech.
        case noSpeech
        /// The renderer refused to write because a credential survived redaction.
        case redactionRefused
        /// Node itself is missing.
        case noRuntime
        /// The stage never finished and Deiko stopped waiting for it.
        case timedOut
        /// Anything unclassified.
        case unknown
    }

    public let kind: Kind
    /// One sentence, and it names the fix rather than the diagnosis.
    public let message: String
    /// Whether the fix lives in Settings, so the caller can offer to open it.
    public let opensSettings: Bool
    /// The original output, for a bug report.
    public let raw: String

    public init(kind: Kind, message: String, opensSettings: Bool, raw: String) {
        self.kind = kind
        self.message = message
        self.opensSettings = opensSettings
        self.raw = raw
    }

    /// Classify a stage failure.
    /// Ordered most specific first.
    public static func classify(stage: String, output: String) -> PipelineFailure {
        let text = output.lowercased()

        func make(_ kind: Kind, _ message: String, settings: Bool = false) -> PipelineFailure {
            PipelineFailure(kind: kind, message: message, opensSettings: settings, raw: output)
        }

        // Every sentence says what happened to the work ("saved", "will finish
        // on its own", "nothing was sent"), so a failed session never leaves
        // the developer wondering whether the narration evaporated. The session
        // is on disk before any of these stages run.

        // The relay's own refusals come first, and they are not faults: each
        // means the session already fell back to Apple's on-device words and
        // rendered (`transcribe.mjs` treats them as degraded, not failed). They
        // reach here only when something else then failed the stage, so the
        // sentence must stop the user chasing a problem they do not have, and
        // must not name the provider, which they have no relationship with.
        //
        // Strings from services/relay/src/quota.mjs and relay.mjs; the mapping
        // lives in packages/core/src/lib/cloud.mjs.
        if text.contains("fair-use limit") {
            return make(
                .quotaExhausted,
                "This month's Pro hours are used up, so this session was transcribed on "
                    + "your Mac — accuracy may be lower. Your allowance resets on the 1st."
            )
        }
        if text.contains("daily ceiling") {
            return make(
                .quotaExhausted,
                "Deiko's transcription is at its daily limit — nothing is wrong with your "
                    + "plan. This session was transcribed on your Mac and is saved."
            )
        }
        if text.contains("usage service unavailable") {
            return make(
                .offline,
                "Deiko's transcription service is briefly unavailable. The session was "
                    + "transcribed on your Mac and is saved — try again in a few minutes."
            )
        }

        // Provider errors arrive as `Groq <status>: <body>` and reach a user
        // only with their own key, so naming the vendor is correct here and not
        // above. `sarvam` is still matched because re-rendering an older
        // session replays its cached failure text.
        if text.contains("groq 401") || text.contains("groq 403")
            || text.contains("sarvam 401") || text.contains("sarvam 403") {
            return make(
                .authRejected,
                "The transcription service rejected your key — it may have expired or been "
                    + "copied incompletely. Paste a fresh one in Settings; the session is saved.",
                settings: true
            )
        }
        if text.contains("groq 429") || text.contains("sarvam 429")
            || text.contains("quota") || text.contains("rate limit") {
            return make(
                .quotaExhausted,
                "The transcription service is rate-limiting. Nothing is lost — "
                    + "wait a moment and try again."
            )
        }

        // `fetch failed` is Node's undici wrapper for every network-layer
        // problem; the specific cause does not survive into stderr.
        if text.contains("fetch failed") || text.contains("enotfound") || text.contains("econnrefused")
            || text.contains("network is unreachable") || text.contains("etimedout") {
            return make(
                .offline,
                "You're offline — check your internet connection. "
                    + "The session is saved and will finish when you're back."
            )
        }

        if text.contains("no words transcribed") || text.contains("no holds with usable audio")
            || text.contains("mic never delivered") {
            return make(
                .noSpeech,
                "No speech heard — there's nothing to brief. If you were talking, "
                    + "check the right microphone is selected in System Settings → Sound."
            )
        }

        if text.contains("refusing to write") || text.contains("secret_marker") {
            return make(
                .redactionRefused,
                "Deiko found something credential-shaped in the captured text and stopped rather than send it. The session is on disk; nothing was sent."
            )
        }

        if text.contains("could not find node") || text.contains("node: command not found") {
            return make(
                .noRuntime,
                "Deiko could not find the Node runtime it needs to process this session. The session is saved."
            )
        }

        // BriefPipeline's watchdog writes this when a stage never finishes. The
        // commonest cause is a quarantined Node runtime (macOS refuses the
        // spawned binary), so the fix names the Terminal command rather than
        // describing a timeout.
        if text.contains("timed out after") {
            return make(
                .timedOut,
                "That step took too long and Deiko stopped waiting. The session is saved on disk. "
                    + "If this keeps happening, run: xattr -dr com.apple.quarantine /Applications/Deiko.app"
            )
        }

        return make(
            .unknown,
            "\(stage) failed. The session is saved — the details below are worth sending in a bug report."
        )
    }
}
