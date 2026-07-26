import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE OVERLAY
//
// A transparent, click-through window above every app, drawing:
//   • a Fovea cursor ring while the hotkey is held
//   • a fading trace behind the cursor
//   • the lasso stroke while dragging
//   • a pulse when a referent is captured (PRD §9.2)
//
// It is also the privacy signal. Push-to-talk is the product's hardest promise,
// and an overlay that appears only while the key is down is visible proof of
// it — far better than a settings screen nobody reads.
//
// COORDINATES: AppKit windows and views are BOTTOM-LEFT origin; every capture
// coordinate in this codebase is TOP-LEFT. The conversion happens once, in
// `viewPoint(from:)`, and nowhere else.
// ─────────────────────────────────────────────────────────────────────────────

/// How long a trail point stays visible. Long enough to read the path you took,
/// short enough that it doesn't smear into a scribble.
private let trailLifetimeMs: Double = 700

/// A captured-referent pulse's duration.
private let pulseLifetimeMs: Double = 450

struct TrailPoint {
    let position: Point
    let t: Double
}

struct Pulse {
    let position: Point
    let t: Double
    let isRegion: Bool
}

@MainActor
final class Overlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var timer: Timer?

    /// Union of every screen, in top-left global coordinates — the overlay
    /// spans all displays so pointing across monitors stays continuous.
    private var canvas: NSRect = .zero

    func show() {
        guard window == nil else { return }

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
        window.contentView = view
        window.orderFrontRegardless()

        self.window = window
        self.view = view

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
    }

    func update(cursor: Point, trail: [TrailPoint], lasso: [Point]?, pulses: [Pulse]) {
        guard let view else { return }
        view.cursor = cursor
        view.trail = trail
        view.lasso = lasso
        view.pulses = pulses
    }
}

// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class OverlayView: NSView {
    var canvas: NSRect = .zero
    var cursor: Point = Point(x: 0, y: 0)
    var trail: [TrailPoint] = []
    var lasso: [Point]?
    var pulses: [Pulse] = []

    override var isFlipped: Bool { false }

    /// The single top-left → bottom-left conversion in the drawing layer.
    private func viewPoint(from p: Point) -> NSPoint {
        NSPoint(x: p.x - canvas.minX, y: canvas.height - (p.y - canvas.minY))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        let now = Clock.nowMs()

        drawTrail(ctx, now: now)
        if let lasso { drawLasso(ctx, path: lasso) }
        drawPulses(ctx, now: now)
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
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.55 * life).cgColor)
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
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
        ctx.closePath()
        ctx.fillPath()

        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    private func drawPulses(_ ctx: CGContext, now: Double) {
        for pulse in pulses {
            let age = now - pulse.t
            guard age < pulseLifetimeMs else { continue }
            let progress = age / pulseLifetimeMs

            // Expanding ring that fades — reads as "captured" without stealing
            // attention from what the user is actually looking at.
            let radius = 14 + 26 * progress
            let alpha = 0.7 * (1 - progress)
            let center = viewPoint(from: pulse.position)

            ctx.setStrokeColor(
                (pulse.isRegion ? NSColor.systemTeal : NSColor.systemBlue)
                    .withAlphaComponent(alpha).cgColor
            )
            ctx.setLineWidth(2)
            ctx.strokeEllipse(
                in: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )
            )
        }
    }

    private func drawCursor(_ ctx: CGContext) {
        let center = viewPoint(from: cursor)

        // A ring, not a replacement pointer: the real cursor stays visible and
        // usable underneath, so pointing accuracy is unaffected.
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))

        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
    }
}
