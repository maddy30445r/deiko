import Foundation

/// Decides whether an audio buffer is speech. A cursor settle only becomes a
/// referent if narration was heard recently, and a referent lost to a false
/// "silent" is unrecoverable.
///
/// The threshold is relative to the room, not fixed: the noise floor is a low
/// percentile of the last eight seconds of buffers, and speech is anything
/// meaningfully above it. Alternatives that fail: a snap-down floor is poisoned
/// by the engine's near-silent warm-up buffer; a fast-climbing floor tracks the
/// speaker's own voice as noise; deriving the floor when the answer is asked,
/// rather than when the buffer arrives, judges old buffers against the present
/// room.
public struct VoiceGate {
    /// The trailing window of buffer RMS values, oldest slot reused first.
    /// Written in place: `note(rms:)` runs in a real-time audio callback, where
    /// a heap allocation is a dropped buffer.
    private var window: [Double]
    private var next = 0
    private var filled = 0

    private let percentile: Double
    private let multiplier: Double
    private let absoluteFloor: Double

    /// - Parameters:
    ///   - windowSize: How many buffers the floor looks back over. The default
    ///     of 96 is about eight seconds of the ~85ms buffers this app records.
    ///     Long enough that continuous speech still dips below the percentile,
    ///     short enough to follow the room.
    ///   - percentile: Where in that window the noise floor sits. Not the
    ///     minimum, so a single anomalous buffer cannot define silence.
    ///   - multiplier: How far above the floor speech has to be.
    ///   - absoluteFloor: A hard minimum for a very quiet room, where "2.5x the
    ///     noise" is still nothing. Without it every rustle is narration.
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
    /// The buffer being judged is part of its own window; otherwise the first
    /// buffer after a silence, which matters most when narration resumes, could
    /// not be judged.
    public mutating func note(rms: Double) -> Bool {
        window[next] = rms
        next = (next + 1) % window.count
        filled = min(filled + 1, window.count)

        guard rms > absoluteFloor else { return false }

        // The floor is `sorted(window)[k]` and the test is `rms > floor * m`.
        // Sorting on the audio thread would allocate, so count instead:
        // sorted(window)[k] * m < rms exactly when at least k + 1 entries
        // satisfy `entry * m < rms`. Multiplying rather than dividing `rms`
        // keeps the comparison bit-identical to the sorted form.
        let k = Int(percentile * Double(filled - 1))
        var below = 0
        for i in 0..<filled where window[i] * multiplier < rms {
            below += 1
            if below > k { return true }
        }
        return false
    }

    /// Forgets the previous session. The recorder's silence watchdog must not
    /// inherit a voice timestamp from a recording already written out. `filled`
    /// alone says which slots are real, so clearing it is enough.
    public mutating func reset() {
        next = 0
        filled = 0
    }
}
