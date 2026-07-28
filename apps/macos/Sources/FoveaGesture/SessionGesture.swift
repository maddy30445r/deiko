/// THE SESSION GESTURE, as pure logic.
///
/// One modifier key has to mean three things — capture while held, lock
/// hands-free, draw a lasso — and which one it meant is only knowable from the
/// sequence: whether a drag happened during the press, and how long since the
/// last release. That is a state machine, and state machines get subtly wrong.
///
/// It lives here, apart from `Hotkey`, for exactly one reason: `Hotkey` needs a
/// CGEventTap and Accessibility permission, so nothing in it can be tested. The
/// first version of this logic shipped a bug where the second tap of a
/// double-tap locked the session and its own release immediately stopped it
/// again — invisible by inspection, and only findable by performing the gesture.
/// Now it is nine lines of test.
///
/// Timing arrives as a parameter rather than being read from a clock, so the
/// tests can step through a double-tap without sleeping.
public struct SessionGesture: Sendable {

    /// What the caller should do. `stopAfterGrace` is the interesting one: a
    /// release does not stop capture, it schedules a stop that a second press
    /// can cancel — which is what keeps audio continuous across a promotion.
    public enum Decision: Equatable, Sendable {
        case none
        case start
        case lock
        case stopAfterGrace
        case stopNow
    }

    /// How soon after a release a press counts as the second half of a
    /// double-tap. macOS's own double-click default.
    public let doubleTapWindowMs: Double

    public private(set) var isCapturing = false
    public private(set) var isLocked = false

    private var lastReleaseAt: Double?
    private var draggedThisPress = false
    private var lockedThisPress = false

    public init(doubleTapWindowMs: Double = 350) {
        self.doubleTapWindowMs = doubleTapWindowMs
    }

    /// The modifier went down.
    public mutating func press(at t: Double) -> Decision {
        draggedThisPress = false
        lockedThisPress = false

        // Second half of a double-tap: promote rather than restart.
        if !isLocked, isCapturing,
           let last = lastReleaseAt, t - last < doubleTapWindowMs {
            lastReleaseAt = nil
            isLocked = true
            lockedThisPress = true
            return .lock
        }

        // While locked, a press decides nothing on its own — it is either the
        // start of a lasso or the tap that stops, and only the release knows.
        guard !isLocked else { return .none }

        if !isCapturing {
            isCapturing = true
            return .start
        }
        // Pressed again after the window expired but before the scheduled stop
        // ran. Continue the session rather than stacking a second one on it.
        return .none
    }

    /// A drag began during the current press — this press is drawing a lasso.
    public mutating func dragStarted() {
        draggedThisPress = true
    }

    /// The modifier came up.
    public mutating func release(at t: Double) -> Decision {
        defer { lockedThisPress = false }

        if isLocked {
            // A lasso is just a lasso, and so is the release of the very tap
            // that locked. Anything else is the tap that ends the session.
            if draggedThisPress || lockedThisPress { return .none }
            return stop()
        }

        // Held mode. A release that drew a lasso cannot begin a double-tap:
        // finishing a drawing is not half of a promotion gesture.
        lastReleaseAt = draggedThisPress ? nil : t
        return .stopAfterGrace
    }

    /// The grace window elapsed with no second press.
    public mutating func graceExpired() -> Decision {
        guard isCapturing, !isLocked else { return .none }
        return stop()
    }

    /// The event tap was disabled and re-enabled; the modifier's true state was
    /// read back afterwards. A release may have gone unobserved in between.
    ///
    /// In HELD mode that would leave capture running forever, so end it —
    /// losing the tail of a sentence beats a stuck microphone. In LOCKED mode
    /// nothing is owed: the user stops by tapping, and always could.
    public mutating func tapRecovered(modifierStillDown: Bool) -> Decision {
        draggedThisPress = false
        lastReleaseAt = nil
        guard !modifierStillDown, !isLocked, isCapturing else { return .none }
        return stop()
    }

    private mutating func stop() -> Decision {
        isCapturing = false
        isLocked = false
        lastReleaseAt = nil
        return .stopNow
    }
}
