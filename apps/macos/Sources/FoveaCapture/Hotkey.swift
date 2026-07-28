import AppKit
import CoreGraphics
import Foundation
import FoveaGesture

// ─────────────────────────────────────────────────────────────────────────────
// HOLD, OR DOUBLE-TAP TO LOCK
//
// One modifier, three meanings, told apart by what happens during the press:
//
//   hold Right Option        → capture while held, release to stop
//   double-tap it            → LOCK: keep capturing hands-free until tapped again
//   hold it and drag         → lasso a region (that drag alone is swallowed)
//
// PUSH-TO-TALK ALONE LOST DATA. Session 20260728-152834: 23.2 of 58.7 seconds
// recorded nothing, because letting go to switch windows also stops the
// microphone and the sampler — the transcript caught a sentence restarted
// verbatim across the gap. A PURE TOGGLE fixed that but taxed the common case,
// where pointing at one thing and saying one sentence became two taps and a
// decision up front.
//
// So: both, with a promotion between them. You start holding, and if it turns
// out to be long, you double-tap and keep talking. Wispr Flow's model — the
// same problem, the same answer — adapted for a modifier that also has to draw.
//
// THE GRACE WINDOW is the whole trick. A release does not stop the session, it
// SCHEDULES a stop; a second press cancels it. Recording therefore continues
// unbroken across the double-tap, because a gap there would land mid-word.
//
// The tap is ACTIVE, not listen-only, because the lasso has to be swallowed:
// dragging with the button down means "select text" in an editor and "drag
// this" in a table. Drags are swallowed only while the modifier is down, so
// ordinary clicking and selection keep working all session.
// ───────────────────────────────────────────────────────────────────────────────

/// Right Option. Not `fn`/Globe, which macOS intercepts for dictation, the
/// emoji picker and input-source switching.
private let kRightOptionKeyCode: Int64 = 61

/// NX_DEVICERALTKEYMASK — the device-specific flag bit for the RIGHT Option
/// key. `.maskAlternate` is set while EITHER Option key is down, so testing it
/// alone meant that releasing Right Option while Left Option happened to be
/// held produced no `.released`: the release event carries keycode 61, but the
/// combined mask was still set, so the state machine saw no change — and the
/// left key's own release is keycode 58, rejected by the keycode guard. Result:
/// a hold that never ended. The device bit tracks the right key alone.
private let kRightOptionFlagMask: UInt64 = 0x40

/// Intent, not mechanics. All the timing lives in `Hotkey` so the Recorder
/// never has to reason about presses, releases or double-tap windows.
enum HotkeyEvent {
    /// Begin capturing. Held mode until a `.locked` follows.
    case recordingStarted
    /// Promoted to hands-free. Capture is already running; this is for the UI.
    case locked
    /// Stop and write the session out.
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

    private(set) var isHeld = false
    private(set) var isDragging = false

    /// Every decision about what a press or release MEANS lives in
    /// `SessionGesture`, which has no CGEvent dependency and is unit-tested.
    /// This class is then only plumbing: translate events, obey the decision.
    private var gesture = SessionGesture()

    /// The stop scheduled by a release, cancellable by a second press. This
    /// indirection is what keeps audio continuous across a promotion.
    private var pendingStop: Task<Void, Never>?

    var isLocked: Bool { gesture.isLocked }

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
        // The system disables a tap that takes too long in its callback. Work
        // here must stay trivial — re-enable and carry on rather than dying
        // silently mid-session. And RECONCILE: while the tap was dead, the
        // release may have happened unobserved. Without this check, `isHeld`
        // stays true forever — mouse clicks swallowed system-wide and the mic
        // recording — until the user happens to press Right Option again.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if isHeld, flags.rawValue & kRightOptionFlagMask == 0 {
                isHeld = false
                if isDragging {
                    isDragging = false
                    emit(.dragEnded(Point(x: event.location.x, y: event.location.y)))
                }
                apply(gesture.tapRecovered(modifierStillDown: false))
            }
            return false
        }

        let pass = false
        let location = Point(x: event.location.x, y: event.location.y)

        switch type {
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == kRightOptionKeyCode
            else { return pass }

            // The DEVICE bit, not `.maskAlternate` — see kRightOptionFlagMask.
            let nowHeld = event.flags.rawValue & kRightOptionFlagMask != 0
            if nowHeld != isHeld {
                isHeld = nowHeld
                if nowHeld { pressed() } else { released(at: location) }
            }
            // Always pass the modifier through: swallowing it would break
            // Option as a normal modifier everywhere else.
            return pass

        case .leftMouseDown:
            guard isHeld else { return pass }
            isDragging = true
            gesture.dragStarted()
            emit(.dragBegan(location))
            return true                     // swallowed — see file header

        case .leftMouseDragged:
            guard isHeld, isDragging else { return pass }
            emit(.dragMoved(location))
            return true

        case .leftMouseUp:
            guard isHeld, isDragging else { return pass }
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

    // ── Plumbing onto the tested state machine ──────────────────────────────

    private func pressed() {
        apply(gesture.press(at: Clock.nowMs()))
    }

    private func released(at location: Point) {
        if isDragging {
            isDragging = false
            emit(.dragEnded(location))
        }
        apply(gesture.release(at: Clock.nowMs()))
    }

    private func apply(_ decision: SessionGesture.Decision) {
        switch decision {
        case .none:
            break
        case .start:
            pendingStop?.cancel()
            pendingStop = nil
            emit(.recordingStarted)
        case .lock:
            pendingStop?.cancel()
            pendingStop = nil
            emit(.locked)
        case .stopNow:
            pendingStop?.cancel()
            pendingStop = nil
            emit(.recordingStopped)
        case .stopAfterGrace:
            pendingStop?.cancel()
            let window = gesture.doubleTapWindowMs
            pendingStop = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(window))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.apply(self.gesture.graceExpired())
                }
            }
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
