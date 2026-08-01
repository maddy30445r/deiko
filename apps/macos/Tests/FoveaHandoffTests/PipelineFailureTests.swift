import Testing
@testable import FoveaHandoff

// Each fixture below is the text a script ACTUALLY prints, copied from
// scripts/transcribe.mjs, scripts/render-brief.mjs and scripts/lib/redact.mjs.
// A taxonomy tested against invented strings would pass while classifying
// nothing a user will ever see.

@Test("a missing key sends the user to Settings, not to a shell")
func noKey() {
    let real = """
        ✗ SARVAM_API_KEY is not set. Copy .env.example to .env and fill it in,
          then run:  export $(grep -v '^#' .env | xargs)
        """
    let failure = PipelineFailure.classify(stage: "Transcribing", output: real)

    #expect(failure.kind == .noAPIKey)
    #expect(failure.opensSettings)
    // The whole point: the shipped app has no .env and the user is not in a
    // shell, so neither may appear in what they are told to do.
    #expect(!failure.message.contains(".env"))
    #expect(!failure.message.contains("export"))
    #expect(failure.raw == real, "the original survives for a bug report")
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
        Error: Refusing to write. Fix looksOpaque / SECRET_MARKER in scripts/render-brief.mjs.
            at renderBrief (/Applications/Fovea.app/Contents/Resources/scripts/render-brief.mjs:467:11)
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
