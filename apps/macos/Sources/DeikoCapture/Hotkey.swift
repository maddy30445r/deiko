import AppKit
import CoreGraphics
import Foundation
import DeikoGesture

// Two keys, one job each:
//
//   double-tap the session key (Right Option by default)  → start capturing
//   tap the session key                                    → stop
//   hold Left Option + move                                → draw a stroke (lasso, arrow, scribble)
//
// This file only reports the key going down and up; the stroke path comes from
// the Recorder's own 60Hz cursor samples. `mouseMoved` is deliberately not in
// the monitors' mask: they are always on, and it would route every mouse move
// on the machine through this callback.
//
// The stroke needs no mouse button, so no event is swallowed and clicks land
// normally mid-stroke.
//
// `NSEvent` monitors, not an active `CGEvent` tap: a tap makes every modifier
// press and scroll on the Mac wait for Deiko's main thread. Monitors observe
// the same events after delivery and need the same Accessibility grant. A
// global monitor sees other apps' events, a local one Deiko's own.

/// The key that starts a session, chosen by the user and read live.
///
/// Configurable because on many non-US layouts Right Option is AltGr, which
/// types `@ # [ ] { } |`. `SessionKey` (in `DeikoGesture`, so its table is
/// unit-tested) holds the four right-hand modifiers and their per-key device
/// bits; Left Option stays the drawing key and is never a candidate.
///
/// Read on every modifier event rather than cached: `UserDefaults` caches
/// in-process, so a change takes effect at once with no observer or second copy.
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

/// Left Option, the drawing key. Keycode and device bit: `.maskAlternate`
/// cannot tell the two Option keys apart.
private let kLeftOptionKeyCode: Int64 = 58
private let kLeftOptionFlagMask: UInt64 = 0x20

/// Intent, not mechanics. The double-tap timing lives in `SessionGesture`, so
/// the Recorder never reasons about presses or windows.
enum HotkeyEvent {
    case recordingStarted
    case recordingStopped
    case drawKeyDown(Point)
    case drawKeyUp(Point)
    case scrolled
}

/// Main-actor isolated: `NSEvent` monitors call back on the main thread, so the
/// overlay can be touched directly from a gesture.
@MainActor
final class Hotkey {
    private var monitors: [Any] = []


    /// What a session-key press means lives in `SessionGesture`, which has no
    /// CGEvent dependency and is unit-tested. This class is only plumbing.
    private var gesture = SessionGesture()

    /// Left Option, tracked separately: it only draws.
    private var isLeftOptionDown = false

    /// Set between `.recordingStarted` and `.recordingStopped`. Gates the
    /// drawing key: with no session, Left Option is left alone.
    private var isSessionActive = false

    /// Called on the main run loop for every gesture transition.
    var onEvent: ((HotkeyEvent) -> Void)?

    /// Starts listening. Returns false when the process isn't trusted for
    /// Accessibility: without it a global monitor gets no key events at all.
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .scrollWheel]
        // The CGEvent behind each, for the device bits and the top-left-origin
        // location the gesture code reads.
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

    private func handle(type: CGEventType, event: CGEvent) {
        let location = Point(x: event.location.x, y: event.location.y)

        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let sessionKey = SessionKey.selected
            if keyCode == sessionKey.keyCode {
                // The device bit, not the combined mask; see `SessionKey`. Only
                // the press means anything.
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
            // Not swallowed: scrolling to reach the target is legitimate
            // mid-session. Reported unconditionally so the aligner knows a
            // settle while content moves is not a pointing act; the Recorder
            // decides whether it is interested.
            emit(.scrolled)
            return

        default:
            return
        }
    }

    /// Called by the Recorder when a session ends by any route other than a
    /// tap (a watchdog, or Quit). Keeps the drawing-key gate honest.
    func noteSessionEnded() {
        isSessionActive = false
        gesture.sessionEndedExternally()
    }

    /// Called by the Recorder when a session starts by any route other than a
    /// tap, such as reopening a finished session. Sets `isSessionActive` so
    /// holding Left Option draws in the extra hold too.
    func noteSessionStarted() {
        isSessionActive = true
        gesture.sessionStartedExternally()
    }

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

    /// Delivers on the next main-queue turn, not inline. A gesture starts real
    /// work (directory creation, audio engine start, the Chromium pre-poke,
    /// overlay window creation) and the monitor callback must return fast.
    /// `DispatchQueue.main` is FIFO, so gesture ordering is preserved.
    private func emit(_ event: HotkeyEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onEvent?(event) }
        }
    }
}
