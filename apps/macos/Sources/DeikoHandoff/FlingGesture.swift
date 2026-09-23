/// THE FLING, as pure logic.
///
/// The orb is the last step of a session: press it, drag it onto the window
/// running Claude Code, let go, and the brief lands in that live session.
///
///   click (no travel)  → open the options
///   drag and release   → hand the brief to whatever is under the cursor
///   release on the orb → cancelled
///   Escape             → cancelled
///
/// **This is deliberately not an `NSDraggingSession`** — with one measured
/// exception, added later and gated to it.
///
/// A real drag needs the destination to accept a pasteboard type, and a
/// terminal accepts none: the cursor would show a rejection badge over the
/// exact window we mean to hit. A fling asks the destination for nothing; it
/// is a way of *pointing*, and the app underneath never learns it happened.
/// That is still how every fling begins, and the only way one ever ends
/// anywhere but a browser.
///
/// THE EXCEPTION: a chat composer attaches a file that is DROPPED on it and
/// ignores the same file pasted (measured on Gemini; a drop works on Claude.ai,
/// ChatGPT and Gemini alike). So when — and only when — a fling is over a
/// BROWSER and the session has a persona file, `OrbController` upgrades it to
/// a real drag mid-flight, which is precisely the case where the destination
/// does accept the type and no rejection badge appears. Everything else keeps
/// the pointing gesture this file describes. See `upgradeToSystemDrag`.
///
/// Lives apart from the orb for the same reason `SessionGesture` lives apart
/// from `Hotkey`: everything that resolves what is under the cursor needs a
/// window server and a running app to point at, so none of it can be tested.
/// Distance arrives as a scalar and the target arrives already resolved, which
/// leaves this file with only the decisions in it.
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
    /// macOS's own drag threshold is 3pt for text selection, which is far too
    /// eager here: the two gestures do completely different things, and a click
    /// that accidentally sends the brief to whatever is behind the orb is much
    /// worse than a fling that has to be started again.
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
    /// Crossing the threshold is one-way. A fling that wanders back within 12pt
    /// of its origin is still a fling — reverting to `.pressed` would turn the
    /// release into `openOptions`, popping the panel open in the middle of a
    /// gesture that was clearly meant to send something.
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
        // Over the orb reads as no target, not as the app the orb happens to be
        // covering. The orb is always on top of *something*, and that something
        // is never what the user meant.
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
