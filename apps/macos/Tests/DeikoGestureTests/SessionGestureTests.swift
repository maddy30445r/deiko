import Testing
@testable import DeikoGesture

// Right Option is the product's entire session control, and it cannot be tested
// by hand except by performing gestures. Every case below is one a user can
// actually do; the previous version of this logic shipped a bug that none of
// them would have survived.

@Test("a single tap does nothing — it only arms")
func singleTapDoesNothing() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    #expect(!g.isCapturing)
}

@Test("a double-tap starts capturing")
func doubleTapStarts() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    #expect(g.press(at: 200) == .start)
    #expect(g.isCapturing)
}

@Test("a second tap outside the window does not start — it re-arms")
func slowSecondTapDoesNotStart() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    #expect(g.press(at: 900) == .none)
    #expect(!g.isCapturing)
    // Re-armed from the LAST tap, so a prompt third one still pairs. Discarding
    // instead would make a slow-then-fast triple tap do nothing at all.
    #expect(g.press(at: 1100) == .start)
}

@Test("the window is measured press to press, so holding the first tap does not arm the second")
func heldFirstTapDoesNotPair() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    // Key held down for two seconds, then tapped again promptly. Press-to-press
    // is 2100ms, so this is two unrelated taps, not a double-tap.
    #expect(g.press(at: 2100) == .none)
    #expect(!g.isCapturing)
}

@Test("a single tap while capturing stops")
func tapWhileCapturingStops() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)
    #expect(g.isCapturing)

    #expect(g.press(at: 9000) == .stopNow)
    #expect(!g.isCapturing)
}

@Test("a double-tap while capturing stops on the first press and no more")
func doubleTapWhileCapturingJustStops() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)

    #expect(g.press(at: 5000) == .stopNow)
    // The second half of the habit lands in idle and merely arms.
    #expect(g.press(at: 5150) == .none)
    #expect(!g.isCapturing)
}

@Test("a fast triple tap while capturing ends up capturing again")
func tripleTapRestarts() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)

    #expect(g.press(at: 5000) == .stopNow)   // stop
    #expect(g.press(at: 5100) == .none)      // arm
    #expect(g.press(at: 5200) == .start)     // start a new session
    #expect(g.isCapturing)
}

@Test("stopping never leaves a half-armed double-tap behind")
func stopClearsTheArmedWindow() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)
    _ = g.press(at: 5000)                    // stop, clearing the window

    // If the stop had left `armedAt` set, this lone tap would start a session
    // the user never asked for.
    #expect(g.press(at: 5100) == .none)
    #expect(!g.isCapturing)
}

@Test("a tap lost to a disabled event tap cannot complete a double-tap")
func tapRecoveryDisarms() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    g.tapRecovered()
    // Presses went unobserved, so the armed half is no longer trustworthy.
    #expect(g.press(at: 100) == .none)
    #expect(!g.isCapturing)
}

@Test("a live session survives a tap hiccup")
func tapRecoveryKeepsCapturing() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)
    g.tapRecovered()
    // No held mode means no stranded state, and a session the user started
    // should not vanish because the OS restarted our tap.
    #expect(g.isCapturing)
    #expect(g.press(at: 3000) == .stopNow)
}

@Test("a watchdog stop leaves the gesture idle, not stale")
func externalStopResets() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)
    #expect(g.isCapturing)

    // The silence watchdog fired. Without this, the next tap would be spent
    // "stopping" a session that already ended — and Hotkey would go on
    // swallowing Option-drags with nothing recording.
    g.sessionEndedExternally()
    #expect(!g.isCapturing)

    #expect(g.press(at: 9000) == .none)      // arms, does not stop
    #expect(g.press(at: 9150) == .start)     // and a double-tap starts cleanly
}

@Test("a session started from a button stops on the next single tap")
func externalStartStopsOnOneTap() {
    var g = SessionGesture()

    // "Forgot something?" reopened a finished session and began another hold.
    // Nobody tapped anything, so without being told, the gesture still believes
    // it is idle.
    g.sessionStartedExternally()
    #expect(g.isCapturing)

    // The tap the user makes to stop must STOP. Read as idle, this would arm the
    // first half of a double-tap instead, and the microphone would stay live on
    // a session they believe they just closed.
    #expect(g.press(at: 1000) == .stopNow)
    #expect(!g.isCapturing)
}

@Test("a button start clears a half-finished double-tap")
func externalStartDiscardsArmedTap() {
    var g = SessionGesture()

    // One tap lands — the user reaching for the hotkey — and then they press the
    // button instead. The stale armed tap must not survive: paired with their
    // stop tap it would read as a double-tap to start, restarting capture on a
    // session that was being closed.
    _ = g.press(at: 0)
    g.sessionStartedExternally()

    #expect(g.press(at: 100) == .stopNow)
}
