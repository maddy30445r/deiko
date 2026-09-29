/// The session gesture as pure logic: the session key (see `SessionKey`)
/// double-tapped starts capturing, a single tap stops. Drawing lives on Left
/// Option in `Hotkey` and never reaches this type.
///
/// Split from `Hotkey`, which needs a CGEventTap and Accessibility permission
/// and cannot be tested. Time arrives as a parameter so tests step through a
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

    /// The session key went down. Timing is press-to-press, as a double-click
    /// is defined, so holding the first press correctly fails to arm the second.
    public mutating func press(at t: Double) -> Decision {
        // A tap while capturing is never the first half of anything.
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

        // Re-arm rather than discard, so a third tap can still pair with a second.
        armedAt = t
        return .none
    }

    /// The session ended without a gesture (a watchdog, or a menu quit).
    ///
    /// Without this the gesture still believes it is capturing, so the next tap
    /// is spent stopping a dead session and `Hotkey` keeps swallowing
    /// Option-drags with nothing recording.
    public mutating func sessionEndedExternally() {
        isCapturing = false
        armedAt = nil
    }

    /// A session started without a gesture, e.g. reopened from the review window.
    ///
    /// The mirror of `sessionEndedExternally`: otherwise the tap that should
    /// stop the session is read as the first half of a double-tap to start,
    /// leaving the microphone live.
    public mutating func sessionStartedExternally() {
        isCapturing = true
        armedAt = nil
    }
}
