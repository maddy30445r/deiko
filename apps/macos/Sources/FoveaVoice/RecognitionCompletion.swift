import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// WHEN IS RECOGNITION FINISHED?
//
// Apple's recogniser does not reliably say. It marks each UTTERANCE final in
// turn, and at end-of-audio it sometimes errors, sometimes emits a last result,
// and sometimes does neither — so the caller has to decide for itself, and
// deciding wrong is expensive in both directions.
//
// It used to decide by coverage alone: "has the furthest segment reached the end
// of the file?", within 1.5s. That is wrong about what a recording IS. A session
// ends when the developer reaches over and presses the hotkey, seconds after
// their last word — the measured session trails 3940ms of silence. The test
// could therefore never pass, every session fell through to a `duration + 20s`
// deadline, and 103 seconds of "recognition" turned out to be 6 seconds of work
// and 97 of waiting.
//
// So there are two signals, and this type is the whole of the decision:
//
//   COVERED — the furthest segment has reached the last WORD (not the last
//             sample). The fast path, and the common one.
//   IDLE    — nothing new has arrived for a while. The fallback, for a file
//             where recognition simply stops short of the end and no further
//             result ever comes.
//
// Split out of `SpeechTiming` for the same reason as `VoiceGate` next door:
// every way of ASKING the recogniser needs Speech, a real audio file and a TCC
// grant, but the judgement itself is arithmetic and should be testable without
// any of them.
// ─────────────────────────────────────────────────────────────────────────────

public struct RecognitionCompletion: Sendable {

    public enum Decision: Equatable, Sendable {
        case keepWaiting
        /// The furthest segment reached the end of the speech.
        case finishedCovering
        /// The recogniser went quiet with segments in hand.
        case finishedIdle
    }

    /// How far short of the last word the furthest segment may fall and still
    /// count as complete. Absorbs the recogniser dropping a trailing word.
    public let coverageToleranceMs: Double

    /// How long the recogniser may be silent before it is presumed done.
    ///
    /// Delivery is BURSTY — a whole utterance, a pause to think, the next
    /// utterance — so this is not "silence in the audio", it is silence on the
    /// wire. Measured gaps reach 3.9s; the default leaves roughly 2x headroom.
    ///
    /// Erring long is much cheaper than erring short: too long costs seconds on
    /// a path that is not the common one, while too short truncates the
    /// transcript silently and nothing downstream can tell that it happened. A
    /// 1.75s threshold tried during development returned 3 segments from a file
    /// holding 55, and reported success.
    public let idleSeconds: Double

    public init(coverageToleranceMs: Double = 1500, idleSeconds: Double = 8) {
        precondition(coverageToleranceMs >= 0, "a negative tolerance demands the recogniser overshoot")
        precondition(idleSeconds > 0, "a non-positive idle threshold finishes instantly")
        self.coverageToleranceMs = coverageToleranceMs
        self.idleSeconds = idleSeconds
    }

    /// - Parameters:
    ///   - furthestSegmentEndMs: End of the latest segment held, nil if none.
    ///   - speechEndMs: Where speech stops in the audio — NOT where the file
    ///     stops. Nil when it could not be measured, in which case coverage
    ///     cannot be judged and only the idle signal remains.
    ///   - secondsSinceLastSegment: Wall-clock silence on the wire.
    public func decide(
        furthestSegmentEndMs: Double?,
        speechEndMs: Double?,
        secondsSinceLastSegment: Double
    ) -> Decision {
        // Nothing yet. Not "finished with no words" — a recognition that has not
        // started looks exactly like one that has gone quiet, and only the
        // presence of a segment tells them apart.
        guard let furthest = furthestSegmentEndMs else { return .keepWaiting }

        if let speechEnd = speechEndMs {
            if furthest >= speechEnd - coverageToleranceMs { return .finishedCovering }
        } else {
            // No measurable speech end. Coverage is unanswerable, so fall
            // through to idle rather than assuming either answer.
        }

        if secondsSinceLastSegment >= idleSeconds { return .finishedIdle }
        return .keepWaiting
    }
}
