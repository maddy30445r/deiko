import Foundation

/// Turning a pipeline stage's output into something worth reading.
///
/// The orb used to show raw stdout+stderr in a monospace box. What that
/// actually put in front of people: shell instructions for a `.env` they do not
/// have, four hundred characters of the provider's JSON, or a Node stack trace ending
/// in "Fix looksOpaque / SECRET_MARKER in scripts/render-brief.mjs" — an
/// instruction to edit source code, naming a file that is inside the app bundle.
///
/// Every case here was read off the strings the scripts actually print
/// (`scripts/transcribe.mjs`, `scripts/render-brief.mjs`, `scripts/lib/redact.mjs`),
/// not imagined. The raw text is always kept: it is the only thing worth having
/// in a bug report, and the orb shows it behind a disclosure.
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
    ///
    /// Ordered most specific first. The API-key check precedes the auth check
    /// because "no key" and "bad key" are different problems with different
    /// fixes, and only one of them is the user's first five minutes.
    public static func classify(stage: String, output: String) -> PipelineFailure {
        let text = output.lowercased()

        func make(_ kind: Kind, _ message: String, settings: Bool = false) -> PipelineFailure {
            PipelineFailure(kind: kind, message: message, opensSettings: settings, raw: output)
        }

        // Every sentence says what happened to the WORK — "saved", "will
        // finish on its own", "nothing was sent". A failed session must never
        // leave the developer wondering whether 43 seconds of narration
        // evaporated. It never does: the session is on disk before any of
        // these stages run.

        // THE RELAY'S OWN REFUSALS COME FIRST, and they are the only ones here
        // that are not a fault at all.
        //
        // Each of these means the session already fell back to Apple's
        // on-device words and rendered — `transcribe.mjs` treats them as a
        // degraded session rather than a failed one, and the review window says
        // which happened in its own line. They reach this taxonomy only when
        // something ELSE then failed the stage, so the sentence's job is to
        // stop the user chasing a problem they do not have. None of them is a
        // bug report, and none of them is the provider: the user has no
        // relationship with it, and naming a vendor they have never heard of is
        // rate-limiting explains nothing they can act on.
        //
        // Strings from services/relay/quota.mjs and relay.mjs; the mapping they
        // belong to lives in scripts/lib/cloud.mjs and is tested there.
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

        // The provider's own errors arrive as `Groq <status>: <body>`, and
        // reach a user only when they brought their OWN key — so naming the
        // vendor here is correct, and naming it above was not. `sarvam` is
        // still matched because a session recorded before the switch can be
        // re-rendered afterwards, and its cached failure text says Sarvam.
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
        // problem; the specific cause arrives in the cause chain, which does not
        // survive into stderr.
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
        // commonest cause is a quarantined Node runtime — macOS refuses the
        // spawned binary and nothing ever comes back — which is why the fix
        // names the Terminal command rather than describing a timeout.
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
