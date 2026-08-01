import Foundation

/// Turning a pipeline stage's output into something worth reading.
///
/// The orb used to show raw stdout+stderr in a monospace box. What that
/// actually put in front of people: shell instructions for a `.env` they do not
/// have, four hundred characters of Sarvam's JSON, or a Node stack trace ending
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
        /// No Sarvam key anywhere — the commonest first-run failure.
        case noAPIKey
        /// The key exists and the service rejected it.
        case authRejected
        /// Rate limit or quota.
        case quotaExhausted
        /// DNS, no route, TLS — the machine could not reach the service.
        case offline
        /// The mic delivered nothing, or nothing that was speech.
        case noSpeech
        /// The renderer refused to write because a credential survived redaction.
        case redactionRefused
        /// Node itself is missing.
        case noRuntime
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

        if text.contains("sarvam_api_key is not set") || text.contains("sarvam_api_key is missing") {
            return make(
                .noAPIKey,
                "Fovea needs a Sarvam API key to turn your narration into text. Add one in Settings.",
                settings: true
            )
        }

        // Sarvam's own errors arrive as `Sarvam <status>: <body>`.
        if text.contains("sarvam 401") || text.contains("sarvam 403") {
            return make(
                .authRejected,
                "Sarvam rejected the API key. Check it in Settings — it may have been revoked or copied incompletely.",
                settings: true
            )
        }
        if text.contains("sarvam 429") || text.contains("quota") || text.contains("rate limit") {
            return make(
                .quotaExhausted,
                "Sarvam is rate-limiting or out of quota. Wait a moment and send again, or check your plan."
            )
        }

        // `fetch failed` is Node's undici wrapper for every network-layer
        // problem; the specific cause arrives in the cause chain, which does not
        // survive into stderr.
        if text.contains("fetch failed") || text.contains("enotfound") || text.contains("econnrefused")
            || text.contains("network is unreachable") || text.contains("etimedout") {
            return make(
                .offline,
                "Could not reach Sarvam. Check your internet connection and send again."
            )
        }

        if text.contains("no words transcribed") || text.contains("no holds with usable audio")
            || text.contains("mic never delivered") {
            return make(
                .noSpeech,
                "Fovea did not hear any speech in this session. Check that the right microphone is selected in System Settings → Sound."
            )
        }

        if text.contains("refusing to write") || text.contains("secret_marker") {
            return make(
                .redactionRefused,
                "Fovea found something credential-shaped in the captured text and stopped rather than send it. The session is on disk; nothing was sent."
            )
        }

        if text.contains("could not find node") || text.contains("node: command not found") {
            return make(
                .noRuntime,
                "Fovea could not find the Node runtime it needs to process this session."
            )
        }

        return make(.unknown, "\(stage) failed. The details below are worth sending in a bug report.")
    }
}
