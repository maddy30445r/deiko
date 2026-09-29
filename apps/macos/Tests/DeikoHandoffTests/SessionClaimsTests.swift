import Testing
@testable import DeikoHandoff

// These sentences are claims a user is invited to check, so the tests pin truth
// rather than wording: each would be a false statement about somebody's data if
// it flipped.

@Test("a session with no cloud anything says nothing left")
func nothingLeft() {
    let line = SessionClaims.trustLine(
        transcriber: "on-device", degradedReason: nil,
        seconds: 43, uploadedChunks: 0, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
    )
    #expect(line == "Nothing left this Mac — everything here was made on it.")
}

@Test("A REFUSED SESSION STILL SENT AUDIO, and must not claim otherwise")
func refusalDoesNotMeanNothingWasSent() {
    // A refused session still sent audio. `relayTranscriber` short-circuits
    // only once already refused, so the first chunk of a spent trial is
    // uploaded in full and the relay receives the whole body before metering
    // it. Claiming "Nothing left this Mac" here would be false.
    for reason in ["trial", "monthly", "ceiling", "rejected"] {
        let line = SessionClaims.trustLine(
            transcriber: "deiko", degradedReason: reason,
            seconds: 90, uploadedChunks: 1, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
        )
        #expect(!line.contains("Nothing left"), "\(reason) uploaded a chunk before being refused")
        #expect(line.contains("Deiko's transcription"))
        // …and it must not quote a duration that never left, either.
        #expect(!line.contains("90s"), "\(reason) sent one chunk, not the whole session")
    }
}

@Test("a transient failure did reach the cloud, so the duration stands")
func unavailableStillSentMostOfIt() {
    // Unlike the three above, `unavailable` fires for one failed chunk out of
    // many — most of the audio went, and saying so is the honest reading.
    let line = SessionClaims.trustLine(
        transcriber: "deiko", degradedReason: "unavailable",
        seconds: 90, uploadedChunks: 4, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
    )
    #expect(line.contains("~90s of audio to Deiko's transcription"))
}

@Test("a BYO key names the vendor it actually went to")
func ownKeyNamesSarvam() {
    let line = SessionClaims.trustLine(
        transcriber: "sarvam", degradedReason: nil,
        seconds: 12, uploadedChunks: 1, hasSummary: true, ownGroqKey: true, filed: false, filedSummary: true
    )
    #expect(line.contains("~12s of audio to Sarvam, with your key"))
    #expect(line.contains("your narration to Groq, with your key"))
    // Deiko's servers saw neither, and the line must not imply they did.
    #expect(!line.contains("Deiko's transcription"))
}

@Test("a summary through Deiko is named as narration, not as screen content")
func summaryThroughRelay() {
    let line = SessionClaims.trustLine(
        transcriber: "deiko", degradedReason: nil,
        seconds: 30, uploadedChunks: 2, hasSummary: true, ownGroqKey: false, filed: false, filedSummary: true
    )
    #expect(line.contains("your narration, for the summary"))
}

@Test("a brief the classifier sent to the relay says so, on top of whatever else left")
func filedAddsTheSortingClaim() {
    // `filed` means the request went out, not that an answer came back or a
    // task was assigned; `context.json` can be absent or unplaced and this is
    // still true. See `ClassifyRequest.sentSummary` (DeikoCapture) for where
    // the caller gets this and `filedSummary`.
    let line = SessionClaims.trustLine(
        transcriber: "deiko", degradedReason: nil,
        seconds: 30, uploadedChunks: 2, hasSummary: true, ownGroqKey: false, filed: true, filedSummary: true
    )
    #expect(line.contains("what you said, its summary, your window titles and notes on earlier work, to Deiko to file it"))
}

@Test("a brief filed before its summary existed does not claim the summary went to be filed")
func filedWithoutSummaryNamesNoSummary() {
    // The summary is on the card now, but the classifier's request left
    // without it — so it is named for the summary call and not for filing.
    let line = SessionClaims.trustLine(
        transcriber: "deiko", degradedReason: nil,
        seconds: 30, uploadedChunks: 2, hasSummary: true, ownGroqKey: false, filed: true, filedSummary: false
    )
    #expect(line.contains("your narration, for the summary"))
    #expect(line.contains("what you said, your window titles and notes on earlier work, to Deiko to file it"))
    #expect(!line.contains("its summary"))
}

@Test("an own-key session that was still sent to the classifier names both — Groq for the words, Deiko for sorting")
func ownKeySessionCanStillBeFiled() {
    // Bringing your own key keeps audio and the summary off Deiko, but the
    // brief is still sorted through the relay, so the line must say so without
    // claiming Deiko transcribed anything.
    let line = SessionClaims.trustLine(
        transcriber: "groq:whisper-large-v3", degradedReason: nil,
        seconds: 12, uploadedChunks: 1, hasSummary: true, ownGroqKey: true, filed: true, filedSummary: true
    )
    #expect(line.contains("~12s of audio to Groq, with your key"))
    #expect(line.contains("your narration to Groq, with your key"))
    #expect(line.contains("what you said, its summary, your window titles and notes on earlier work, to Deiko to file it"))
    #expect(!line.contains("Deiko's transcription"))
}

@Test("with sorting off nothing is filed, so no other input brings the filing clause in")
func sortingOffNeverClaimsFiling() {
    // Off, `classify.mjs` sends nothing and leaves no marker, so the caller
    // passes `filed: false`. An own key, a summary, a summary said to have
    // gone with a request: none of them may stand in for the marker.
    for transcriber in ["groq:whisper-large-v3", "deiko", "on-device", nil] {
        for ownKey in [true, false] {
            for hasSummary in [true, false] {
                let line = SessionClaims.trustLine(
                    transcriber: transcriber, degradedReason: nil,
                    seconds: 12, uploadedChunks: 1, hasSummary: hasSummary, ownGroqKey: ownKey, filed: false, filedSummary: true
                )
                #expect(!line.contains("to file it"))
                #expect(!line.contains("notes on earlier work"))
            }
        }
    }
}

@Test("nothing in the line ever names screen content, for a brief that was never filed")
func screenContentIsNeverClaimedToLeave() {
    // The product's central claim: screenshots, OCR and accessibility text have
    // no code path off the device. Window titles are the exception (the
    // classifier sends them to place a filed brief, which `filed: true` says),
    // so this holds `filed: false` and checks that every other combination
    // stays silent about them.
    for transcriber in ["sarvam", "deiko", "on-device", nil] {
        for reason in [nil, "trial", "monthly", "ceiling", "unavailable", "timing", "rejected"] {
            for hasSummary in [true, false] {
                let line = SessionClaims.trustLine(
                    transcriber: transcriber, degradedReason: reason,
                    seconds: 30, uploadedChunks: 3, hasSummary: hasSummary, ownGroqKey: false, filed: false, filedSummary: hasSummary
                ).lowercased()
                #expect(!line.contains("screenshot"))
                #expect(!line.contains("screen text"))
                #expect(!line.contains("window"))
            }
        }
    }
}

@Test("a session rendered before the transcriber was recorded claims nothing")
func unknownTranscriberClaimsNothing() {
    // Old briefs on disk have no `transcriber`. Guessing would be worse than
    // silence: this line is only worth anything if it never overstates.
    let line = SessionClaims.trustLine(
        transcriber: nil, degradedReason: nil,
        seconds: 30, uploadedChunks: nil, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
    )
    #expect(line.contains("Nothing left"))
}

@Test("a clean session gets no sentence at all")
func cleanSessionSaysNothing() {
    #expect(SessionClaims.degradedSentence(nil, degraded: false, resetSentence: "Resets 1 May") == nil)
}

@Test("each reason carries the answer that reason actually has")
func reasonsCarryTheirAnswers() {
    let reset = "Resets 1 May (UTC)"
    let trial = SessionClaims.degradedSentence("trial", degraded: true, resetSentence: reset)
    #expect(trial?.contains("free 30 minutes") == true)

    // A spent month is the one with a date, because that is what the user
    // wants to know and it is the only reason that has one.
    let monthly = SessionClaims.degradedSentence("monthly", degraded: true, resetSentence: reset)
    #expect(monthly?.contains(reset) == true)

    // The service's ceiling is Deiko's problem; a paying user must not
    // read it as a fault of their plan.
    let ceiling = SessionClaims.degradedSentence("ceiling", degraded: true, resetSentence: reset)
    #expect(ceiling?.lowercased().contains("nothing is wrong with your plan") == true)
}

@Test("a transient failure is not described as if the whole session was local")
func unavailableIsPartial() {
    // It fires for one failed chunk as well as a dead relay.
    let line = SessionClaims.degradedSentence("unavailable", degraded: true, resetSentence: "")
    #expect(line?.hasPrefix("Some of this") == true)
}

@Test("`timing` is the OPPOSITE degradation and must not claim a local transcript")
func timingIsNotAFallbackToTheMac() {
    // The on-device clock failed and the cloud text survived. The generic
    // sentence ("transcribed on your Mac") states the reverse of what happened.
    let line = SessionClaims.degradedSentence("timing", degraded: true, resetSentence: "")
    #expect(line?.contains("transcribed on your Mac") == false)
    #expect(line?.contains("timings") == true)
}

@Test("an older brief that only knows it was degraded still gets a sentence")
func degradedWithoutAReasonStillExplains() {
    let line = SessionClaims.degradedSentence(nil, degraded: true, resetSentence: "")
    #expect(line != nil)
    // An unrecognised reason from a newer renderer degrades to the same generic
    // line rather than falling silent.
    #expect(SessionClaims.degradedSentence("something-new", degraded: true, resetSentence: "") != nil)
}

@Test("a session whose audio never reached the network claims nothing")
func nothingUploadedClaimsNothing() {
    // Two ways to land here. A DNS failure never opens a socket, so
    // `transcriber` reads "deiko" while nothing left. And reopening an old
    // session re-runs the pipeline from the transcript cache (every hold a
    // cache hit, nothing uploaded), which must not announce an upload that
    // never happened.
    let line = SessionClaims.trustLine(
        transcriber: "deiko", degradedReason: "unavailable",
        seconds: 62, uploadedChunks: 0, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
    )
    #expect(line.contains("Nothing left"))
    #expect(!line.contains("62s"))
}

@Test("a rejected key is final, and its fix is Settings")
func rejectedKeyIsActionable() {
    // 401/403 cannot heal by retrying, so it short-circuits like the quota
    // refusals — but unlike them the user can actually fix it.
    let line = SessionClaims.degradedSentence("rejected", degraded: true, resetSentence: "")
    #expect(line?.contains("Settings") == true)
    #expect(line?.contains("licence key") == true)
}

@Test("a relay-less build names the build, not a plan")
func onDeviceNamesTheBuild() {
    let sentence = SessionClaims.degradedSentence("on-device", degraded: true, resetSentence: "")
    #expect(sentence != nil)
    // A build that silently loses its relay produces on-device transcripts,
    // and wording that sends somebody to check their subscription is the wrong
    // advice: the fix is a rebuild.
    #expect(sentence?.contains("build") == true)
    #expect(sentence?.contains("used up") != true)
    #expect(sentence?.contains("free") != true)
}

@Test("a missing relay and a spent trial never read the same")
func onDeviceIsNotTrial() {
    #expect(SessionClaims.degradedSentence("on-device", degraded: true, resetSentence: "")
            != SessionClaims.degradedSentence("trial", degraded: true, resetSentence: ""))
}

@Test("on-device never makes the trust line claim an upload")
func onDeviceStaysLocal() {
    // `trustLine` must not change for this reason: a session that uploaded
    // nothing did not reach the network, whatever the degradation is called.
    let line = SessionClaims.trustLine(
        transcriber: "on-device", degradedReason: "on-device",
        seconds: 80, uploadedChunks: 0, hasSummary: false, ownGroqKey: false, filed: false, filedSummary: false
    )
    #expect(line.contains("Nothing left this Mac"))
}
