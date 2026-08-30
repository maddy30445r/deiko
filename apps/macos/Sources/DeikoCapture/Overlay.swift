import AppKit
import Foundation
import DeikoGesture

// ─────────────────────────────────────────────────────────────────────────────
// THE OVERLAY
//
// A transparent, click-through window above every app, drawing:
//   • a Deiko cursor ring while a session runs
//   • a fading trace behind the cursor
//   • the lasso stroke while dragging
//   • a pulse when a referent is captured (PRD §9.2) — accent for a point,
//     teal for a region, distinguishable mid-session at a glance
//   • a flourish when a stroke commits — the CLASSIFIED shape, briefly, so a
//     misread is visible at the moment it happens
//
// Everything here is translucent accent — quiet receipts, not decoration.
// The ONE loud thing is the capturing pill, and it is loud on purpose: an
// opaque red capsule with a live timer, on every display, that does not fade,
// dim, or auto-hide. macOS's own orange microphone dot says "something is
// recording" and cannot be faked or suppressed by this app; the pill adds what
// that dot cannot — which app, for how long, and how to stop it. Clicking it
// stops the session, which is why it lives in its own panel rather than the
// click-through canvas.
//
// COORDINATES: AppKit windows and views are BOTTOM-LEFT origin; every capture
// coordinate in this codebase is TOP-LEFT. The conversion happens once, in
// `viewPoint(from:)`, and nowhere else.
// ─────────────────────────────────────────────────────────────────────────────

/// How long a trail point stays visible. Long enough to read the path you took,
/// short enough that it doesn't smear into a scribble.
private let trailLifetimeMs: Double = 700

/// A captured-referent pulse's duration. Under Reduce Motion the expanding
/// ring becomes a single short blink at fixed size — still a receipt, no
/// motion.
private let pulseLifetimeMs: Double = 450
private let reducedPulseLifetimeMs: Double = 100

struct TrailPoint {
    let position: Point
    let t: Double
}

struct Pulse {
    let position: Point
    let t: Double
    let isRegion: Bool
}

/// The classified form of the stroke that just committed, shown briefly where
/// it was drawn — so a misread (a scribble read as emphasis, a tap read as a
/// point) is visible the instant it happens, not discovered later in a crop.
struct Flourish {
    let path: [Point]
    let kind: StrokeKind
    let t: Double
}

@MainActor
final class Overlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var timer: Timer?
    private var pills: [CapturePill] = []

    /// Union of every screen, in top-left global coordinates — the overlay
    /// spans all displays so pointing across monitors stays continuous.
    private var canvas: NSRect = .zero
    /// Registered once and never removed — the callback is cheap, checks
    /// whether an overlay is even up, and unregistering would mean holding an
    /// exactly-matching function pointer and context to pass back.
    private var observingDisplays = false

    /// What the pill's click does — supplied by the recorder, because the
    /// pill's whole promise is "this stops it".
    var onStopRequested: (() -> Void)?

    func show() {
        guard window == nil else { return }
        observeDisplayChanges()

        canvas = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }

        let window = NSWindow(
            contentRect: canvas,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above normal windows and full-screen apps, below the screen saver.
        window.level = .screenSaver
        // Click-through: the overlay must never intercept a click. The event
        // tap already sees everything it needs; the window is purely visual.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]

        let view = OverlayView(frame: NSRect(origin: .zero, size: canvas.size))
        view.canvas = canvas
        // The top-left↔bottom-left flip pivots on the MAIN screen's top edge —
        // CG's global origin is the main display's top-left — not on the
        // canvas height. The two coincide only when every screen shares the
        // main screen's vertical extent; with a taller external monitor the
        // difference put every ring and lasso a few hundred points from the
        // real cursor.
        view.flipY = NSScreen.screens.first?.frame.maxY ?? canvas.height
        window.contentView = view
        window.orderFrontRegardless()

        self.window = window
        self.view = view

        // One pill per display — the session records the whole desktop, so
        // the disclosure belongs on every part of it.
        pills = NSScreen.screens.map { screen in
            CapturePill(screen: screen) { [weak self] in self?.onStopRequested?() }
        }
        for pill in pills { pill.show() }

        // 60fps redraw only while visible. The trail fades continuously, so it
        // has to repaint even when the cursor is still.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { view.needsDisplay = true }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        view = nil
        for pill in pills { pill.hide() }
        pills = []
    }

    // ── Displays move while a session is running ────────────────────────────
    //
    // EVERY NUMBER IN `show()` IS READ ONCE. The canvas is the union of the
    // screens as they were, `flipY` pivots on the main screen's top edge as it
    // was, and there is exactly one `CapturePill` per screen that existed at
    // the time. Plug in a monitor mid-session and that display gets no red
    // capturing pill at all — which is not a cosmetic gap, it is the
    // disclosure the product promises sits on every display, missing from the
    // screen most likely to have somebody else looking at it.
    //
    // `Capture.swift` already registers a CGDisplayReconfiguration callback to
    // invalidate its crop cache, and this uses the same mechanism rather than
    // introducing the app's first NSNotification observer for the same event —
    // one answer to "the displays moved", not two that can disagree.
    //
    // Rebuilding wholesale rather than patching: `show()` is idempotent behind
    // its own guard, and re-deriving three values is cheaper to reason about
    // than reconciling which screen gained or lost a pill.
    private func observeDisplayChanges() {
        guard !observingDisplays else { return }
        observingDisplays = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // Only once the change has landed. The "beginConfiguration" pass
            // fires before the new geometry exists, and rebuilding against it
            // would lay the overlay out for the displays we are leaving.
            guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
                    || flags.contains(.removeFlag) || flags.contains(.desktopShapeChangedFlag)
            else { return }
            guard let userInfo else { return }
            let overlay = Unmanaged<Overlay>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard overlay.window != nil else { return }
                    overlay.hide()
                    overlay.show()
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func update(
        cursor: Point, trail: [TrailPoint], lasso: [Point]?, pulses: [Pulse],
        hearingVoice: Bool
    ) {
        // Every pill, because the microphone belongs to the session rather than
        // to a screen — and the one thing worse than a silent failure is a
        // silent failure the user could only have seen on the other monitor.
        for pill in pills { pill.hearingVoice = hearingVoice }
        guard let view else { return }
        view.cursor = cursor
        // Reduce Motion: the trail is pure motion — a comet tail — so it is
        // the one element that goes entirely, not a substitute.
        view.trail = DeikoStyle.reduceMotion ? [] : trail
        view.lasso = lasso
        view.pulses = pulses
    }

    /// Called once per committed stroke, from `Recorder.commitLasso`. A new
    /// flourish replaces whatever was still fading — there is only ever one
    /// stroke to answer for at a time.
    func flourish(path: [Point], kind: StrokeKind) {
        view?.flourish = Flourish(path: path, kind: kind, t: Clock.nowMs())
    }
}

// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class OverlayView: NSView {
    var canvas: NSRect = .zero
    /// The main screen's Cocoa maxY — the pivot for the y-flip. See `show()`.
    var flipY: CGFloat = 0
    var cursor: Point = Point(x: 0, y: 0)
    var trail: [TrailPoint] = []
    var lasso: [Point]?
    var pulses: [Pulse] = []
    var flourish: Flourish?
    override var isFlipped: Bool { false }

    /// The single top-left → bottom-left conversion in the drawing layer.
    /// Cocoa global y = flipY − CG y; view y subtracts the window's origin.
    private func viewPoint(from p: Point) -> NSPoint {
        NSPoint(x: p.x - canvas.minX, y: flipY - p.y - canvas.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        let now = Clock.nowMs()

        drawTrail(ctx, now: now)
        if let lasso { drawLasso(ctx, path: lasso) }
        drawPulses(ctx, now: now)
        drawFlourish(ctx, now: now)
        drawCursor(ctx)
    }

    private func drawTrail(_ ctx: CGContext, now: Double) {
        guard trail.count >= 2 else { return }

        // Drawn as individual fading segments rather than one stroked path:
        // a single path can only carry one alpha, and the whole point is that
        // the tail is dimmer than the head.
        for i in 1..<trail.count {
            let a = trail[i - 1]
            let b = trail[i]
            let age = now - b.t
            guard age < trailLifetimeMs else { continue }

            let life = 1 - (age / trailLifetimeMs)
            ctx.setStrokeColor(DeikoStyle.accentNS.withAlphaComponent(0.55 * life).cgColor)
            ctx.setLineWidth(1 + 3 * life)
            ctx.setLineCap(.round)
            ctx.move(to: viewPoint(from: a.position))
            ctx.addLine(to: viewPoint(from: b.position))
            ctx.strokePath()
        }
    }

    private func drawLasso(_ ctx: CGContext, path: [Point]) {
        guard path.count >= 2 else { return }

        let points = path.map(viewPoint(from:))
        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }

        // Translucent fill with the loop implicitly closed, so a half-drawn
        // lasso already shows what it will enclose.
        ctx.setFillColor(DeikoStyle.accentNS.withAlphaComponent(0.13).cgColor)
        ctx.closePath()
        ctx.fillPath()

        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.setStrokeColor(DeikoStyle.accentNS.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    private func drawPulses(_ ctx: CGContext, now: Double) {
        let reduce = DeikoStyle.reduceMotion
        let lifetime = reduce ? reducedPulseLifetimeMs : pulseLifetimeMs

        for pulse in pulses {
            let age = now - pulse.t
            guard age < lifetime else { continue }
            let progress = age / lifetime

            // Expanding ring that fades — reads as "captured" without stealing
            // attention from what the user is actually looking at. Reduce
            // Motion pins the radius: a fixed-size blink instead of growth.
            let radius = reduce ? 22 : 14 + 26 * progress
            let alpha = reduce ? 0.7 : 0.7 * (1 - progress)
            let center = viewPoint(from: pulse.position)

            // Teal = a region was captured; accent = a point. The colour is
            // never alone — a region pulse is born from a lasso the user just
            // drew, a point pulse from a settle.
            ctx.setStrokeColor(
                (pulse.isRegion ? DeikoStyle.regionTealNS : DeikoStyle.accentNS)
                    .withAlphaComponent(alpha).cgColor
            )
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(
                in: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )
            )
        }
    }

    /// Shows the CLASSIFIED form of the stroke that just committed — not the
    /// raw pixels drawn, but what `StrokeClassifier` read them as. A misread
    /// (a scribble read as `.emphasis`, a real loop read as `.trace`) is
    /// visible right here, at release, instead of discovered later in a crop.
    private func drawFlourish(_ ctx: CGContext, now: Double) {
        guard let flourish else { return }
        let reduce = DeikoStyle.reduceMotion
        let lifetime = reduce ? reducedPulseLifetimeMs : pulseLifetimeMs
        let age = now - flourish.t
        guard age < lifetime else { return }

        // Reduce Motion: no fade, a fixed-alpha blink — the same treatment
        // pulses get, for the same reason.
        let alpha = reduce ? 0.9 : 0.9 * (1 - age / lifetime)
        let color = DeikoStyle.accentNS.withAlphaComponent(alpha).cgColor
        let points = flourish.path.map(viewPoint(from:))
        guard let first = points.first else { return }

        switch flourish.kind {
        case .point:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8))

        case .lasso:
            guard points.count >= 2 else { break }
            // Same stroke as the live lasso — accent, 2.5pt, round joins —
            // but CLOSED even if the release point never made it back to the
            // start: the flourish shows the shape it was READ as, not the
            // exact pixels drawn.
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2.5)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()

        case .connector:
            // The classifier discarded the wobble and kept only the relation:
            // one straight line between the two endpoints, arrow pointing at
            // whatever the stroke ended on.
            guard let last = points.last, points.count >= 2 else { break }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.round)
            ctx.move(to: first)
            ctx.addLine(to: last)
            ctx.strokePath()
            drawArrowhead(ctx, from: first, to: last, color: color)

        case .trace:
            guard points.count >= 2 else { break }
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2.5)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
            drawArrowhead(
                ctx, from: points[points.count - 2], to: points[points.count - 1], color: color
            )

        case .emphasis:
            guard points.count >= 2 else { break }
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(3.5)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
    }

    /// Two barbs at ±30° off the line's direction, 12pt long — the same
    /// geometry `InkRenderer` burns into the saved crop, so the live answer
    /// and the receipt agree.
    private func drawArrowhead(_ ctx: CGContext, from a: NSPoint, to b: NSPoint, color: CGColor) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let len: CGFloat = 12
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2.5)
        for side in [-1.0, 1.0] {
            let barb = angle + .pi + side * (.pi / 6)
            ctx.beginPath()
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x + len * cos(barb), y: b.y + len * sin(barb)))
            ctx.strokePath()
        }
    }

    private func drawCursor(_ ctx: CGContext) {
        let center = viewPoint(from: cursor)

        // A ring, not a replacement pointer: the real cursor stays visible and
        // usable underneath, so pointing accuracy is unaffected.
        ctx.setStrokeColor(DeikoStyle.accentNS.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))

        ctx.setFillColor(DeikoStyle.accentNS.withAlphaComponent(0.22).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The capturing pill: `● Deiko is capturing 0:43 · tap right ⌥ to stop`.
///
/// Its own panel, NOT part of the click-through overlay, because clicking it
/// stops the session — the one clickable pixel region Deiko draws over your
/// screen. Opaque record red (the only opaque surface in the product), white
/// live timer, centred 8pt below the menu bar of its screen. It never fades or
/// dims, and Reduce Transparency changes nothing because it was never
/// transparent.
@MainActor
final class CapturePill {
    private let panel: NSPanel
    private let screen: NSScreen
    private var clock: Timer?
    private let startedMs = Clock.nowMs()
    private let label = NSTextField(labelWithString: "")
    private let onStop: () -> Void

    /// Whether the microphone has heard anything recently. Set by `Overlay`
    /// from the recorder's own gate, so the pill warns at exactly the moment
    /// capture starts discarding what you point at, not on a second guess.
    ///
    /// This exists because the failure it catches has now happened three times
    /// in this project's life — twice recorded in comments, both at a 27%
    /// system input volume — and every time the user found out AFTER the
    /// session, from a pipeline that had 44 seconds of unusable audio and
    /// nothing to say about it until then. Everything needed to say so
    /// earlier was already here: the gate is live, the pill redraws every
    /// second, and it never mentioned it.
    var hearingVoice = true {
        didSet { if hearingVoice != oldValue { layout() } }
    }

    init(screen: NSScreen, onStop: @escaping () -> Void) {
        self.screen = screen
        self.onStop = onStop
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = PillView(onStop: onStop)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        (panel.contentView as? PillView)?.addSubview(label)
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
        // A pill without a moving clock is a pill that might be a stale
        // screenshot of itself. One second is enough; the timer's job is to
        // prove liveness, not measure it.
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func hide() {
        clock?.invalidate()
        clock = nil
        panel.orderOut(nil)
    }

    private func layout() {
        let elapsed = Int((Clock.nowMs() - startedMs) / 1000)
        let text = NSMutableAttributedString(
            string: "●  Deiko is capturing  ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        )
        text.append(NSAttributedString(
            string: String(format: "%d:%02d", elapsed / 60, elapsed % 60),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
        ))
        // The warning REPLACES the stop hint rather than joining it. Both at
        // once is a pill nobody finishes reading, and the hint is the more
        // expendable of the two: the pill is clickable either way, and a
        // session recording silence is worth more attention than a keyboard
        // shortcut already printed in the log when it started.
        text.append(NSAttributedString(
            string: hearingVoice
                ? "  ·  tap right ⌥ to stop"
                : "  ·  not hearing you — check Sound input",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: 12, weight: hearingVoice ? .regular : .semibold
                ),
                .foregroundColor: hearingVoice
                    ? NSColor.white.withAlphaComponent(0.8)
                    : NSColor.white,
            ]
        ))
        label.attributedStringValue = text
        label.sizeToFit()

        let padding: CGFloat = 14
        let height = label.frame.height + 10
        let size = NSSize(width: label.frame.width + padding * 2, height: height)
        label.frame.origin = NSPoint(x: padding, y: (height - label.frame.height) / 2)

        // Centred, 8pt below this screen's menu bar (visibleFrame excludes it).
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 8
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The opaque red capsule, and the click that stops the session.
    private final class PillView: NSView {
        private let onStop: () -> Void

        init(onStop: @escaping () -> Void) {
            self.onStop = onStop
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            DeikoStyle.pillRedNS.setFill()
            path.fill()
        }

        override func mouseDown(with event: NSEvent) {
            onStop()
        }
    }
}
