import Foundation

/// Decides when speech recognition is finished, which Apple's recogniser does
/// not reliably say. Two signals:
///
/// - Covered: the furthest segment has reached the last word (not the last
///   sample). The fast path. A session ends seconds after the last word, so
///   coverage of the whole file would never pass.
/// - Idle: nothing new has arrived for a while. The fallback for a file where
///   recognition stops short and no further result comes.
///
/// Split out so the judgement is plain arithmetic, testable without Speech, an
/// audio file or a TCC grant.
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
    /// Delivery is bursty, so this is silence on the wire, not in the audio.
    /// Erring long is much cheaper than erring short: too long costs seconds on
    /// the uncommon path, too short silently truncates the transcript.
    public let idleSeconds: Double

    public init(coverageToleranceMs: Double = 1500, idleSeconds: Double = 8) {
        precondition(coverageToleranceMs >= 0, "a negative tolerance demands the recogniser overshoot")
        precondition(idleSeconds > 0, "a non-positive idle threshold finishes instantly")
        self.coverageToleranceMs = coverageToleranceMs
        self.idleSeconds = idleSeconds
    }

    /// - Parameters:
    ///   - furthestSegmentEndMs: End of the latest segment held, nil if none.
    ///   - speechEndMs: Where speech stops in the audio, not where the file
    ///     stops. Nil when it could not be measured, in which case coverage
    ///     cannot be judged and only the idle signal remains.
    ///   - secondsSinceLastSegment: Wall-clock silence on the wire.
    public func decide(
        furthestSegmentEndMs: Double?,
        speechEndMs: Double?,
        secondsSinceLastSegment: Double
    ) -> Decision {
        // Nothing yet. A recognition that has not started looks like one that
        // has gone quiet; only a segment tells them apart.
        guard let furthest = furthestSegmentEndMs else { return .keepWaiting }

        if let speechEnd = speechEndMs {
            if furthest >= speechEnd - coverageToleranceMs { return .finishedCovering }
        } else {
            // No measurable speech end: coverage is unanswerable, so fall
            // through to idle.
        }

        if secondsSinceLastSegment >= idleSeconds { return .finishedIdle }
        return .keepWaiting
    }
}
