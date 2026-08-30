import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// IS THIS BUFFER SPEECH?
//
// The whole capture pipeline hangs off this question. A cursor settle only
// becomes a referent if narration was heard recently, so a buffer wrongly
// judged silent can cost a referent — and a dropped referent is unrecoverable:
// no crop, no accessibility text, nothing in the brief, and no trace that
// anything went missing.
//
// This used to be a fixed RMS threshold of 250. Simulated over every WAV this
// project has recorded, that threshold opened a voice gap longer than the
// recorder's four-second gate in NINE of twenty recordings at the volume they
// were actually recorded at — including the last clean session, which lost a
// referent to it. An absolute threshold cannot survive a different microphone,
// a different distance from it, or a quieter mood.
//
// So the threshold is relative to the room: the noise floor is the 20th
// percentile of the last eight seconds of buffers, and speech is anything
// meaningfully above it. Measured the same way, the worst gap across all
// twenty recordings falls to 3924ms, and none exceed four seconds.
//
// Three other designs were tried against those recordings first, and each
// failed in a way worth remembering:
//
//   • A snap-down noise floor (instant down, slow creep up) is poisoned by the
//     audio engine's near-silent warm-up buffer. The floor pins near zero and
//     the creep never recovers, leaving a fixed threshold wearing a costume.
//   • A fast-climbing floor tracks the speaker's own voice as noise: talk
//     without pausing and the floor rises to meet you.
//   • Deriving the floor when the answer is ASKED for, rather than when the
//     buffer arrives, judges old buffers against the present room. The gap
//     grows back to 4778ms.
//
// A trailing percentile has neither problem: one outlier cannot move it, and
// eight seconds of continuous speech still contains enough inter-word dips to
// hold it down.
// ─────────────────────────────────────────────────────────────────────────────

public struct VoiceGate {
    /// The trailing window of buffer RMS values, oldest slot reused first.
    /// Allocated once and written in place — `note(rms:)` runs inside a
    /// real-time audio callback, where a heap allocation is a dropped buffer.
    private var window: [Double]
    private var next = 0
    private var filled = 0

    private let percentile: Double
    private let multiplier: Double
    private let absoluteFloor: Double

    /// - Parameters:
    ///   - windowSize: How many buffers the floor looks back over. The default
    ///     of 96 is eight seconds of the ~85ms buffers this app records (4096
    ///     frames at the hardware rate, resampled to 16kHz). Long enough that
    ///     continuous speech still dips below the percentile; short enough to
    ///     follow the room when it changes.
    ///   - percentile: Where in that window the noise floor sits. 0.20 rather
    ///     than the minimum, so a single anomalous buffer cannot define silence.
    ///   - multiplier: How far above the floor speech has to be.
    ///   - absoluteFloor: A hard minimum, for a room so quiet that "2.5× the
    ///     noise" is still nothing. Without it, a near-silent recording becomes
    ///     a very sensitive one and every rustle is narration.
    public init(
        windowSize: Int = 96,
        percentile: Double = 0.20,
        multiplier: Double = 2.5,
        absoluteFloor: Double = 25
    ) {
        precondition(windowSize > 0, "the floor needs something to look at")
        self.window = [Double](repeating: 0, count: windowSize)
        self.percentile = percentile
        self.multiplier = multiplier
        self.absoluteFloor = absoluteFloor
    }

    /// Records one buffer's RMS and answers whether it counts as speech.
    ///
    /// The buffer being judged is part of its own window. That is deliberate:
    /// the alternative — judging against the preceding window only — makes the
    /// first buffer after a silence unjudgeable, which is exactly the buffer
    /// that matters when narration resumes.
    public mutating func note(rms: Double) -> Bool {
        window[next] = rms
        next = (next + 1) % window.count
        filled = min(filled + 1, window.count)

        guard rms > absoluteFloor else { return false }

        // The floor is `sorted(window)[k]`, and the test is `rms > floor × m`.
        // Sorting per buffer on the audio thread would mean an allocation, so
        // use the identity: sorted(window)[k] × m < rms exactly when at least
        // k + 1 entries satisfy `entry × m < rms`. One counting pass, no sort,
        // no heap. Comparing by multiplication rather than dividing `rms` keeps
        // it bit-identical to the comparison it replaces.
        let k = Int(percentile * Double(filled - 1))
        var below = 0
        for i in 0..<filled where window[i] * multiplier < rms {
            below += 1
            if below > k { return true }
        }
        return false
    }

    /// Forgets the previous session. The room may be a different one, and more
    /// importantly the recorder's silence watchdog must not inherit a voice
    /// timestamp from a recording that has already been written out.
    /// `filled` is the sole authority on which slots are real, so clearing it
    /// is enough — the stale values are unreachable and get overwritten.
    public mutating func reset() {
        next = 0
        filled = 0
    }
}
