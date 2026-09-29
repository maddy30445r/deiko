import Testing
@testable import DeikoGesture

// Each case is a gesture a user can actually perform; the CGEvent tap that
// feeds it cannot be driven by tests.

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
    // Re-armed from the last tap, so a prompt third one still pairs.
    #expect(g.press(at: 1100) == .start)
}

@Test("the window is measured press to press, so holding the first tap does not arm the second")
func heldFirstTapDoesNotPair() {
    var g = SessionGesture()
    #expect(g.press(at: 0) == .none)
    // Held for two seconds, then tapped again promptly: press-to-press is
    // 2100ms, so these are two unrelated taps.
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

    // A lone tap must not start a session because the stop left `armedAt` set.
    #expect(g.press(at: 5100) == .none)
    #expect(!g.isCapturing)
}

@Test("a watchdog stop leaves the gesture idle, not stale")
func externalStopResets() {
    var g = SessionGesture()
    _ = g.press(at: 0)
    _ = g.press(at: 200)
    #expect(g.isCapturing)

    // The silence watchdog fired. The next tap must not be spent stopping a
    // session that already ended.
    g.sessionEndedExternally()
    #expect(!g.isCapturing)

    #expect(g.press(at: 9000) == .none)      // arms, does not stop
    #expect(g.press(at: 9150) == .start)     // and a double-tap starts cleanly
}

@Test("a session started from a button stops on the next single tap")
func externalStartStopsOnOneTap() {
    var g = SessionGesture()

    // Reopened from a button: nobody tapped, so the gesture must be told.
    g.sessionStartedExternally()
    #expect(g.isCapturing)

    // The tap made to stop must stop. Read as idle it would arm a double-tap
    // and leave the microphone live.
    #expect(g.press(at: 1000) == .stopNow)
    #expect(!g.isCapturing)
}

@Test("a button start clears a half-finished double-tap")
func externalStartDiscardsArmedTap() {
    var g = SessionGesture()

    // One tap lands, then the button is pressed instead. The stale armed tap
    // must not pair with the stop tap into a double-tap to start.
    _ = g.press(at: 0)
    g.sessionStartedExternally()

    #expect(g.press(at: 100) == .stopNow)
}
