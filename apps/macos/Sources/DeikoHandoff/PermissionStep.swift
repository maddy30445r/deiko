import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// WHAT ONE CLICK ON "GRANT" SHOULD ACTUALLY DO
//
// It used to do two things at once, and that is the whole bug. `Permission.ask`
// requested the permission AND opened System Settings, every time:
//
//     let granted = await … request { … }        // shows the system alert
//     guard !granted, let url = settingsURL else { return }
//     NSWorkspace.shared.open(url)               // …and opens Settings as well
//
// For Accessibility and Screen Recording that guard always passes, because
// `AXIsProcessTrustedWithOptions(prompt:)` and `CGRequestScreenCaptureAccess()`
// return the status AS IT WAS rather than waiting for an answer. So one click
// produced the system alert *and* a Settings window behind it, before the user
// had touched either. Worse, the alert belongs to the system: it does not close
// when the permission is granted somewhere else, so it sat there through the
// grant and outlived it — and quitting Deiko was what finally cleared it. That
// is the "I had to restart the app" in the report.
//
// The rule is one action per click:
//
//   never asked   → REQUEST. The system dialog appears. Microphone and Speech
//                   are granted by that dialog outright; Accessibility and
//                   Screen Recording carry their own "Open System Settings"
//                   button, so opening it ourselves only duplicates a window
//                   the user has not dismissed yet.
//   asked already → OPEN SETTINGS. The dialog will not reappear for a denied
//                   permission, and re-requesting Accessibility just stacks a
//                   second alert on the first. Sending them straight to the
//                   pane is the only thing left that helps.
//   granted       → NOTHING.
//
// Asking at least once still has to happen, and that is why `request` survives
// the first branch rather than being replaced by a Settings link: macOS does
// not list an app in a privacy pane until it has requested, and Deiko was once
// missing from the Microphone list entirely for exactly that reason.
//
// HERE, in DeikoHandoff, because `Permission` lives in the executable target,
// which cannot be linked into a test binary — `main.swift` is top-level code
// that would run the app. Same move as `SessionClaims`: the decision is a pure
// function of two booleans, so it can be a table anybody can check, while the
// TCC calls stay where they have to be.
// ─────────────────────────────────────────────────────────────────────────────

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
