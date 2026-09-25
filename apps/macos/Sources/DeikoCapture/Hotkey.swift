import AppKit
import CoreGraphics
import Foundation
import DeikoGesture

// ─────────────────────────────────────────────────────────────────────────────
// TWO KEYS, ONE JOB EACH
//
//   double-tap Right Option   → start capturing
//   tap Right Option          → stop
//   hold Left Option + move   → draw a stroke (lasso, arrow, scribble)
//
// THEY USED TO BE THE SAME KEY, told apart by whether a drag happened during
// the press. That distinction is invisible — the user has to feel it — and it
// shipped a bug where the second tap of a double-tap locked the session and
// its own release stopped it again. Two keys, no discrimination, no bug.
//
// There is no "hold to capture" mode either. It existed for a ten-second
// capture, and nobody describes a task worth planning in ten seconds.
//
// NOTHING IS SWALLOWED. Drawing used to be Left Option + a button drag, and
// that drag had to be eaten so it would not select text or move a row in the
// app underneath — which also ate every Option+click for the whole session.
// The stroke is now Left Option + plain movement: no button is involved, so
// there is nothing to eat, and mid-flow you can click Submit, hold Left Option,
// scribble, let go and click Edit with every click landing.
//
// This file only reports the key going down and up; the path comes from the
// Recorder's own 60Hz cursor samples. `mouseMoved` is deliberately not in the
// monitors' mask — they are always on, and that would put every mouse move on
// the machine through this callback, session or not.
//
// MONITORS, NOT A TAP. This was an active `CGEvent` tap on the main run loop:
// every modifier press and every scroll on the Mac waited for Deiko's main
// thread to hand it back, so a busy Deiko put a hitch in everybody's
// scrolling. `NSEvent` monitors observe the same events after they are
// delivered — nothing waits on Deiko — and need the same Accessibility grant.
// A global monitor sees other apps' events, a local one Deiko's own.
// ───────────────────────────────────────────────────────────────────────────────

/// WHICH KEY STARTS A SESSION — the user's choice, read live.
///
/// It was Right Option, hardcoded, and on most non-US layouts that key is
/// AltGr: the modifier that types `@ # [ ] { } |`. A double tap inside 350ms
/// starts a recording, so typing an array literal could open a session, and
/// nothing named the key or let anybody change it. `SessionKey` (in
/// `DeikoGesture`, so its table is unit-tested) holds the four right-hand
/// modifiers and their per-key device bits; Left Option stays the drawing key
/// and is never a candidate.
///
/// Read on every modifier event rather than cached: `UserDefaults` is backed by
/// CFPreferences, which caches in-process, so this costs nothing measurable and
/// buys a setting that takes effect the moment it is changed — no relaunch, no
/// observer, no second copy of the value to fall out of step.
extension SessionKey {
    static let defaultsKey = "DEIKO_SESSION_KEY"

    static var selected: SessionKey {
        get {
            SessionKey(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
                ?? .fallback
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Left Option — the drawing key. Keycode and device bit, same reasoning as
/// above: `.maskAlternate` cannot tell the two Option keys apart.
private let kLeftOptionKeyCode: Int64 = 58
private let kLeftOptionFlagMask: UInt64 = 0x20

/// Intent, not mechanics. The double-tap timing lives in `SessionGesture`, so
/// the Recorder never reasons about presses or windows.
enum HotkeyEvent {
    case recordingStarted
    case recordingStopped
    /// Left Option pressed / released during a session. See the file header.
    case drawKeyDown(Point)
    case drawKeyUp(Point)
    case scrolled
}

/// Main-actor isolated, and legitimately so: `NSEvent` monitors call back on
/// the main thread. Declaring that lets the overlay be touched directly from a
/// gesture instead of hopping queues for no reason.
@MainActor
final class Hotkey {
    private var monitors: [Any] = []


    /// What a Right Option press MEANS lives in `SessionGesture`, which has no
    /// CGEvent dependency and is unit-tested. This class is only plumbing.
    private var gesture = SessionGesture()

    /// Left Option, tracked separately — it draws, and draws only.
    private var isLeftOptionDown = false

    /// Set between `.recordingStarted` and `.recordingStopped`. Gates the
    /// drawing key: with no session, Left Option is nobody's business but the
    /// user's.
    private var isSessionActive = false

    /// Called on the main run loop for every gesture transition.
    var onEvent: ((HotkeyEvent) -> Void)?

    /// Starts listening. Returns false when the process isn't trusted for
    /// Accessibility: without it a global monitor gets no key events at all.
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .scrollWheel]
        // The CGEvent behind each: the same device bits and the same
        // top-left-origin location the gesture code has always read.
        let observe: (NSEvent) -> Void = { [weak self] event in
            guard let self, let cgEvent = event.cgEvent else { return }
            handle(type: cgEvent.type, event: cgEvent)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: observe) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { observe($0); return $0 }) { monitors.append(local) }
        return true
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // ── Event handling ──────────────────────────────────────────────────────

    private func handle(type: CGEventType, event: CGEvent) {
        let location = Point(x: event.location.x, y: event.location.y)

        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let sessionKey = SessionKey.selected
            if keyCode == sessionKey.keyCode {
                // The DEVICE bit, not the combined mask — see `SessionKey`.
                // Only the press means anything; a release carries no meaning
                // now that there is no held mode.
                if event.flags.rawValue & sessionKey.deviceMask != 0 {
                    apply(gesture.press(at: Clock.nowMs()))
                }
            } else if keyCode == kLeftOptionKeyCode {
                let wasDown = isLeftOptionDown
                isLeftOptionDown = event.flags.rawValue & kLeftOptionFlagMask != 0
                // Edges only: other modifiers changing while Option is held
                // also arrive here with its keycode on some keyboards.
                if isLeftOptionDown != wasDown, isSessionActive {
                    emit(isLeftOptionDown ? .drawKeyDown(location) : .drawKeyUp(location))
                }
            }
            return

        case .scrollWheel:
            // Not swallowed: scrolling to reach the thing you want to point at
            // is legitimate mid-session. Recorded because a "settle" while the
            // content moves underneath is not a pointing act, and the aligner
            // needs to know that. Reported unconditionally now — the modifier
            // no longer bounds the session, so the Recorder decides whether it
            // is currently interested.
            emit(.scrolled)
            return

        default:
            return
        }
    }

    /// Called by the Recorder when a session ends by any route other than a
    /// tap — a watchdog, or Quit. Keeps the drawing-key gate honest.
    func noteSessionEnded() {
        isSessionActive = false
        gesture.sessionEndedExternally()
    }

    /// Called by the Recorder when a session starts by any route other than a
    /// tap — today, "Forgot something?" reopening a finished session.
    ///
    /// `isSessionActive` is what makes holding Left Option mean "draw a stroke".
    /// Setting it here is what
    /// lets you circle something in the extra hold, exactly as in the first.
    func noteSessionStarted() {
        isSessionActive = true
        gesture.sessionStartedExternally()
    }

    // ── Plumbing onto the tested state machine ──────────────────────────────

    private func apply(_ decision: SessionGesture.Decision) {
        switch decision {
        case .none:
            break
        case .start:
            isSessionActive = true
            emit(.recordingStarted)
        case .stopNow:
            isSessionActive = false
            emit(.recordingStopped)
        }
    }

    /// Deliver on the next main-queue turn, NOT inline. The tap callback must
    /// return fast — the system disables a tap whose callback dawdles — and
    /// `.pressed` triggers real work: directory creation, AVAudioEngine start,
    /// the Chromium pre-poke (two AX calls with 250ms timeouts each), overlay
    /// window creation. Inline, a slow disk or busy Electron app could kill
    /// the tap mid-session. The swallow decision above stays synchronous; only
    /// the reaction is deferred. `DispatchQueue.main` is FIFO, so gesture
    /// ordering is preserved exactly.
    private func emit(_ event: HotkeyEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onEvent?(event) }
        }
    }
}
