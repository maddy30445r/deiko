import Foundation

/// What one click on "Grant" does: exactly one action.
///
/// - Never asked: request. The system dialog appears. Microphone and Speech are
///   granted by it outright; Accessibility and Screen Recording carry their own
///   "Open System Settings" button. Requesting must still happen once, because
///   macOS does not list an app in a privacy pane until it has requested.
/// - Asked already: open Settings. A denied permission's dialog does not
///   reappear, and re-requesting Accessibility stacks a second alert.
/// - Granted: nothing.
///
/// Requesting and opening Settings must not be combined: the
/// `AXIsProcessTrustedWithOptions(prompt:)` and `CGRequestScreenCaptureAccess()`
/// calls return the status as it was rather than waiting, so a "not granted"
/// guard after them always passes, and the system alert (which does not close
/// when the permission is granted elsewhere) is left behind a Settings window.
///
/// Lives here because `Permission` is in the executable target, which cannot be
/// linked into a test binary; the decision is a pure function of two booleans.
public enum PermissionStep: Equatable, Sendable {
    /// Show the system's own dialog. Registers the app with TCC, and for the
    /// two that cannot be granted from a dialog, offers the way to Settings.
    case request
    /// Open the privacy pane. For a permission whose dialog has been seen and
    /// will not come back.
    case openSettings
    /// Already granted — a click here is a no-op rather than another dialog.
    case nothing

    /// - Parameters:
    ///   - granted: whether the permission is held right now.
    ///   - asked: whether this install has ever requested it. For Microphone
    ///     and Speech this is `status != .notDetermined`, which the system
    ///     tracks; Accessibility and Screen Recording have no such state, so
    ///     the caller remembers it.
    public static func next(granted: Bool, asked: Bool) -> PermissionStep {
        if granted { return .nothing }
        return asked ? .openSettings : .request
    }
}
