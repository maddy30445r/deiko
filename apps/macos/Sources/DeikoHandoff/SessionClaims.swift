import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE TWO SENTENCES THE PRODUCT IS TRUSTED ON
//
// One says what left this Mac. The other says why a transcript came out worse
// than usual. Both are claims a user is invited to check, and the first is the
// app's only answer to the question the whole privacy posture rests on —
// until it existed, "did my screen go anywhere" was answerable only by reading
// the source.
//
// HERE, NOT IN `ReviewWindow`, and the reason is the rule `Update.swift` writes
// down: `DeikoCapture` cannot be linked into a test binary, because
// `main.swift` is top-level code that would run the app. That comment allows
// one exception — a decision whose "worst failure is one wrong menu item".
// These are the opposite of that. A wrong sentence here is a false statement
// about somebody's data, and the first draft of `trustLine` contained one: it
// reported "Nothing left this Mac" for a session whose audio HAD been uploaded
// and then refused, because the code assumed a refusal meant no upload. That
// bug was found by reading `relayTranscriber` by hand. It should have been
// found by a test, so now it can be.
//
// Pure functions over primitives — no `BriefDigest`, no AppKit — so the whole
// of both claims is checkable without a screen or a session.
// ─────────────────────────────────────────────────────────────────────────────

public enum SessionClaims {

    /// What actually left the machine, for one session.
    ///
    /// Exactly two things can, and both are named: the narration AUDIO, to
    /// whoever transcribed it, and the narration TEXT, to whoever wrote the
    /// summary. Screenshots, OCR, window titles and accessibility text are
    /// absent from this list because they are absent from the product — there
    /// is no endpoint that accepts them.
    ///
    /// - Parameters:
    ///   - transcriber: `"deiko"`, `"on-device"`, a `"groq:…"` variant when the
    ///     user brought their own key, `"sarvam"` for a session recorded before
    ///     the switch, or nil for one rendered before this was recorded.
    ///   - degradedReason: why the cloud path fell back, if it did.
    ///   - seconds: the span of the recognised words. Reported with a `~`
    ///     because it is a shade shorter than the recording itself.
    ///   - hasSummary: whether a summary was actually produced — a request that
    ///     was skipped or failed sent nothing.
    ///   - ownGroqKey: whether that summary went to the user's own Groq key
    ///     rather than through Deiko.
    ///   - uploadedChunks: how many requests actually reached the network this
    ///     run. Nil for a brief rendered before this was recorded.
    ///   - filedSummary: whether that request carried the summary. Not
    ///     `hasSummary`: a summary can land on the card after the request
    ///     left without one. `classify.mjs` records it in the same marker.
    ///   - filed: whether the classifier's request went out to the relay for
    ///     this session — true once the words left, whether or not an answer
    ///     ever came back, and true for own-key users too, since sorting runs
    ///     through Deiko regardless of who transcribed the audio. The caller
    ///     reads this from a marker `classify.mjs` writes before its POST,
    ///     not from whether `context.json` ended up placed — a failed or
    ///     raced request still sent the narration and window titles. Never
    ///     true for a brief made with "Sort briefs into tasks" off: nothing
    ///     is sent, so there is no marker. The claim follows the marker, not
    ///     the switch, so a brief filed before the switch went off still says
    ///     what left for it.
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

        // NOTHING WAS SENT IF NOTHING WAS SENT. A relay that could not be
        // reached at all — DNS, no route, a dead host — never opens a socket,
        // so `uploadedChunks` is 0 while `transcriber` still reads "deiko".
        // Claiming a duration there would invent an upload out of a
        // configuration. Nil means an older brief that predates the counter,
        // and there the transcriber name is the best evidence available.
        let reachedTheNetwork = uploadedChunks == nil || (uploadedChunks ?? 0) > 0

        // A REFUSAL DOES NOT MEAN NOTHING WAS SENT.
        //
        // `relayTranscriber` short-circuits only once it has ALREADY been
        // refused, so the first chunk of a spent trial is uploaded in full and
        // the relay receives the entire body before metering it — it counts
        // `body.length` and only then decides (`services/relay/relay.mjs`).
        // What is true is that the rest was never sent and none of it was
        // transcribed, so that is what this says. Claiming a clean session
        // here, or quoting a duration that never left, are both lies in the one
        // place the product cannot afford one.
        let refusedOutright = ["trial", "monthly", "ceiling", "rejected"]
            .contains(degradedReason ?? "")
        switch transcriber {
        case _ where !reachedTheNetwork:
            break
        case let name where name?.hasPrefix("groq") == true:
            parts.append("~\(seconds)s of audio to Groq, with your key")
        case "sarvam":
            // Sessions recorded before Whisper replaced Sarvam. Re-rendering one
            // must still describe what actually left at the time.
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

        // SORTING IS NOT TRANSCRIPTION. Own-key users keep their audio off
        // Deiko's servers — narration and its summary are produced by Groq
        // directly — but a brief the classifier attempted to place still
        // sent what you said, its summary, your window titles and notes on
        // earlier work, through the relay — so the card has to admit that
        // too, or the line understates what left this Mac.
        // "Its summary" only when the request carried one.
        if filed {
            parts.append(filedSummary
                ? "what you said, its summary, your window titles and notes on earlier work, to Deiko to file it"
                : "what you said, your window titles and notes on earlier work, to Deiko to file it")
        }

        return parts.isEmpty
            ? "Nothing left this Mac — everything here was made on it."
            : "Left this Mac: " + parts.joined(separator: " · ")
    }

    /// Why this transcript is worse than a clean one, in the words that carry
    /// the answer rather than just the diagnosis.
    ///
    /// Five reasons with five different answers: a spent trial wants a way to
    /// buy, a spent month wants a reset date, the service's own ceiling wants
    /// "this is not about you", an unreachable relay wants "try later" — and
    /// `timing` is not a fallback to the Mac at all. It is the opposite: the
    /// on-device CLOCK failed and the cloud text survived, so the generic
    /// sentence stated the reverse of what happened.
    ///
    /// `resetSentence` is passed in rather than computed, so this stays a pure
    /// function of its inputs and the caller owns the calendar.
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
            // The one degradation whose fix is a text field. A malformed or
            // revoked bearer cannot heal by being retried, so it is final —
            // and the user is the only one who can change it.
            return "Deiko didn't accept this install's licence key — this was transcribed "
                + "on your Mac. Check the key in Settings."
        case "on-device":
            // THE ONE DEGRADATION THAT IS A BUILD MISTAKE RATHER THAN A PLAN.
            //
            // Every other reason here is a fact about somebody's account or the
            // network. This one means the app was assembled with no
            // DeikoRelayURL, so `selectTranscriber` never had a relay to call —
            // and the only person who can fix it is whoever ran `make`.
            //
            // Kept distinct from "trial" deliberately. A spent trial is normal
            // and its answer is a purchase; this is a misconfiguration and its
            // answer is a reinstall. Collapsing the two is how a build that
            // silently lost its relay produced a day of on-device transcripts
            // that read as the aligner being broken.
            return "This build has no transcription relay, so every word came from your Mac "
                + "— accuracy is lower. Settings → Copy diagnostics shows what was stamped."
        case "unavailable":
            // "Some of this", deliberately: unlike the three above, this fires
            // for a single failed chunk as well as for a dead relay, and most
            // of the session may well have reached the cloud.
            return "Some of this couldn't reach Deiko's transcription — those parts were "
                + "transcribed on your Mac, so accuracy may be lower."
        case "timing":
            return "Word timings were estimated for part of this — what you said is intact, "
                + "but what you pointed at may bind loosely."
        default:
            // A session rendered before `degradedReason` existed still knows
            // THAT it was degraded, so it keeps the sentence it always had.
            return degraded
                ? "Some of this was transcribed on your Mac rather than in the cloud — accuracy may be lower."
                : nil
        }
    }
}
