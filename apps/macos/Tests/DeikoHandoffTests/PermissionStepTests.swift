import Testing
@testable import DeikoHandoff

// The whole table, so that one click means one action.

@Test("a first click prompts, and does not open Settings behind the prompt")
func firstClickPrompts() {
    // The failure being pinned: a system alert appeared and System Settings
    // opened behind it before either was answered. The alert does not close
    // when the permission is granted elsewhere.
    #expect(PermissionStep.next(granted: false, asked: false) == .request)
}

@Test("a second click goes to Settings, and does not stack another prompt")
func secondClickOpensSettings() {
    // `AXIsProcessTrustedWithOptions(prompt:)` re-shows its alert on every call
    // while untrusted, and a denied Microphone prompt never returns, so
    // requesting twice helps nobody.
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
    // Load-bearing: macOS does not list an app in a privacy pane until it has
    // requested, so an unasked, ungranted permission must never route straight
    // to a pane it is not listed in.
    #expect(PermissionStep.next(granted: false, asked: false) != .openSettings)
}
