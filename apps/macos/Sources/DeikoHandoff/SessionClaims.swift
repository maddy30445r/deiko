import Foundation

/// The two claims the product is trusted on: what left this Mac (`trustLine`)
/// and why a transcript came out worse than usual (`degradedSentence`). A wrong
/// sentence here is a false statement about somebody's data, so both are pure
/// functions over primitives, kept in this library rather than beside
/// `ReviewWindow` so they can be tested (`DeikoCapture` cannot be linked into a
/// test binary).
public enum SessionClaims {

    /// What actually left the machine for one session, each item named:
    /// narration audio to whoever transcribed it, narration text to whoever
    /// wrote the summary, and what was sent to the relay for filing.
    ///
    /// - Parameters:
    ///   - transcriber: `"deiko"`, `"on-device"`, a `"groq:…"` variant when the
    ///     user brought their own key, `"sarvam"` for an older session, or nil
    ///     when it was not recorded.
    ///   - degradedReason: why the cloud path fell back, if it did.
    ///   - seconds: the span of the recognised words. Reported with a `~`
    ///     because it is a shade shorter than the recording itself.
    ///   - hasSummary: whether a summary was actually produced; a skipped or
    ///     failed request sent nothing.
    ///   - ownGroqKey: whether that summary went to the user's own Groq key
    ///     rather than through Deiko.
    ///   - uploadedChunks: how many requests actually reached the network this
    ///     run. Nil for a brief rendered before this was recorded.
    ///   - filedSummary: whether the filing request carried the summary. Not
    ///     `hasSummary`: a summary can land on the card after the request left
    ///     without one. `classify.mjs` records it in the same marker.
    ///   - filed: whether the classifier's request went out to the relay for
    ///     this session: true once the words left, whether or not an answer
    ///     came back, and for own-key users too, since sorting runs through
    ///     Deiko regardless of who transcribed. Read from the marker
    ///     `classify.mjs` writes before its POST, not from whether
    ///     `context.json` was placed, because a failed request still sent the
    ///     narration and window titles. Never true with "Sort briefs into
    ///     tasks" off.
    public static func trustLine(
        transcriber: String?,
        degradedReason: String?,
        seconds: Int,
        uploadedChunks: Int?,
        hasSummary: Bool,
        ownGroqKey: Bool,
        filed: Bool,
        filedSummary: Bool
    ) -> String {
        var parts: [String] = []

        // Nothing was sent if nothing was sent: a relay that could not be
        // reached at all never opens a socket, so `uploadedChunks` is 0 while
        // `transcriber` still reads "deiko". Nil is an older brief without the
        // counter; there the transcriber name is the best evidence.
        let reachedTheNetwork = uploadedChunks == nil || (uploadedChunks ?? 0) > 0

        // A refusal does not mean nothing was sent. `relayTranscriber`
        // short-circuits only once already refused, so the first chunk of a
        // spent trial is uploaded in full and the relay meters the body after
        // receiving it (`services/relay/src/relay.mjs`). Say that part was
        // sent and none transcribed; never claim a clean session or quote a
        // duration that never left.
        let refusedOutright = ["trial", "monthly", "ceiling", "rejected"]
            .contains(degradedReason ?? "")
        switch transcriber {
        case _ where !reachedTheNetwork:
            break
        case let name where name?.hasPrefix("groq") == true:
            parts.append("~\(seconds)s of audio to Groq, with your key")
        case "sarvam":
            // Re-rendering an older session must still describe what left.
            parts.append("~\(seconds)s of audio to Sarvam, with your key")
        case "deiko" where refusedOutright:
            parts.append("part of your audio to Deiko's transcription, which refused it")
        case "deiko":
            parts.append("~\(seconds)s of audio to Deiko's transcription")
        default:
            break
        }

        if hasSummary {
            parts.append(ownGroqKey
                ? "your narration to Groq, with your key"
                : "your narration, for the summary")
        }

        // Sorting is not transcription. Own-key users keep their audio off
        // Deiko's servers, but a brief the classifier attempted to place still
        // sent what you said, window titles and notes on earlier work through
        // the relay, so the line must say so. "Its summary" only when the
        // request carried one.
        if filed {
            parts.append(filedSummary
                ? "what you said, its summary, your window titles and notes on earlier work, to Deiko to file it"
                : "what you said, your window titles and notes on earlier work, to Deiko to file it")
        }

        return parts.isEmpty
            ? "Nothing left this Mac — everything here was made on it."
            : "Left this Mac: " + parts.joined(separator: " · ")
    }

    /// Why this transcript is worse than a clean one, in words that carry the
    /// answer rather than the diagnosis. Each reason has a different answer: a
    /// spent trial wants an upgrade path, a spent month a reset date, the
    /// service ceiling "this is not about you", an unreachable relay "try
    /// later". `timing` is not a fallback to the Mac at all: the on-device clock
    /// failed and the cloud text survived.
    ///
    /// `resetSentence` is passed in so this stays a pure function and the
    /// caller owns the calendar.
    public static func degradedSentence(
        _ reason: String?, degraded: Bool, resetSentence: String
    ) -> String? {
        switch reason {
        case "trial":
            return "Your free 30 minutes are used up — this was transcribed on your Mac, "
                + "so accuracy may be lower."
        case "monthly":
            return "This month's Pro hours are used up — transcribed on your Mac. "
                + "\(resetSentence)."
        case "ceiling":
            return "Deiko's transcription is at its daily limit — nothing is wrong with "
                + "your plan. This was transcribed on your Mac."
        case "rejected":
            // The one degradation whose fix is a text field: a malformed or
            // revoked bearer cannot heal by retrying, and only the user can
            // change it.
            return "Deiko didn't accept this install's licence key — this was transcribed "
                + "on your Mac. Check the key in Settings."
        case "on-device":
            // The one degradation that is a build mistake rather than a plan:
            // the app was assembled with no DeikoRelayURL, so
            // `selectTranscriber` never had a relay to call, and only whoever
            // ran `make` can fix it. Kept distinct from "trial", whose answer
            // is a purchase rather than a reinstall.
            return "This build has no transcription relay, so every word came from your Mac "
                + "— accuracy is lower. Settings → Copy diagnostics shows what was stamped."
        case "unavailable":
            // "Some of this": unlike the reasons above, this fires for a single
            // failed chunk as well as for a dead relay.
            return "Some of this couldn't reach Deiko's transcription — those parts were "
                + "transcribed on your Mac, so accuracy may be lower."
        case "timing":
            return "Word timings were estimated for part of this — what you said is intact, "
                + "but what you pointed at may bind loosely."
        default:
            // No reason recorded (an older session), but it was still degraded.
            return degraded
                ? "Some of this was transcribed on your Mac rather than in the cloud — accuracy may be lower."
                : nil
        }
    }
}
