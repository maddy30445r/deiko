/// The fling as pure logic. The orb is the last step of a session: press it,
/// drag it onto the window running Claude Code, let go, and the brief lands in
/// that live session.
///
///   click (no travel)  → open the options
///   drag and release   → hand the brief to whatever is under the cursor
///   release on the orb → cancelled
///   Escape             → cancelled
///
/// This is deliberately not an `NSDraggingSession`. A real drag needs the
/// destination to accept a pasteboard type, and a terminal accepts none, so the
/// cursor would show a rejection badge over the window being aimed at. A fling
/// asks the destination for nothing; it is a way of pointing.
///
/// The one exception: a chat composer attaches a file that is dropped on it and
/// ignores the same file pasted. When a fling is over a browser and the session
/// has a persona file, `OrbController` upgrades it to a real drag mid-flight
/// (see `upgradeToSystemDrag`).
///
/// Lives apart from the orb because resolving what is under the cursor needs a
/// window server. Distance arrives as a scalar and the target already resolved,
/// so only decisions are here.
public struct FlingGesture: Sendable {

    public enum Decision: Equatable, Sendable {
        /// Nothing to say — the press was ignored, or the drag is still short of
        /// the threshold.
        case none
        /// A press and release with no travel. The user tapped the orb.
        case openOptions
        /// Travelling. Carries whatever is under the cursor so the orb can name
        /// it *before* the user commits — nil when that is nothing we can send to.
        case aiming(HandoffTarget?)
        case commit(HandoffTarget)
        case cancelled
    }

    /// How far the cursor must travel before a press stops being a click.
    ///
    /// macOS's own 3pt drag threshold is too eager here: a click that sends the
    /// brief to whatever is behind the orb is much worse than a fling that has
    /// to be restarted.
    public let travelThreshold: Double

    /// Whether the orb will accept a fling at all. False while the pipeline is
    /// still working — there is no brief to send yet, so the press should not
    /// even arm.
    public var isArmed: Bool

    private enum State: Equatable {
        case idle
        /// Pressed, but still inside the threshold — could become either gesture.
        case pressed
        case flinging(HandoffTarget?)
    }
    private var state: State = .idle

    public init(travelThreshold: Double = 12, isArmed: Bool = false) {
        self.travelThreshold = travelThreshold
        self.isArmed = isArmed
    }

    /// True once the press has travelled far enough to be a fling. The orb reads
    /// this to ghost itself and get out of the way of the target.
    public var isFlinging: Bool {
        if case .flinging = state { return true }
        return false
    }

    public mutating func press() -> Decision {
        guard isArmed else { return .none }
        state = .pressed
        return .none
    }

    /// The cursor moved while the button is down.
    ///
    /// - Parameters:
    ///   - distance: how far from where the press started.
    ///   - overOrb: whether the cursor is back inside the orb's resting frame.
    ///   - target: what is under the cursor, already resolved.
    ///
    /// Crossing the threshold is one-way: reverting to `.pressed` would turn
    /// the release into `openOptions` in the middle of a fling.
    public mutating func drag(distance: Double, overOrb: Bool, target: HandoffTarget?) -> Decision {
        switch state {
        case .idle:
            return .none
        case .pressed:
            guard distance >= travelThreshold else { return .none }
            state = .flinging(overOrb ? nil : target)
        case .flinging:
            state = .flinging(overOrb ? nil : target)
        }
        // Over the orb reads as no target, not as the app the orb happens to
        // be covering.
        return .aiming(overOrb ? nil : target)
    }

    public mutating func release() -> Decision {
        defer { state = .idle }
        switch state {
        case .idle:
            return .none
        case .pressed:
            return .openOptions
        case .flinging(let target):
            guard let target else { return .cancelled }
            return .commit(target)
        }
    }

    /// Escape during a fling. Also the path for anything that invalidates the
    /// gesture mid-flight — the window closing, the session being extended.
    public mutating func cancel() -> Decision {
        let wasActive = state != .idle
        state = .idle
        return wasActive ? .cancelled : .none
    }
}
