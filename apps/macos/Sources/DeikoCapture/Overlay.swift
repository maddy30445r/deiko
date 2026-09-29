import AppKit
import Foundation
import DeikoGesture

// A transparent, click-through window above every app. It draws a cursor ring
// while a session runs, the stroke while Left Option is held (nothing behind the
// cursor otherwise), a pulse when a referent is captured (accent for a point,
// teal for a region), and a flourish when a stroke commits (the classified
// shape, so a misread is visible at once).
//
// Everything is translucent accent except the capturing pill: an opaque red
// capsule with a live timer on every display, which never fades or auto-hides.
// macOS's own orange microphone dot says "something is recording"; the pill adds
// how long, and how to stop it. Clicking it stops the session, so it lives in
// its own panel rather than the click-through canvas.
//
// Coordinates: AppKit windows and views are bottom-left origin; every capture
// coordinate in this codebase is top-left. The conversion happens once, in
// `viewPoint(from:)`.

/// A captured-referent pulse's duration. Under Reduce Motion the expanding
/// ring becomes a single short blink at fixed size.
private let pulseLifetimeMs: Double = 450
private let reducedPulseLifetimeMs: Double = 100

struct Pulse {
    let position: Point
    let t: Double
    let isRegion: Bool
}

/// The classified form of the stroke that just committed, shown briefly where
/// it was drawn, so a misread is visible at once.
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
    /// Registered once and never removed: the callback is cheap and checks
    /// whether an overlay is up, and unregistering needs the exact function
    /// pointer and context.
    private var observingDisplays = false

    /// What the pill's click does. Supplied by the recorder, because the pill
    /// promises "this stops it".
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
        // Click-through: the overlay must never intercept a click; the window
        // is purely visual.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]

        let view = OverlayView(frame: NSRect(origin: .zero, size: canvas.size))
        view.canvas = canvas
        // The y-flip pivots on the main screen's top edge (CG's global origin
        // is the main display's top-left), not on the canvas height. The two
        // coincide only when every screen shares the main screen's vertical
        // extent.
        view.flipY = NSScreen.screens.first?.frame.maxY ?? canvas.height
        window.contentView = view
        window.orderFrontRegardless()

        self.window = window
        self.view = view

        // One pill per display: the session records the whole desktop, so the
        // disclosure belongs on every part of it.
        pills = NSScreen.screens.map { screen in
            CapturePill(screen: screen) { [weak self] in self?.onStopRequested?() }
        }
        for pill in pills { pill.show() }

        // 60fps redraw only while visible. Pulses and flourishes fade
        // continuously, so it has to repaint even when the cursor is still.
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

    /// Everything `show()` computes is read once (canvas, `flipY`, one pill per
    /// screen), so a display added mid-session would get no capturing pill. This
    /// rebuilds the overlay when the displays change, through the same
    /// CGDisplayReconfiguration mechanism `Capture.swift` uses. Rebuilding
    /// wholesale is simpler than reconciling which screen gained or lost a pill.
    private func observeDisplayChanges() {
        guard !observingDisplays else { return }
        observingDisplays = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // Only once the change has landed: the "beginConfiguration" pass
            // fires before the new geometry exists.
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
        cursor: Point, lasso: [Point]?, pulses: [Pulse],
        hearingVoice: Bool
    ) {
        // Every pill, because the microphone belongs to the session rather
        // than to a screen.
        for pill in pills { pill.hearingVoice = hearingVoice }
        guard let view else { return }
        view.cursor = cursor
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

@MainActor
final class OverlayView: NSView {
    var canvas: NSRect = .zero
    /// The main screen's Cocoa maxY — the pivot for the y-flip. See `show()`.
    var flipY: CGFloat = 0
    var cursor: Point = Point(x: 0, y: 0)
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

        if let lasso { drawLasso(ctx, path: lasso) }
        drawPulses(ctx, now: now)
        drawFlourish(ctx, now: now)
        drawCursor(ctx)
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

            // Expanding ring that fades; Reduce Motion pins the radius for a
            // fixed-size blink.
            let radius = reduce ? 22 : 14 + 26 * progress
            let alpha = reduce ? 0.7 : 0.7 * (1 - progress)
            let center = viewPoint(from: pulse.position)

            // Teal = a region was captured; accent = a point.
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

    /// Shows the classified form of the stroke that just committed: what
    /// `StrokeClassifier` read the pixels as, not the pixels themselves, so a
    /// misread is visible at release.
    private func drawFlourish(_ ctx: CGContext, now: Double) {
        guard let flourish else { return }
        let reduce = DeikoStyle.reduceMotion
        let lifetime = reduce ? reducedPulseLifetimeMs : pulseLifetimeMs
        let age = now - flourish.t
        guard age < lifetime else { return }

        // Reduce Motion: a fixed-alpha blink, as pulses get.
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
            // Same stroke as the live lasso, but closed even if the release
            // point never made it back to the start: the flourish shows the
            // shape as read.
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
            // The classifier discarded the wobble and kept only the relation: a
            // straight line between the endpoints, arrow at the end.
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

    /// Two barbs at ±30° off the line's direction, 12pt long: the same geometry
    /// `InkRenderer` burns into the saved crop.
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

/// The capturing pill: `● Deiko is capturing 0:43 · tap right ⌥ to stop`.
///
/// Its own panel, not part of the click-through overlay, because clicking it
/// stops the session: the one clickable region Deiko draws over the screen.
/// Opaque record red (the only opaque surface in the product), it never fades or
/// dims, and sits centred 8pt below its screen's menu bar.
@MainActor
final class CapturePill {
    private let panel: NSPanel
    private let screen: NSScreen
    private var clock: Timer?
    private let startedMs = Clock.nowMs()
    private let label = NSTextField(labelWithString: "")
    private let onStop: () -> Void

    /// Whether the microphone has heard anything recently. Set by `Overlay`
    /// from the recorder's own gate, so the pill warns exactly when capture
    /// starts discarding what you point at. It catches a silent failure (for
    /// example a very low system input volume) that would otherwise only show
    /// up after the session.
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
        // A pill without a moving clock might be a stale screenshot of itself.
        // The timer proves liveness rather than measuring time.
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
        // The warning replaces the stop hint rather than joining it: both at
        // once is a pill nobody finishes reading, and the pill is clickable
        // either way.
        text.append(NSAttributedString(
            string: hearingVoice
                ? "  ·  tap \(SessionKey.selected.symbol) to stop"
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
