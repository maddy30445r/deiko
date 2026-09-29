/// What a fling can land on: an app, named before the user commits.
///
/// There is deliberately no allowlist of terminal bundle ids deciding what is a
/// "Claude Code window": the orb showing the app name before release is the
/// guard. The one exclusion is Deiko itself.
public struct HandoffTarget: Equatable, Sendable {
    /// Process id of the app under the cursor — what `activate()` needs.
    public let pid: Int32
    /// The app's visible name, shown on the orb while aiming.
    public let appName: String

    /// Where the fling was released, in CG global coordinates (top-left origin).
    /// Nil when the target was not chosen by pointing.
    ///
    /// Activating an app restores focus to whatever widget had it last, which
    /// may be nowhere near the drop, so the handoff clicks this point first and
    /// types second.
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
    ///   - ownPid: Deiko's own pid. Deiko's overlay or windows under the
    ///     cursor must read as "nowhere", not as a target.
    public static func resolve(pid: Int32?, appName: String?, ownPid: Int32) -> HandoffTarget? {
        guard let pid, pid != ownPid else { return nil }
        // A window with no nameable owner cannot be verified before committing.
        guard let appName, !appName.isEmpty else { return nil }
        return HandoffTarget(pid: pid, appName: appName)
    }

    /// The same target, pinned to the point where the fling ended.
    public func dropped(atX x: Double, y: Double) -> HandoffTarget {
        HandoffTarget(pid: pid, appName: appName, dropPoint: (x, y))
    }
}