import Testing
@testable import DeikoHandoff

// The whole table, because the bug was a missing branch rather than a wrong
// one: `ask()` did BOTH things on every click, so there was no table to get
// wrong. These pin that one click now means one action.

@Test("a first click prompts, and does not open Settings behind the prompt")
func firstClickPrompts() {
    // The reported failure: a system alert appeared AND System Settings opened
    // behind it, before the user had answered either. The alert belongs to the
    // system, so it did not close when the permission was granted elsewhere —
    // it sat through the grant and only quitting Deiko cleared it.
    #expect(PermissionStep.next(granted: false, asked: false) == .request)
}

@Test("a second click goes to Settings, and does not stack another prompt")
func secondClickOpensSettings() {
    // `AXIsProcessTrustedWithOptions(prompt:)` re-shows its alert every time it
    // is called while untrusted, and a denied Microphone prompt never comes
    // back at all. Either way, requesting twice helps nobody.
    #expect(PermissionStep.next(granted: false, asked: true) == .openSettings)
}

@Test("a granted permission does nothing at all")
func grantedDoesNothing() {
    // Both spellings: the flag is only meaningful while something is missing.
    #expect(PermissionStep.next(granted: true, asked: true) == .nothing)
    #expect(PermissionStep.next(granted: true, asked: false) == .nothing)
}

@Test("the first click always requests, whatever else is true")
func requestingIsNeverSkipped() {
    // Load-bearing, and the reason `.request` survives rather than being
    // replaced by a Settings link: macOS does not list an app in a privacy pane
    // until it has requested, and Deiko was once absent from the Microphone
    // list entirely for exactly that reason. An unasked, ungranted permission
    // must never route straight to a pane it is not listed in.
    #expect(PermissionStep.next(granted: false, asked: false) != .openSettings)
}
