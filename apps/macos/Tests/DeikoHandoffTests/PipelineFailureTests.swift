import Testing
@testable import DeikoHandoff

// Each fixture below is the text a script ACTUALLY prints, copied from
// packages/core/src/transcribe.mjs, packages/core/src/render-brief.mjs and packages/core/src/lib/redact.mjs.
// A taxonomy tested against invented strings would pass while classifying
// nothing a user will ever see.

// THE MISSING-KEY CASE IS GONE, and its deletion is the finding.
//
// `pipeline-contract.test.mjs` had listed "sarvam_api_key is not set" for
// releases as a branch no script can reach any more: `selectTranscriber` falls
// through to the relay and then to on-device words, so a keyless install
// transcribes rather than failing. The branch stayed, telling anybody unlucky
// enough to reach it that Deiko needs a key it does not need. Classifying a
// failure that cannot happen is not free — it was the first thing `classify`
// checked, and it was the wrong sentence.

@Test("this month's Pro hours are not a bug report")
func monthlyCapSpent() {
    // services/relay/src/quota.mjs:200, wrapped by transcribe.mjs's relay error.
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Deiko relay 429: {"error":"this month's fair-use limit is used up"}"#
    )

    #expect(failure.kind == .quotaExhausted)
    #expect(failure.message.contains("Pro hours"))
    #expect(failure.message.contains("resets"))
    // A paying customer who has spent their month has no key to fix and
    // nothing to report; both would send them somewhere useless.
    #expect(!failure.opensSettings)
    #expect(!failure.message.contains("bug report"))
    // They have no relationship with Sarvam.
    #expect(!failure.message.lowercased().contains("sarvam"))
}

@Test("the service's own ceiling says the plan is fine")
func serviceCeiling() {
    // quota.mjs:190 — checked before any per-subject cap, precisely so a paying
    // customer is never told THEY are out when the service is.
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Deiko relay 429: {"error":"the service is at its daily ceiling — try again tomorrow"}"#
    )

    #expect(failure.kind == .quotaExhausted)
    #expect(failure.message.lowercased().contains("nothing is wrong with your plan"))
    #expect(!failure.message.contains("bug report"))
}

@Test("a metering outage reads as temporary, not as a fault of theirs")
func meteringUnavailable() {
    // relay.mjs:223/249 — the relay fails closed when DynamoDB is unreachable.
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Deiko relay 503: {"error":"usage service unavailable: timeout"}"#
    )

    #expect(failure.kind == .offline)
    #expect(failure.message.contains("saved"))
    #expect(!failure.message.contains("bug report"))
    #expect(!failure.opensSettings)
}

@Test("the relay's own rate limiter does not blame a vendor the user never chose")
func relayRateLimitNamesNoVendor() {
    // relay.mjs:203. This lands in the `rate limit` branch, which used to say
    // "Sarvam is rate-limiting" about Deiko's own per-container limiter.
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Deiko relay 429: {"error":"rate limit exceeded"}"#
    )

    #expect(failure.kind == .quotaExhausted)
    #expect(!failure.message.lowercased().contains("sarvam"))
}

@Test("a rejected key is not confused with a missing one")
func rejectedKey() {
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Sarvam 401: {"error":{"message":"Invalid API key provided","code":"invalid_api_key"}}"#
    )
    #expect(failure.kind == .authRejected)
    #expect(failure.opensSettings)
    // 400 characters of provider JSON is not a sentence.
    #expect(!failure.message.contains("{"))
}

@Test("rate limiting reads as temporary, and does not send anyone to Settings")
func quota() {
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: #"Sarvam 429: {"error":"rate limit exceeded"}"#
    )
    #expect(failure.kind == .quotaExhausted)
    #expect(!failure.opensSettings, "the key is fine; changing it would be the wrong fix")
}

@Test("Node's opaque `fetch failed` becomes a connection problem")
func offline() {
    // undici collapses DNS, refused connections and TLS into this one string,
    // and the cause chain does not survive into stderr.
    let failure = PipelineFailure.classify(stage: "Transcribing", output: "✗ fetch failed")
    #expect(failure.kind == .offline)
    #expect(failure.message.lowercased().contains("internet"))
}

@Test("silence names the microphone, which is what the user has to go and check")
func noSpeech() {
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: "\n✗ no words transcribed — not writing transcript.json"
    )
    #expect(failure.kind == .noSpeech)
    #expect(failure.message.lowercased().contains("microphone"))
}

@Test("a mic that never delivered a buffer is the same problem")
func noAudioBuffers() {
    let failure = PipelineFailure.classify(
        stage: "Transcribing",
        output: "  hold 1: no audioT0 — mic never delivered a buffer, skipping\n✗ no holds with usable audio"
    )
    #expect(failure.kind == .noSpeech)
}

@Test("a redaction refusal reassures rather than instructing a code edit")
func redaction() {
    let real = """
        Error: Refusing to write. Fix looksOpaque / SECRET_MARKER in packages/core/src/lib/redact.mjs.
            at renderBrief (/Applications/Deiko.app/Contents/Resources/scripts/render-brief.mjs:467:11)
        """
    let failure = PipelineFailure.classify(stage: "Rendering the brief", output: real)

    #expect(failure.kind == .redactionRefused)
    // Telling somebody to edit a file inside a signed app bundle is not a fix.
    #expect(!failure.message.contains("render-brief.mjs"))
    #expect(failure.message.lowercased().contains("nothing was sent"))
}

@Test("an unclassified failure says so honestly and keeps the output")
func unknown() {
    let noise = "make: *** [brief] Error 1\nsome unexpected thing"
    let failure = PipelineFailure.classify(stage: "Rendering the brief", output: noise)

    #expect(failure.kind == .unknown)
    #expect(failure.message.contains("Rendering the brief"))
    #expect(failure.raw == noise)
    #expect(!failure.opensSettings)
}

@Test("classification is case-insensitive — script output is not a stable format")
func caseInsensitive() {
    #expect(PipelineFailure.classify(stage: "s", output: "SARVAM 401: nope").kind == .authRejected)
    #expect(PipelineFailure.classify(stage: "s", output: "FETCH FAILED").kind == .offline)
}

@Test("a stage that never finished names the quarantine fix, not the timeout")
func timedOut() {
    // BriefPipeline's watchdog writes this after 180s. The commonest cause is
    // a quarantined Node runtime: macOS refuses the spawned binary, nothing
    // ever comes back, and the orb used to sit at "Transcribing…" forever.
    let real = "timed out after 180s\n"
    let failure = PipelineFailure.classify(stage: "Transcribing", output: real)

    #expect(failure.kind == .timedOut)
    #expect(failure.message.lowercased().contains("saved"))
    #expect(failure.message.contains("xattr -dr com.apple.quarantine"))
}
