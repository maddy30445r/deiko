import Testing
@testable import DeikoHandoff

// The fling is the approval step — a wrong decision here sends a brief to the
// wrong app, or sends nothing while looking like it did. Every case below is a
// gesture a user can actually make with the orb.

private let iterm = HandoffTarget(pid: 100, appName: "iTerm2")
private let code = HandoffTarget(pid: 200, appName: "Code")

private func armed() -> FlingGesture {
    FlingGesture(isArmed: true)
}

// ── Click vs fling ──────────────────────────────────────────────────────────

@Test("press and release without travel opens the options")
func clickOpensOptions() {
    var g = armed()
    #expect(g.press() == .none)
    #expect(g.release() == .openOptions)
}

@Test("travel under the threshold is still a click")
func shortTravelIsAClick() {
    var g = armed()
    _ = g.press()
    #expect(g.drag(distance: 11, overOrb: false, target: iterm) == .none)
    #expect(g.release() == .openOptions)
}

@Test("travel past the threshold becomes a fling")
func longTravelIsAFling() {
    var g = armed()
    _ = g.press()
    #expect(g.drag(distance: 12, overOrb: false, target: iterm) == .aiming(iterm))
    #expect(g.release() == .commit(iterm))
}

// ── While the pipeline is still working ─────────────────────────────────────

@Test("an unarmed orb ignores the whole gesture — there is no brief to send yet")
func unarmedPressDoesNothing() {
    var g = FlingGesture(isArmed: false)
    #expect(g.press() == .none)
    #expect(g.drag(distance: 100, overOrb: false, target: iterm) == .none)
    #expect(g.release() == .none)
}

// ── Aiming ──────────────────────────────────────────────────────────────────

@Test("aiming tracks the target under the cursor, and the last one wins")
func aimingTracksTheTarget() {
    var g = armed()
    _ = g.press()
    #expect(g.drag(distance: 40, overOrb: false, target: iterm) == .aiming(iterm))
    #expect(g.drag(distance: 60, overOrb: false, target: code) == .aiming(code))
    #expect(g.release() == .commit(code))
}

@Test("releasing over nothing cancels rather than guessing")
func releaseOverNothingCancels() {
    var g = armed()
    _ = g.press()
    #expect(g.drag(distance: 40, overOrb: false, target: nil) == .aiming(nil))
    #expect(g.release() == .cancelled)
}

@Test("release back over the orb cancels — the app it covers is not the target")
func releaseOverTheOrbCancels() {
    var g = armed()
    _ = g.press()
    _ = g.drag(distance: 40, overOrb: false, target: iterm)
    // Dragged out and brought back home. The window underneath the orb is NOT
    // what the user meant — the orb is always covering something.
    #expect(g.drag(distance: 5, overOrb: true, target: code) == .aiming(nil))
    #expect(g.release() == .cancelled)
}

@Test("a fling that wanders home stays a fling — release must not pop the options")
func flingThatWandersHomeStaysAFling() {
    var g = armed()
    _ = g.press()
    _ = g.drag(distance: 40, overOrb: false, target: iterm)
    // Back within the click threshold, but the gesture crossed it once.
    _ = g.drag(distance: 3, overOrb: true, target: nil)
    #expect(g.isFlinging)
    #expect(g.release() == .cancelled)
}

// ── Escape ──────────────────────────────────────────────────────────────────

@Test("escape cancels a fling, and the next press starts fresh")
func escapeCancels() {
    var g = armed()
    _ = g.press()
    _ = g.drag(distance: 40, overOrb: false, target: iterm)
    #expect(g.cancel() == .cancelled)
    #expect(g.release() == .none)

    _ = g.press()
    #expect(g.release() == .openOptions)
}

@Test("escape when idle is silent")
func escapeWhenIdleIsSilent() {
    var g = armed()
    #expect(g.cancel() == .none)
}

// ── Target resolution ───────────────────────────────────────────────────────

@Test("Deiko itself is never a target")
func resolveRefusesDeiko() {
    #expect(HandoffTarget.resolve(pid: 42, appName: "Deiko", ownPid: 42) == nil)
}

@Test("the nameless and the absent are never targets — the user could not verify them")
func resolveRefusesTheNameless() {
    #expect(HandoffTarget.resolve(pid: nil, appName: "iTerm2", ownPid: 1) == nil)
    #expect(HandoffTarget.resolve(pid: 7, appName: nil, ownPid: 1) == nil)
    #expect(HandoffTarget.resolve(pid: 7, appName: "", ownPid: 1) == nil)
}

@Test("any other named app resolves — the orb's label is the guard, not an allowlist")
func resolveAcceptsAnyOtherNamedApp() {
    #expect(
        HandoffTarget.resolve(pid: 7, appName: "iTerm2", ownPid: 1)
            == HandoffTarget(pid: 7, appName: "iTerm2")
    )
}

// ── The drop point ──────────────────────────────────────────────────────────

@Test("a target carries no drop point until one is pinned to it")
func targetsStartWithoutADropPoint() {
    #expect(HandoffTarget.resolve(pid: 7, appName: "Code", ownPid: 1)?.dropPoint == nil)
}

@Test("pinning a drop point keeps the identity the user was shown")
func droppedKeepsIdentity() {
    let named = HandoffTarget(pid: 7, appName: "Code")
    let pinned = named.dropped(atX: 120, y: 340)

    // The pid is what `deliver` activates and what the pre-click re-resolve
    // compares against — pinning a point must not disturb either, or the
    // guard would be checking a different app than the one on the label.
    #expect(pinned.pid == named.pid)
    #expect(pinned.appName == named.appName)
    #expect(pinned.dropPoint?.x == 120)
    #expect(pinned.dropPoint?.y == 340)
}

@Test("two drops of the same app at different points are not the same target")
func dropPointParticipatesInEquality() {
    let a = HandoffTarget(pid: 7, appName: "Code").dropped(atX: 10, y: 10)
    let b = HandoffTarget(pid: 7, appName: "Code").dropped(atX: 900, y: 10)
    #expect(a != b)
}
