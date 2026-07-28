/// THE SESSION GESTURE, as pure logic.
///
/// Right Option controls the session and nothing else:
///
///   double-tap  → start capturing
///   single tap  → stop
///
/// Drawing lives on Left Option, in `Hotkey`, and never reaches this type. That
/// separation is the point. Both used to be Right Option, told apart by whether
/// a drag happened during the press — a distinction the user had to feel rather
/// than see, and one that already shipped a bug where the second tap of a
/// double-tap locked the session and its own release immediately stopped it.
///
/// There is also no "hold to capture" mode any more. It existed for a
/// ten-second capture, and nobody describes a task worth planning in ten
/// seconds; every real session so far ran from tens of seconds to minutes.
///
/// This lives apart from `Hotkey` because `Hotkey` needs a CGEventTap and
/// Accessibility permission, so nothing inside it can be tested. Time arrives
/// as a parameter rather than from a clock, so the tests step through a
/// double-tap without sleeping.
public struct SessionGesture: Sendable {

    public enum Decision: Equatable, Sendable {
        /// A first tap, or a second one that came too late. Arms, does nothing.
        case none
        case start
        case stopNow
    }

    /// How soon after a tap another one counts as a double-tap. macOS's own
    /// double-click default.
    public let doubleTapWindowMs: Double

    public private(set) var isCapturing = false

    /// When the last unmatched tap happened, if it is still live.
    private var armedAt: Double?

    public init(doubleTapWindowMs: Double = 350) {
        self.doubleTapWindowMs = doubleTapWindowMs
    }

    /// Right Option went down. Releases carry no meaning at all now, so there
    /// is no counterpart to this.
    ///
    /// Measured press-to-press rather than release-to-press: it matches how a
    /// double-click is defined, and it means holding the first press for a
    /// while correctly fails to arm the second.
    public mutating func press(at t: Double) -> Decision {
        // Stopping is immediate and unconditional. A tap while capturing is
        // never the first half of anything — there is nothing to start.
        if isCapturing {
            isCapturing = false
            armedAt = nil
            return .stopNow
        }

        if let armed = armedAt, t - armed < doubleTapWindowMs {
            armedAt = nil
            isCapturing = true
            return .start
        }

        // First tap, or too slow to pair with the last one. Re-arm from here
        // rather than discarding, so a third tap can still pair with a second.
        armedAt = t
        return .none
    }

    /// The session ended without a gesture — a watchdog stopped it, or the
    /// user quit from the menu.
    ///
    /// Without this the two halves desync: the gesture still believes it is
    /// capturing, so the next tap is spent "stopping" a session that already
    /// ended, and — worse — `Hotkey` goes on swallowing Option-drags when no
    /// recording is running, breaking box-select and Finder duplicate in apps
    /// Fovea is not even watching.
    public mutating func sessionEndedExternally() {
        isCapturing = false
        armedAt = nil
    }

    /// The event tap was disabled and re-enabled. Presses may have gone
    /// unobserved, so a half-finished double-tap can no longer be trusted.
    ///
    /// Capture itself is left alone deliberately: without a held mode there is
    /// no state that a missed release could strand, and a session the user
    /// started should survive a tap hiccup. The watchdogs in `Recorder` are
    /// what stop a session nobody ends.
    public mutating func tapRecovered() {
        armedAt = nil
    }
}
