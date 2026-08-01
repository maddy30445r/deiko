/// What a fling can land on: an app, named before the user commits.
///
/// The name is the safety property. There is deliberately no allowlist of
/// terminal bundle ids deciding what counts as "a Claude Code window" — any
/// such list is stale the day a new terminal ships, and the orb showing
/// "→ iTerm2" *before* release is a better guard than a list the user never
/// sees. The one exclusion is Fovea itself, which is not a place a brief can go.
public struct HandoffTarget: Equatable, Sendable {
    /// Process id of the app under the cursor — what `activate()` needs.
    public let pid: Int32
    /// The app's visible name, shown on the orb while aiming.
    public let appName: String

    /// Where the fling was RELEASED, in CG global coordinates (top-left
    /// origin). Nil when the target was not chosen by pointing — `handoff-test`
    /// names an app, it does not aim at a pixel.
    ///
    /// This exists because activating an app restores focus to whatever widget
    /// had it last, which is not necessarily anywhere near where the user
    /// dropped. The first live fling proved it: the paste went to VS Code, and
    /// VS Code put it wherever its focus happened to be — nothing visible
    /// anywhere. The drop point is the one place the user has *actually
    /// pointed at*, so the handoff clicks it first and types second — the same
    /// order a human uses.
    public let dropPoint: (x: Double, y: Double)?

    public init(pid: Int32, appName: String, dropPoint: (x: Double, y: Double)? = nil) {
        self.pid = pid
        self.appName = appName
        self.dropPoint = dropPoint
    }

    public static func == (lhs: HandoffTarget, rhs: HandoffTarget) -> Bool {
        lhs.pid == rhs.pid && lhs.appName == rhs.appName
            && lhs.dropPoint?.x == rhs.dropPoint?.x && lhs.dropPoint?.y == rhs.dropPoint?.y
    }

    /// Decide whether an app under the cursor is somewhere a brief can land.
    ///
    /// - Parameters:
    ///   - pid: owner of the window under the cursor, if any.
    ///   - appName: its visible name, if any.
    ///   - ownPid: Fovea's own pid — flinging the orb onto Fovea's own surfaces
    ///     (the orb itself is excluded upstream, but the overlay or a Fovea
    ///     window may be underneath) must read as "nowhere", not as a target.
    public static func resolve(pid: Int32?, appName: String?, ownPid: Int32) -> HandoffTarget? {
        guard let pid, pid != ownPid else { return nil }
        // A window with no nameable owner is not a place the user can verify
        // before committing, so it is not a place we send to.
        guard let appName, !appName.isEmpty else { return nil }
        return HandoffTarget(pid: pid, appName: appName)
    }

    /// The same target, pinned to the point where the fling ended.
    public func dropped(atX x: Double, y: Double) -> HandoffTarget {
        HandoffTarget(pid: pid, appName: appName, dropPoint: (x, y))
    }
}