import Testing
@testable import DeikoVoice

// Regression cases for completion: trailing silence before the stop press,
// bursty delivery gaps, and a recogniser that stops short.

private let policy = RecognitionCompletion()

@Test("silence before the hotkey does not stall completion")
func trailingSilenceStillCompletes() {
    // A 77.3s file with speech ending at 73.36s: the developer stopped talking,
    // then reached over to press stop. Judged against the file this never
    // completes; judged against the speech it completes at once.
    let decision = policy.decide(
        furthestSegmentEndMs: 73_360,
        speechEndMs: 73_400,
        secondsSinceLastSegment: 0.2
    )
    #expect(decision == .finishedCovering)
}

@Test("the old duration-based test would have failed this exact case")
func theOldTestWouldStall() {
    // Same recognition, but given the end of the file as the target. It must
    // not report covered: a 3940ms gap against a 1500ms tolerance is the
    // failure this type prevents.
    let decision = policy.decide(
        furthestSegmentEndMs: 73_360,
        speechEndMs: 77_300,
        secondsSinceLastSegment: 0.2
    )
    #expect(decision == .keepWaiting)
}

@Test("a recogniser that dropped the last word still counts as covered")
func toleranceAbsorbsADroppedTailWord() {
    // Apple hears only a fraction of the words in Hinglish narration, so the
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

@Test("a normal pause between utterances is not the end")
func burstyDeliveryIsNotIdle() {
    // Delivery is bursty: an utterance, a pause to think, the next utterance.
    // A short idle threshold would treat that pause as the end and silently
    // truncate the transcript. A 3.9s gap must still read as "keep waiting".
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
    // The two resume the continuation from different tasks, and the fast path
    // must be the one that fires.
    #expect(policy.decide(
        furthestSegmentEndMs: 40_000,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 30
    ) == .finishedCovering)
}

@Test("a recognition that has not started is not one that has finished")
func noSegmentsIsNeverComplete() {
    // "No segment for 8 seconds" describes a recognition still loading its
    // model as well as one that is done. Only holding a segment tells them
    // apart, so with none, never finish.
    #expect(policy.decide(
        furthestSegmentEndMs: nil,
        speechEndMs: 40_000,
        secondsSinceLastSegment: 60
    ) == .keepWaiting)
}

@Test("unmeasurable speech end falls back to idle rather than guessing")
func unknownSpeechEndUsesIdleOnly() {
    // Speech whose end cannot be measured cannot be judged by coverage.
    // Completing on the first `isFinal` would stop after the first utterance;
    // wait for quiet instead.
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
