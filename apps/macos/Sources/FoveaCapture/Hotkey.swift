import AppKit
import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PUSH-TO-TALK + GESTURE TAP
//
// One modifier, two gestures, separated by the mouse button:
//
//   hotkey held, moving, button up    → transit, ignored
//   hotkey held, still,  button up    → settle    → point candidate
//   hotkey held, moving, button DOWN  → lasso     → region referent
//
// The tap is ACTIVE, not listen-only, because the lasso has to be swallowed:
// dragging with the button down means "select text" in an editor and "drag
// this" in a table. If the drag reached the app underneath, drawing a region
// would mangle whatever you drew it around. While the hotkey is held we
// consume mouse events entirely and the app never sees them.
//
// Nothing is observed when the hotkey is up — the tap sees only modifier
// changes then, and every other event passes straight through untouched.
// ─────────────────────────────────────────────────────────────────────────────

/// Right Option. Not `fn`/Globe, which macOS intercepts for dictation, the
/// emoji picker and input-source switching.
private let kRightOptionKeyCode: Int64 = 61

enum HotkeyEvent {
    case pressed
    case released
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
        // silently mid-session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let pass = false
        let location = Point(x: event.location.x, y: event.location.y)

        switch type {
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == kRightOptionKeyCode
            else { return pass }

            // `.maskAlternate` is set for either Option key, so the keycode
            // check above is what makes this Right Option specifically.
            let nowHeld = event.flags.contains(.maskAlternate)
            if nowHeld != isHeld {
                isHeld = nowHeld
                emit(nowHeld ? .pressed : .released)
                if !nowHeld, isDragging {
                    isDragging = false
                    emit(.dragEnded(location))
                }
            }
            // Always pass the modifier through: swallowing it would break
            // Option as a normal modifier everywhere else.
            return pass

        case .leftMouseDown:
            guard isHeld else { return pass }
            isDragging = true
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
            // needs to know that.
            if isHeld { emit(.scrolled) }
            return pass

        default:
            return pass
        }
    }

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
    }
}
