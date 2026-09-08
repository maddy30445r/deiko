import AppKit
import CoreGraphics
import Foundation
import DeikoGesture

// ─────────────────────────────────────────────────────────────────────────────
// TWO KEYS, ONE JOB EACH
//
//   double-tap Right Option   → start capturing
//   tap Right Option          → stop
//   hold Left Option + drag   → lasso a region
//
// THEY USED TO BE THE SAME KEY, told apart by whether a drag happened during
// the press. That distinction is invisible — the user has to feel it — and it
// shipped a bug where the second tap of a double-tap locked the session and
// its own release stopped it again. Two keys, no discrimination, no bug.
//
// There is no "hold to capture" mode either. It existed for a ten-second
// capture, and nobody describes a task worth planning in ten seconds.
//
// The tap is ACTIVE, not listen-only, because the lasso has to be swallowed:
// dragging with the button down means "select text" in an editor and "drag
// this" in a table, so a drag that reached the app underneath would mangle
// whatever it was drawn around. It swallows ONLY while Left Option is down AND
// a session is running — with no session, Option-drag keeps doing whatever it
// does in your apps (box-select in an editor, duplicate in Finder), because
// Deiko has no business touching input it was not invited to.
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
    case dragBegan(Point)
    case dragMoved(Point)
    case dragEnded(Point)
    case scrolled
}

/// Main-actor isolated, and legitimately so: `start()` adds the tap's run loop
/// source to the CURRENT run loop, which is the main one, so the callback is
/// delivered on the main thread. Declaring that lets the overlay be touched
/// directly from a gesture instead of hopping queues for no reason.
@MainActor
final class Hotkey {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isDragging = false

    /// What a Right Option press MEANS lives in `SessionGesture`, which has no
    /// CGEvent dependency and is unit-tested. This class is only plumbing.
    private var gesture = SessionGesture()

    /// Left Option, tracked separately — it draws, and draws only.
    private var isLeftOptionDown = false

    /// Set between `.recordingStarted` and `.recordingStopped`. Gates the
    /// swallowing: no session, no interference with the user's mouse.
    private var isSessionActive = false

    /// Called on the main run loop for every gesture transition.
    var onEvent: ((HotkeyEvent) -> Void)?

    /// Starts the tap. Returns false when the process isn't trusted for
    /// Accessibility — an active tap requires it, and there is no partial mode.
    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // .defaultTap = may modify or swallow
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }

                // Both the tap object and the event cross into the closure as
                // raw pointers rather than as their real types: CGEvent isn't
                // Sendable, and pointers are. Nothing unsafe is happening — the
                // source lives on the main run loop (see the type's doc
                // comment), so this callback is already on the main actor and
                // `assumeIsolated` is asserting a fact, not hoping for one.
                let eventPointer = Unmanaged.passUnretained(event).toOpaque()
                let swallow: Bool = MainActor.assumeIsolated {
                    let hotkey = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
                    let cgEvent = Unmanaged<CGEvent>.fromOpaque(eventPointer)
                        .takeUnretainedValue()
                    return hotkey.handle(type: type, event: cgEvent)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // ── Tap callback ────────────────────────────────────────────────────────

    /// Returns whether to SWALLOW the event (true) or let it through (false).
    /// A bool rather than an `Unmanaged<CGEvent>?` so nothing non-Sendable has
    /// to cross back out of the main-actor hop in the callback.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that dawdles in its callback. Re-enable and
        // carry on rather than dying silently mid-session, then RECONCILE what
        // went unobserved: a half-finished double-tap can no longer be trusted,
        // and Left Option may have come up while we were deaf — which would
        // otherwise leave every drag swallowed forever.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            gesture.tapRecovered()
            let flags = CGEventSource.flagsState(.combinedSessionState)
            isLeftOptionDown = flags.rawValue & kLeftOptionFlagMask != 0
            if !isLeftOptionDown, isDragging {
                isDragging = false
                emit(.dragEnded(Point(x: event.location.x, y: event.location.y)))
            }
            return false
        }

        let pass = false
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
                isLeftOptionDown = event.flags.rawValue & kLeftOptionFlagMask != 0
                if !isLeftOptionDown, isDragging {
                    isDragging = false
                    emit(.dragEnded(location))
                }
            }
            // Always pass modifiers through: swallowing one would break Option
            // as a normal modifier everywhere else.
            return pass

        case .leftMouseDown:
            // `isSessionActive` is half the guard on purpose: with no session
            // running, an Option-drag is the user's own gesture and must reach
            // their app untouched.
            guard isLeftOptionDown, isSessionActive else { return pass }
            isDragging = true
            emit(.dragBegan(location))
            return true                     // swallowed — see file header

        case .leftMouseDragged:
            guard isDragging else { return pass }
            emit(.dragMoved(location))
            return true

        case .leftMouseUp:
            guard isDragging else { return pass }
            isDragging = false
            emit(.dragEnded(location))
            return true

        case .scrollWheel:
            // Not swallowed: scrolling to reach the thing you want to point at
            // is legitimate mid-session. Recorded because a "settle" while the
            // content moves underneath is not a pointing act, and the aligner
            // needs to know that. Reported unconditionally now — the modifier
            // no longer bounds the session, so the Recorder decides whether it
            // is currently interested.
            emit(.scrolled)
            return pass

        default:
            return pass
        }
    }

    /// Called by the Recorder when a session ends by any route other than a
    /// tap — a watchdog, or Quit. Keeps the swallow gate honest.
    func noteSessionEnded() {
        isSessionActive = false
        gesture.sessionEndedExternally()
        if isDragging {
            isDragging = false
            emit(.dragEnded(AXProbe.cursorLocation()))
        }
    }

    /// Called by the Recorder when a session starts by any route other than a
    /// tap — today, "Forgot something?" reopening a finished session.
    ///
    /// `isSessionActive` is what makes Left Option drags mean "draw a lasso"
    /// rather than passing through to the app underneath. Setting it here is what
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
            if isDragging {
                isDragging = false
                emit(.dragEnded(AXProbe.cursorLocation()))
            }
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
