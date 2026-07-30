import Testing
@testable import FoveaVoice

// These are the measured failures of the previous design, frozen so they cannot
// come back. Every number here came off a real recording — the 3940ms trailing
// silence, the 3.9s delivery gap, the 55-segment file that a too-eager threshold
// cut down to 3.

private let policy = RecognitionCompletion()

// ── The bug this type exists to prevent ─────────────────────────────────────

@Test("silence before the hotkey does not stall completion")
func trailingSilenceStillCompletes() {
    // The measured session: 77.3s of file, speech stopping at 73.36s, because
    // the developer stopped talking and then reached over to press stop.
    // Judged against the FILE this never completed and cost 97 seconds of
    // waiting. Judged against the SPEECH it completes at once.
    let decision = policy.decide(
        furthestSegmentEndMs: 73_360,
        speechEndMs: 73_400,
        secondsSinceLastSegment: 0.2
    )
    #expect(decision == .finishedCovering)
}

@Test("the old duration-based test would have failed this exact case")
func theOldTestWouldStall() {
    // Same recognition, but told the target is the end of the FILE — which is
    // what the code used to pass. It must NOT report covered; that gap of
    // 3940ms against a 1500ms tolerance is the whole bug.
    let decision = policy.decide(
        furthestSegmentEndMs: 73_360,
        speechEndMs: 77_300,
        secondsSinceLastSegment: 0.2
    )
    #expect(decision == .keepWaiting)
}

// ── Coverage ────────────────────────────────────────────────────────────────

@Test("a recogniser that dropped the last word still counts as covered")
func toleranceAbsorbsADroppedTailWord() {
    // Apple hears roughly a quarter of the words in Hinglish narration, so the
    // furthest segment routinely lands short. Within the tolerance that is
    // finished, not stalled.
    #expect(policy.decide(
        furthestSegmentEndMs: 39_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 0.1
    ) == .finishedCovering)
}

@Test("falling well short of the speech is not completion")
func shortOfSpeechIsNotComplete() {
    #expect(policy.decide(
        furthestSegmentEndMs: 20_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 0.1
    ) == .keepWaiting)
}

// ── Idle ────────────────────────────────────────────────────────────────────

@Test("a normal pause between utterances is not the end")
func burstyDeliveryIsNotIdle() {
    // THE 3-SEGMENT BUG. Delivery is bursty: an utterance, a pause to think,
    // the next utterance. A 1.75s threshold treated that pause as the end and
    // returned 3 segments from a file holding 55 — reporting success. The
    // widest real gap measured is 3.9s and must still read as "keep waiting".
    #expect(policy.decide(
        furthestSegmentEndMs: 12_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 3.9
    ) == .keepWaiting)
}

@Test("a recogniser that stops short is eventually let go")
func idleFinishesAStalledRecognition() {
    #expect(policy.decide(
        furthestSegmentEndMs: 12_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 8.0
    ) == .finishedIdle)
}

@Test("coverage wins over idle when both hold")
func coverageIsReportedFirst() {
    // Not cosmetic: the two resume the continuation from different tasks, and
    // the fast path must be the one that fires, not whichever polls first.
    #expect(policy.decide(
        furthestSegmentEndMs: 40_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 30
    ) == .finishedCovering)
}

// ── Nothing yet ─────────────────────────────────────────────────────────────

@Test("a recognition that has not started is not one that has finished")
func noSegmentsIsNeverComplete() {
    // The dangerous confusion: "no segment for 8 seconds" describes a
    // recognition still loading its model exactly as well as one that is done.
    // Only holding a segment distinguishes them, so with none, never finish.
    #expect(policy.decide(
        furthestSegmentEndMs: nil,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 60
    ) == .keepWaiting)
}

@Test("unmeasurable speech end falls back to idle rather than guessing")
func unknownSpeechEndUsesIdleOnly() {
    // A file whose speech end could not be measured cannot be judged by
    // coverage. The old code returned `true` here — completing on the first
    // `isFinal`, i.e. after the first utterance. Wait for quiet instead.
    #expect(policy.decide(
        furthestSegmentEndMs: 5_000,
        speechEndMs: nil,
        secondsSinceLastSegment: 1.0
    ) == .keepWaiting)

    #expect(policy.decide(
        furthestSegmentEndMs: 5_000,
        speechEndMs: nil,
        secondsSinceLastSegment: 8.0
    ) == .finishedIdle)
}
