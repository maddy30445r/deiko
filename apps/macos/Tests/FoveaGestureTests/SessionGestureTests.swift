import Testing
@testable import FoveaGesture

// The gesture is the product's entire input surface: one key meaning capture,
// lock, and lasso. Every case below is a sequence a user can actually perform,
// and at least one of them shipped broken.

@Test("hold, talk, release — the quick path")
func quickHold() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .start)
    #expect(g.release(at: 900) == .stopAfterGrace)
    #expect(g.graceExpired() == .stopNow)
    #expect(!g.isCapturing)
}

@Test("double-tap locks, and does NOT stop on the second tap's own release")
func doubleTapLocks() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .start)
    #expect(g.release(at: 120) == .stopAfterGrace)
    #expect(g.press(at: 200) == .lock)          // within the 350ms window
    // The bug: this release used to be read as "a tap while locked" and
    // stopped the session milliseconds after locking it.
    #expect(g.release(at: 260) == .none)
    #expect(g.isCapturing && g.isLocked)
}

@Test("the scheduled stop is cancelled by the promotion, so capture never pauses")
func promotionCancelsTheStop() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    _ = g.press(at: 180)
    // The grace timer still fires — it was scheduled before the second press —
    // and must now be inert, or it would stop a session the user just locked.
    #expect(g.graceExpired() == .none)
    #expect(g.isCapturing)
}

@Test("a tap while locked stops the session")
func tapWhileLockedStops() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    _ = g.press(at: 180)
    _ = g.release(at: 240)

    #expect(g.press(at: 5000) == .none)         // locked: the press decides nothing
    #expect(g.release(at: 5080) == .stopNow)
    #expect(!g.isCapturing && !g.isLocked)
}

@Test("a slow second press is a new session, not a promotion")
func slowSecondPressDoesNotLock() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    #expect(g.graceExpired() == .stopNow)
    #expect(g.press(at: 2000) == .start)        // far outside the window
    #expect(!g.isLocked)
}

@Test("a lasso is not half of a double-tap")
func lassoDoesNotArmPromotion() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    g.dragStarted()
    #expect(g.release(at: 900) == .stopAfterGrace)
    // Pressing again quickly must NOT lock: the previous release finished a
    // drawing, and treating it as a tap would promote sessions by accident
    // every time someone drew two regions in quick succession.
    #expect(g.press(at: 1000) == .none)
    #expect(!g.isLocked)
}

@Test("a lasso while locked leaves the session running")
func lassoWhileLockedKeepsGoing() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.release(at: 100)
    _ = g.press(at: 180)
    _ = g.release(at: 240)

    _ = g.press(at: 4000)
    g.dragStarted()
    #expect(g.release(at: 4600) == .none)
    #expect(g.isCapturing && g.isLocked)
}

@Test("a release lost to a disabled tap ends a held session but not a locked one")
func tapRecovery() {
    var held = SessionGesture()
    _ = held.press(at: 0)
    #expect(held.tapRecovered(modifierStillDown: false) == .stopNow)

    var locked = SessionGesture()
    _ = locked.press(at: 0)
    _ = locked.release(at: 100)
    _ = locked.press(at: 180)
    _ = locked.release(at: 240)
    #expect(locked.tapRecovered(modifierStillDown: false) == .none)
    #expect(locked.isCapturing)
}
