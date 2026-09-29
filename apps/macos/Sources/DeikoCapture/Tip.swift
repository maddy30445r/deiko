import AppKit
import SwiftUI

// Deiko's own tooltip: `.help()` cannot be styled or animated. After the usual
// hover delay a speech bubble pops out of the view being pointed at, and goes
// away on click, key, scroll or hover-out. Reduce Motion gets a plain fade.
//
// The bubble lives in its own borderless, click-through panel rather than an
// overlay: every pane is a scroll view that would clip an overlay, and the orb
// floats above normal windows. The text is also the view's accessibility hint,
// which is what `.help()` gave VoiceOver.

extension View {
    /// A hover explanation that pops out: Deiko's `.help()`.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content
                .onHover { inside in
                    if inside { Tips.shared.schedule(text, for: owner) } else { Tips.shared.cancel(owner) }
                }
                .onDisappear { Tips.shared.cancel(owner) }
                .accessibilityHint(text)
        }
    }
}

/// `.tip()` for an AppKit view SwiftUI doesn't draw, such as the menu-bar
/// icon: own its tracking area, set `text`, and it pops the same bubble.
@MainActor
final class HoverTip: NSResponder {
    var text: String? {
        didSet { if text == nil { Tips.shared.cancel(id) } }
    }
    private let id = UUID()

    override func mouseEntered(with event: NSEvent) {
        if let text { Tips.shared.schedule(text, for: id) }
    }

    override func mouseExited(with event: NSEvent) {
        Tips.shared.cancel(id)
    }
}

/// Whether the bubble is out; the view animates on it.
@MainActor
private final class TipState: ObservableObject {
    @Published var shown = false
}

@MainActor
final class Tips {
    static let shared = Tips()

    /// The macOS tooltip delay, so moving across a window never sets off a
    /// string of pops.
    private let delay: TimeInterval = 0.55
    /// The shadow's room inside the panel, on every side.
    fileprivate static let margin: CGFloat = 16

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var owner: UUID?
    private var monitor: Any?
    private let state = TipState()

    func schedule(_ text: String, for id: UUID) {
        pending?.cancel()
        owner = id
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(text) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel(_ id: UUID) {
        guard owner == id else { return }
        hide()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        guard let panel, panel.isVisible else { return }
        state.shown = false
        // Out after the shrink, unless another tip has taken the panel since.
        let close = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.shown else { return }
                self.panel?.orderOut(nil)
            }
        }
        closing = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: close)
    }

    private func show(_ text: String) {
        closing?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero

        // Measure once to know the bubble's size, then place it and point the tail.
        let probe = NSHostingView(rootView: TipBubble(text: text, tailUp: true, tailX: 16, width: 0, state: state))
        let size = probe.fittingSize
        let m = Self.margin
        let bubbleWidth = size.width - 2 * m

        // Below the pointer's arrow, or above it when there's no room below.
        let tailUp = mouse.y - 22 - size.height >= screen.minY
        // The bubble starts just left of the pointer, and is nudged back on
        // screen at the right edge; the tail keeps pointing at the pointer.
        var left = mouse.x - 20
        left = min(left, screen.maxX - bubbleWidth - 8)
        left = max(left, screen.minX + 8)
        let tailX = min(max(mouse.x - left, 20), bubbleWidth - 20)

        let host = NSHostingView(rootView: TipBubble(text: text, tailUp: tailUp, tailX: tailX, width: bubbleWidth, state: state))
        let panel = self.panel ?? make()
        panel.contentView = host
        panel.setContentSize(size)
        let originY = tailUp ? mouse.y - 22 + m - size.height : mouse.y + 8 - m
        panel.setFrameOrigin(NSPoint(x: left - m, y: originY))
        state.shown = false
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.state.shown = true }
        watchForDismissal()
    }

    private func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the orb, which floats one level under the screen saver.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    /// Any click, key or scroll puts the tip away, as a system tooltip does.
    private func watchForDismissal() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
    }
}

/// A speech bubble: a rounded card with a small tail on its top or bottom
/// edge, `tailX` in from the left. One continuous outline, so the hairline
/// runs round the tail instead of across its base.
private struct Bubble: SwiftUI.Shape {
    let tailUp: Bool
    let tailX: CGFloat
    var radius: CGFloat = 11
    static let tail = CGSize(width: 16, height: 8)

    func path(in rect: CGRect) -> Path {
        let t = Self.tail
        let top = rect.minY + (tailUp ? t.height : 0)
        let bottom = rect.maxY - (tailUp ? 0 : t.height)
        let (l, r, x, w) = (rect.minX, rect.maxX, rect.minX + tailX, t.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: l + radius, y: top))
        if tailUp {
            p.addLine(to: CGPoint(x: x - w, y: top))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - w / 3, y: top))
            p.addQuadCurve(to: CGPoint(x: x + w, y: top), control: CGPoint(x: x + w / 3, y: top))
        }
        p.addArc(tangent1End: CGPoint(x: r, y: top), tangent2End: CGPoint(x: r, y: bottom), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r, y: bottom), tangent2End: CGPoint(x: l, y: bottom), radius: radius)
        if !tailUp {
            p.addLine(to: CGPoint(x: x + w, y: bottom))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.maxY), control: CGPoint(x: x + w / 3, y: bottom))
            p.addQuadCurve(to: CGPoint(x: x - w, y: bottom), control: CGPoint(x: x - w / 3, y: bottom))
        }
        p.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: l, y: top), radius: radius)
        p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: r, y: top), radius: radius)
        p.closeSubpath()
        return p
    }
}

private struct TipBubble: View {
    let text: String
    let tailUp: Bool
    let tailX: CGFloat
    /// The bubble's own width, measured before placing it, so the pop can
    /// grow from the tail's tip.
    let width: CGFloat
    @ObservedObject var state: TipState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let t = Bubble.tail
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            // Deiko's dot: "I'm pointing at that."
            Circle()
                .fill(DeikoStyle.tipDot)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            Text(text)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(DeikoStyle.tipText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.textWidth(text), alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8 + (tailUp ? t.height : 0))
        .padding(.bottom, 9 + (tailUp ? 0 : t.height))
        .background(
            Bubble(tailUp: tailUp, tailX: tailX)
                .fill(DeikoStyle.tipFill)
                .overlay(Bubble(tailUp: tailUp, tailX: tailX).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
        )
        .fixedSize()
        // The pop grows out of the tail's tip.
        .scaleEffect(reduceMotion || state.shown ? 1 : 0.55, anchor: anchor)
        .rotationEffect(.degrees(reduceMotion || state.shown ? 0 : (tailUp ? -6 : 6)), anchor: anchor)
        .opacity(state.shown ? 1 : 0)
        .animation(
            state.shown
                ? (reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.5))
                : .easeIn(duration: 0.12),
            value: state.shown
        )
        .padding(Tips.margin)
    }

    static let fontSize: CGFloat = 12
    /// Past this, a tip wraps.
    static let maxTextWidth: CGFloat = 252

    /// The width the text will actually take: its one-line width, capped.
    ///
    /// Pinned rather than `maxWidth`: the panel is sized from `fittingSize`,
    /// which proposes no width, so under a `maxWidth` frame the text reports its
    /// one-line height and then wraps inside a one-line bubble. With the width
    /// pinned, the height is measured at the wrapped width.
    static func textWidth(_ s: String) -> CGFloat {
        let one = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return min(ceil(one) + 1, maxTextWidth)
    }

    /// The tail's tip, as a point in the bubble's own frame.
    private var anchor: UnitPoint {
        UnitPoint(x: width > 0 ? tailX / width : 0, y: tailUp ? 0 : 1)
    }
}
