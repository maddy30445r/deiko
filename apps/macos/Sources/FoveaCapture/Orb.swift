import AppKit
import Combine
import SwiftUI
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE ORB — the session's last step, on screen instead of in a terminal
//
// A session ends and the orb appears: a small always-on-top glass card, centred,
// showing Fovea's three-line reading of what it heard. Its 56pt COIN — a disc
// wearing the fovea mark — is the drag handle: fling it onto the window running
// Claude Code and the brief lands in that live session, the send, the app
// switch and the typing of the slash command all inside one gesture.
//
// While you aim, the coin DETACHES: it follows the cursor at full weight with
// the aim label riding underneath, and the card stays behind at 35% opacity
// with a dashed socket where the coin was. What you are throwing is the coin,
// not the card — the design (mddocs/design-brief.md → Claude Design canvas)
// made that literal.
//
// Clicking the coin opens the full review panel directly. The old unfold-on-
// click options row is gone (canvas cut 1r): two hidden buttons behind a click,
// on a non-activating panel where hover can't teach, was a dead end. "Add more"
// lives on as the panel's "Point at more" button, and as double-tapping Right
// Option while the orb is up — which resumes the SAME session.
//
// The summary sits at rest deliberately. A mis-heard identifier in the
// narration does more damage than anywhere else in the brief, so "did it hear
// me" must be answerable at a glance, before the fling, without opening
// anything.
//
// The gesture's decisions live in `FoveaHandoff.FlingGesture`, tested without a
// screen. This file feeds it mouse events and obeys what comes back.
// ─────────────────────────────────────────────────────────────────────────────

/// What the orb window is currently showing.
enum OrbMode {
    /// The card: summary and the coin.
    case collapsed
    /// The full review panel.
    case expanded
}

/// What the fling is currently over.
///
/// A three-case enum rather than the `HandoffTarget??` this used to be, where
/// `nil` meant "not flinging" and `.some(nil)` meant "over nothing". Those read
/// identically at a glance and only one of them should show a target name.
enum Aim {
    /// No fling in flight.
    case idle
    /// Flinging, but over nothing a brief can go to.
    case overNothing
    case over(HandoffTarget)
}

@MainActor
final class OrbState: ObservableObject {
    @Published var mode: OrbMode = .collapsed
    /// The app the fling is currently over, for the label under the coin.
    @Published var aim: Aim = .idle
    /// What the session captured, for the working readout — known the moment
    /// the recorder closes, long before the pipeline has anything to say.
    @Published var captured: SessionStats?
    var isAiming: Bool { if case .idle = aim { return false }; return true }
    /// Aiming AND over something a brief can actually go to.
    var isOverTarget: Bool { if case .over = aim { return true }; return false }
}

@MainActor
final class OrbController: NSObject {

    private var window: NSPanel?
    private let model = ReviewModel()
    private let state = OrbState()
    private var fling = FlingGesture()
    private let highlight = TargetHighlight()
    private lazy var coinCursor = CoinCursor(state: state)
    private var phaseWatcher: AnyCancellable?
    private var escapeMonitor: Any?
    private var fadeTask: Task<Void, Never>?

    /// Reopen a finished session and start recording again. Set by `MenuBar`,
    /// which owns the recorder — the same contract the review window had.
    var onExtend: ((String) -> Bool)?

    /// Open Settings — set by `MenuBar`, which owns that window. A failure whose
    /// fix is "add your key" should be one click from the key.
    ///
    /// Forwarded to the model too, so the expanded panel's failure view offers
    /// the same button as the collapsed orb.
    var onOpenSettings: (() -> Void)? {
        didSet { model.onOpenSettings = onOpenSettings }
    }

    /// The session currently being extended, if any.
    private var extending: String?

    /// The point the last processed drag update resolved its target at, in CG
    /// global coordinates.
    ///
    /// The release used to re-read `NSEvent.mouseLocation`, which is a
    /// DIFFERENT point: SwiftUI coalesces drag updates, so on a fast fling the
    /// cursor can travel tens of points past the last position we actually
    /// resolved an app at. That made the named target and the clicked pixel two
    /// different questions. Now they are the same one.
    private var aimPoint: CGPoint?

    // ── Presenting ──────────────────────────────────────────────────────────

    /// A session has just closed: show the orb and run the pipeline behind it.
    func present(sessionDir: String, stats: SessionStats? = nil) {
        // Narrate every handoff into the app's log. The first live fling
        // failed with nothing on screen and nothing on disk — the only trace
        // hook was in `handoff-test`, so the field run was undiagnosable and
        // the whole investigation started from "nothing happened". Field runs
        // must never be quieter than the test harness.
        if Handoff.trace == nil {
            Handoff.trace = { Emit.log("handoff: \($0)") }
        }
        fadeTask?.cancel()
        state.captured = stats
        if let extending, extending == sessionDir {
            self.extending = nil
            show()
            model.reload(afterExtending: sessionDir)
            return
        }
        state.mode = .collapsed
        show()
        model.load(sessionDir: sessionDir)
    }

    private func show() {
        if window == nil { window = makeWindow() }
        applyMode()
        window?.orderFrontRegardless()
        installEscapeMonitor()

        // Fading is phase-driven rather than wired into each send path, so the
        // orb behaves the same whether the brief left via a fling or via the
        // expanded panel's own button.
        //
        // `.failed` CANCELS a scheduled fade. Without that, a handoff that
        // fails after the copy succeeded could flash its message and vanish —
        // the orb dismissing itself over the one screen the developer needed
        // to read.
        if phaseWatcher == nil {
            phaseWatcher = model.$phase.sink { [weak self] phase in
                switch phase {
                case .sent: self?.fadeSoon()
                case .failed:
                    self?.fadeTask?.cancel()
                    // The failure block is taller than the readout — message,
                    // a button, the folded details. Give it the room now; a
                    // scrolling one-liner was the old design's mistake.
                    self?.applyMode()
                case .working, .ready: break
                }
            }
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = OrbPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above every normal window on every space — the orb is a handoff
        // object, not a document, and it must be visible wherever the session
        // ended. Below the lasso overlay's `.screenSaver`, which must stay the
        // topmost thing Fovea draws.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        // Nonactivating: pressing the orb must not pull focus off the app the
        // developer is working in — the whole point is to aim at *that* app.
        // The panel still becomes key itself when the editor needs typing.
        panel.hidesOnDeactivate = false

        let hosting = NSHostingController(
            rootView: OrbRootView(
                model: model,
                state: state,
                actions: OrbActions(
                    onPress: { [weak self] in self?.flingPressed() },
                    onDrag: { [weak self] translation in self?.flingDragged(translation) },
                    onRelease: { [weak self] in self?.flingReleased() },
                    onDismiss: { [weak self] in self?.dismiss() },
                    onExtend: { [weak self] in self?.extendSession() },
                    onSetMode: { [weak self] mode in
                        self?.state.mode = mode
                        self?.applyMode()
                    },
                    onOpenSettings: { [weak self] in self?.onOpenSettings?() },
                    onHeightChange: { [weak self] height in self?.fit(cardHeight: height) }
                )
            )
        )
        // THE WINDOW OWNS ITS SIZE, NOT SWIFTUI.
        //
        // The default sizing options push the SwiftUI content's ideal size back
        // onto the window, which silently beat every `setFrame` here: the
        // expanded panel grew past the bottom of the display and took "Point at
        // more" and "Good to go" off screen with it — two buttons that existed
        // and could not be clicked. The collapsed card had the same disease,
        // harmlessly. Now nothing resizes this window except `applyMode` and
        // `fit(cardHeight:)`.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        return panel
    }

    /// The card's measured height, reported up from SwiftUI. Nil until the
    /// first measurement lands.
    private var measuredCardHeight: CGFloat?

    /// Size and recentre for the current mode. Centred, on purpose — if that
    /// turns out to sit where you are looking, that is dogfooding feedback
    /// worth having, not a setting worth pre-building.
    ///
    /// The panel is the design's fixed 620×640 and scrolls internally. The card
    /// is 400 wide and exactly as tall as its content — "the readout earns its
    /// height, no more" — which is a measurement rather than the three guessed
    /// constants this used to carry, one of which was always wrong for a
    /// three-line summary.
    private func applyMode() {
        let size: NSSize
        switch state.mode {
        case .collapsed: size = NSSize(width: 400, height: measuredCardHeight ?? 132)
        case .expanded: size = NSSize(width: 620, height: 640)
        }
        setFrame(to: size)
    }

    /// SwiftUI measured the card. Resize only when it actually changed, or the
    /// preference round-trip becomes a layout loop.
    private func fit(cardHeight: CGFloat) {
        let rounded = cardHeight.rounded(.up)
        guard rounded > 0, abs((measuredCardHeight ?? 0) - rounded) > 0.5 else { return }
        measuredCardHeight = rounded
        guard state.mode == .collapsed else { return }
        setFrame(to: NSSize(width: 400, height: rounded))
    }

    private func setFrame(to size: NSSize) {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard window.frame.size != size else { return }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        // The shadow is cached against the old shape. Without this the sent
        // pill wears the card's rectangle.
        window.invalidateShadow()
    }

    /// The × — the session is already on disk; this only puts the orb away.
    ///
    /// `cancelPendingWork()` is the invariant the review window's
    /// `windowWillClose` used to carry: closing the surface stops the pipeline
    /// behind it, so a transcription nobody is waiting for does not go on
    /// writing into a model the next session is about to reuse.
    private func dismiss() {
        fadeTask?.cancel()
        cancelFling()
        removeEscapeMonitor()
        model.cancelPendingWork()
        window?.orderOut(nil)
    }

    private func fadeSoon() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // ── "Point at more" ─────────────────────────────────────────────────────

    /// Identical contract to the review window's extend: hand control back to
    /// the recorder for another hold, and get the orb out of the way — the
    /// developer is about to point at the thing it would be covering.
    func extendSession() {
        guard let dir = model.currentSessionDir, let onExtend else { return }
        model.prepareToExtend()
        guard onExtend(dir) else {
            model.noteExtendFailed()
            return
        }
        extending = dir
        state.mode = .collapsed
        // Not `dismiss()`: this must NOT cancel the model's work — the
        // recording it is waiting for has just begun. Only the interaction
        // state is torn down.
        cancelFling()
        removeEscapeMonitor()
        window?.orderOut(nil)
    }

    /// The start gesture arrived while the orb is up: add to the session it is
    /// showing instead of opening a second one the agent would have to
    /// reconcile. Returns false when there is nothing extendable — no window,
    /// no digest yet, or a brief already handed over — and the recorder then
    /// starts a fresh session exactly as before.
    func extendPresentedSession() -> Bool {
        guard window?.isVisible == true, model.digest != nil else { return false }
        switch model.phase {
        case .ready, .failed:
            extendSession()
            return extending != nil
        case .working, .sent:
            return false
        }
    }

    // ── The fling ───────────────────────────────────────────────────────────

    private func flingPressed() {
        // Armed exactly when a brief exists to send — `.ready`, or a `.failed`
        // whose digest survived (a send that can be retried).
        fling.isArmed = {
            switch model.phase {
            case .ready: return model.digest != nil
            case .failed: return model.digest != nil
            case .working, .sent: return false
            }
        }()
        _ = fling.press()
    }

    private func flingDragged(_ translation: CGSize) {
        let mouse = NSEvent.mouseLocation
        let cgPoint = cocoaToCG(mouse)
        let overOrb = window?.frame.contains(mouse) ?? false
        let resolved = overOrb ? nil : Handoff.targetUnder(point: cgPoint, excluding: window)

        let decision = fling.drag(
            distance: hypot(translation.width, translation.height),
            overOrb: overOrb,
            target: resolved?.target
        )
        if case .aiming(let target) = decision {
            state.aim = target.map(Aim.over) ?? .overNothing
            // Only remembered when it actually resolved to the target we are
            // naming — an aim point over nothing must not become a click point.
            aimPoint = target == nil ? nil : cgPoint
            // The detached coin rides the cursor with the aim label under it;
            // the card behind keeps only its dashed socket.
            coinCursor.move(to: mouse)
            if let resolved, target != nil {
                highlight.show(cgRect: resolved.windowBounds)
            } else {
                highlight.hide()
            }
        }
    }

    private func flingReleased() {
        highlight.hide()
        coinCursor.hide()
        state.aim = .idle
        switch fling.release() {
        case .openOptions:
            // The gesture still calls a travel-free release `openOptions` —
            // the name is the package's tested contract. What it OPENS changed
            // with the redesign: the options row is cut, so a click goes
            // straight to the review panel.
            state.mode = .expanded
            applyMode()
        case .commit(let target):
            // Pin the aim point onto the target. The paste can only land where
            // focus is, and this is the one pixel the user actually aimed at —
            // deliver clicks it before typing. `aimPoint`, not a fresh cursor
            // read: they are not the same point on a fast fling.
            if let drop = aimPoint {
                send(to: target.dropped(atX: drop.x, y: drop.y))
            } else {
                send(to: target)
            }
        case .none, .aiming, .cancelled:
            break
        }
    }

    private func cancelFling() {
        _ = fling.cancel()
        highlight.hide()
        coinCursor.hide()
        state.aim = .idle
    }

    /// Send first, keystroke second, always. If the keystroke half fails the
    /// brief is already pending, so the remedy is the old flow — type the
    /// command yourself — and the orb says exactly that, naming the command
    /// form that host actually uses.
    private func send(to target: HandoffTarget) {
        // Resolved BEFORE deliver runs, while the app is still known to be
        // alive. `command(for:)` reads the bundle id through the pid, and the
        // commonest failure here is "the app is no longer running" — so
        // resolving it in the catch block finds nothing, misses the terminal
        // list, and tells the user to type the VS Code form at a terminal. This
        // file's own history is that handing over the wrong command form looks
        // exactly like a broken keystroke.
        let command = Handoff.command(for: target)
        model.approve(handingTo: target.appName) {
            do {
                try await Handoff.deliver(to: target)
            } catch {
                throw HandoffError(
                    "the brief is sent and waiting, but \(error.localizedDescription) "
                        + "Type \(command) in \(target.appName) to pick it up."
                )
            }
        }
    }

    // ── Escape ──────────────────────────────────────────────────────────────

    /// Escape cancels a fling in flight, and puts the orb away when no fling
    /// is running — the keyboard route to dismiss, so the orb is never a window
    /// you are stuck with.
    ///
    /// Installed for the orb's whole visible life rather than per-fling. The
    /// per-fling version leaked: it was installed on every press including
    /// unarmed ones and removed only on release, so a gesture interrupted by
    /// `extendSession` (which orders the panel out, and `onEnded` never
    /// arrives) left a monitor swallowing Escape for the rest of the process.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            // While the narration editor is open, Escape belongs to the text
            // field — dismissing the panel out from under someone typing a
            // correction would throw the correction away.
            if state.mode == .expanded { return event }
            if fling.isFlinging {
                cancelFling()
            } else {
                dismiss()
            }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Cocoa global (bottom-left origin) → CG global (top-left). The flip
    /// pivots on the MAIN screen's top edge, exactly as `Overlay` documents —
    /// CG's origin is the main display's top-left, not the canvas top.
    private func cocoaToCG(_ p: NSPoint) -> CGPoint {
        let flipY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: flipY - p.y)
    }
}

/// A borderless panel that can take keys — the narration editor needs a
/// first responder, and `.borderless` refuses key status by default.
private final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// ── The detached coin ───────────────────────────────────────────────────────

/// The coin while it is being thrown: a click-through panel that follows the
/// cursor, drawing the coin at full weight with the aim label riding under it.
/// The card it left behind keeps a dashed socket — what travels is the coin.
@MainActor
final class CoinCursor {
    private var window: NSPanel?
    private let state: OrbState

    /// Panel geometry: the coin's centre sits `coinCenterFromTop` below the
    /// panel's top edge, and the label hangs beneath it.
    private static let panelSize = NSSize(width: 340, height: 110)
    private static let coinCenterFromTop: CGFloat = 28

    init(state: OrbState) {
        self.state = state
    }

    /// Put the coin's centre at the cursor, in Cocoa screen coordinates.
    func move(to cocoaPoint: NSPoint) {
        if window == nil { window = make() }
        guard let window else { return }
        window.setFrameOrigin(NSPoint(
            x: cocoaPoint.x - Self.panelSize.width / 2,
            y: cocoaPoint.y - (Self.panelSize.height - Self.coinCenterFromTop)
        ))
        // Ordered after the card's panel at the same level, so the coin rides
        // above the card when the fling passes over it.
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The coin draws its own shadow; a window shadow under a mostly-empty
        // panel paints a visible rectangle.
        panel.hasShadow = false
        // Click-through: the panel chases the cursor, and a panel that could
        // swallow the mouse-up would end the fling into itself.
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentViewController = NSHostingController(rootView: CoinCursorView(state: state))
        return panel
    }
}

private struct CoinCursorView: View {
    @ObservedObject var state: OrbState

    var body: some View {
        VStack(spacing: 8) {
            CoinView(kind: state.isOverTarget ? .ready : .overNothing, held: true)
            switch state.aim {
            case .over(let target):
                aimLabel("→ \(target.appName) · let go to send", prominent: true)
            case .overNothing:
                aimLabel("not over a window · let go to cancel", prominent: false)
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .frame(width: 340, height: 110, alignment: .top)
    }

    private func aimLabel(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

// ── The coin ────────────────────────────────────────────────────────────────

/// The orb's handle: a 56pt disc with rim light, an inset ring, and a real
/// shadow — the one element in the product with depth, because it is the one
/// you can pick up. Wears the fovea mark; the failed state swaps it for `!`.
struct CoinView: View {
    enum Kind {
        /// Grey, pulsing — no accent until there is something to throw.
        case working
        case ready
        /// In flight, over nothing a brief can go to. The coin LOSES its
        /// accent and its mark goes dashed — this is the one moment it most
        /// needs to say "letting go here sends nothing", and a coin that looks
        /// identical over a target and over the desktop says the opposite.
        case overNothing
        case failed
    }

    let kind: Kind
    /// Held coins float: the shadow grows from 2pt to 8pt of throw the moment
    /// the coin is picked up. The card's shadow never changes.
    var held: Bool = false

    var body: some View {
        ZStack {
            Circle().fill(fill)
            // Rim light: bright at the top, gone by the middle.
            Circle().fill(
                LinearGradient(
                    colors: [FoveaStyle.coinShine, .clear],
                    startPoint: .top, endPoint: .center
                )
            )
            Circle().strokeBorder(ring, lineWidth: 1.5)
            glyph
        }
        .frame(width: 56, height: 56)
        .shadow(
            color: .black.opacity(held ? 0.45 : 0.3),
            radius: held ? 14 : 3,
            y: held ? 8 : 2
        )
    }

    private var fill: Color {
        switch kind {
        case .working, .overNothing: return Color.primary.opacity(0.06)
        case .ready: return FoveaStyle.coinFill
        case .failed: return FoveaStyle.needsYou.opacity(0.12)
        }
    }

    private var ring: Color {
        switch kind {
        case .working, .overNothing: return Color.secondary.opacity(0.5)
        case .ready: return FoveaStyle.accent
        case .failed: return FoveaStyle.needsYou
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .working:
            FoveaMark(diameter: 20, color: Color.secondary)
        case .ready:
            FoveaMark(diameter: 20, color: FoveaStyle.mark)
        case .overNothing:
            // Dashed and hollow — the mark's dot is what "this is aimed at
            // something" looks like, so over nothing it is absent.
            Circle()
                .strokeBorder(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                )
                .frame(width: 20, height: 20)
        case .failed:
            Text("!")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(FoveaStyle.needsYou)
        }
    }
}

// ── The aiming outline ──────────────────────────────────────────────────────

/// A stroked rectangle over the window the fling would land on. Purely visual,
/// click-through, and gone the moment the fling ends.
@MainActor
final class TargetHighlight {
    private var window: NSWindow?

    func show(cgRect: CGRect) {
        let flipY = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = NSRect(
            x: cgRect.origin.x,
            y: flipY - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
        if window == nil {
            let w = NSWindow(contentRect: cocoa, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = HighlightView()
            window = w
        }
        window?.setFrame(cocoa, display: true)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private final class HighlightView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            FoveaStyle.accentNS.setStroke()
            path.stroke()
        }
    }
}

// ── Views ───────────────────────────────────────────────────────────────────

struct OrbActions {
    let onPress: () -> Void
    let onDrag: (CGSize) -> Void
    let onRelease: () -> Void
    let onDismiss: () -> Void
    let onExtend: () -> Void
    let onSetMode: (OrbMode) -> Void
    let onOpenSettings: () -> Void
    /// How tall the collapsed card wants to be, so the panel can be exactly
    /// that and no more.
    let onHeightChange: (CGFloat) -> Void
}

/// Carries the card's laid-out height from SwiftUI up to the window.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct OrbRootView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var state: OrbState
    let actions: OrbActions

    /// Whether a press is in flight, so the first drag update — whatever its
    /// translation — is recognised as the press.
    @State private var pressed = false

    var body: some View {
        Group {
            if state.mode == .expanded {
                expandedPanel
            } else if case .sent = model.phase {
                measured { sentPill }
            } else {
                measured { card }
            }
        }
    }

    /// Report how tall this is, so the window can be exactly that. Measured on
    /// the way out rather than guessed on the way in.
    private func measured<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 400, alignment: .top)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(CardHeightKey.self) { height in
                actions.onHeightChange(height)
            }
    }

    // ── The card ────────────────────────────────────────────────────────────

    private var card: some View {
        HStack(alignment: .top, spacing: 14) {
            coinSlot
            readout
                // The canvas gives the readout its own right margin and floats
                // the ✕ above it. As an HStack member the ✕ stole width from
                // the summary and shifted the text every time it appeared.
                .padding(.trailing, 16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: FoveaStyle.panelRadius)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: FoveaStyle.panelRadius)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            // ALWAYS present, in every phase. A pipeline that failed before
            // producing a digest once left a borderless, always-on-top,
            // all-Spaces panel with no close box and no way out but quitting
            // Fovea. Hidden only while aiming, where it would sit under the
            // cursor mid-fling.
            if !state.isAiming {
                Button {
                    actions.onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(10)
                .help("Put the orb away. The session stays on disk.")
            }
        }
        .opacity(state.isAiming ? 0.35 : 1)
        .animation(.spring(duration: 0.25), value: state.mode)
        .animation(.easeOut(duration: 0.15), value: state.isAiming)
    }

    /// The coin at rest, or the socket it left behind while being thrown.
    ///
    /// The socket is drawn OVER an invisible coin, not INSTEAD of it: the
    /// coin's view owns the drag gesture in flight, and SwiftUI cancels a
    /// gesture whose view leaves the hierarchy — swap the views and the
    /// release never arrives, stranding the fling mid-air with the cursor
    /// coin stuck on screen.
    private var coinSlot: some View {
        ZStack {
            CoinView(kind: coinKind)
                .modifier(Breathing(active: isWorking))
                .opacity(state.isAiming ? 0 : 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The first update IS the press. Not
                            // `translation == .zero` — a fast fling's first
                            // event can arrive with the mouse already moved,
                            // and the press would never register.
                            if !pressed {
                                pressed = true
                                actions.onPress()
                            }
                            actions.onDrag(value.translation)
                        }
                        .onEnded { _ in
                            pressed = false
                            actions.onRelease()
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(accessibilitySummary)
                .accessibilityAddTraits(.isButton)
                .help("Drag the coin onto the window running Claude Code to hand the brief over. Click to review.")
            if state.isAiming {
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .frame(width: 56, height: 56)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isAiming {
                // The aim label rides under the coin now; the dimmed card only
                // reassures that nothing has been decided yet.
                if let summary = model.summary ?? digestLine {
                    Text(summary)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .opacity(0.8)
                }
                Text("the card stays behind while you aim — nothing sent yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                phaseReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var phaseReadout: some View {
        switch model.phase {
        case .working(let what):
            Text(what).font(.system(size: 13))
            if let captured = state.captured {
                Text(capturedLine(captured))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .failed(let problem):
            failureReadout(problem)
        case .ready:
            summaryLines
        case .sent:
            // Unreachable — the sent phase swaps the whole card for the pill —
            // but the switch must be total.
            EmptyView()
        }
    }

    private func failureReadout(_ problem: PipelineFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if problem.opensSettings {
                    Button("Open Settings") { actions.onOpenSettings() }
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            // Kept, folded — the raw output is the only thing worth having in
            // a bug report, and not what the person in front of it needs.
            if !problem.raw.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(problem.raw)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Fovea's reading when it exists; the digest's counts when it does not
    /// (no `GROQ_API_KEY`). Either way, "did it hear me" is answerable here.
    @ViewBuilder private var summaryLines: some View {
        if let summary = model.summary {
            Text(summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        } else if let line = digestLine {
            Text(line)
                .font(.system(size: 13))
            if model.summaryPending {
                ProgressView().controlSize(.small)
            }
        }
        if let repo = model.digest?.summary.repoHints.first {
            HStack(spacing: 8) {
                Text(repo)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FoveaStyle.mark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(FoveaStyle.accent.opacity(0.16), in: Capsule())
                Text("drag the coin onto Claude Code · click it for more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 3)
        } else if model.digest != nil {
            Label("No repo named — confirm where this belongs", systemImage: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(FoveaStyle.needsYou)
            Text("drag the coin onto Claude Code · click it for more")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // ── The sent pill ───────────────────────────────────────────────────────

    /// The card collapses to a capsule on the way out the door — less to read
    /// once there is nothing left to decide. Fades 2.5s later.
    private var sentPill: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(FoveaStyle.sentGreen.opacity(0.18))
                Circle()
                    .strokeBorder(FoveaStyle.sentGreen, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FoveaStyle.sentGreen)
            }
            .frame(width: 36, height: 36)
            Text(sentLine)
                .font(.system(size: 13))
        }
        .padding(.leading, 8)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        )
        // Centred in the 400pt width but NOT stretched to it — the canvas
        // draws a pill on its own, and a pill inside an invisible card carries
        // the card's shadow with it.
        .frame(maxWidth: .infinity)
        .accessibilityLabel(sentLine)
    }

    // ── The expanded panel ──────────────────────────────────────────────────

    /// The full review, unchanged — this is the old window's body wearing the
    /// orb as chrome. Collapsing keeps every edit: the narration lives in the
    /// model, not the view.
    private var expandedPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    actions.onSetMode(.collapsed)
                } label: {
                    Text("‹ Back to the orb")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FoveaStyle.mark)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    actions.onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Put the orb away. The session stays on disk.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            ReviewView(
                model: model,
                onExtend: actions.onExtend,
                onCollapse: { actions.onSetMode(.collapsed) }
            )
        }
        // The design's panel, exactly. Nothing inside may grow it: the content
        // scrolls and the footer is pinned, so "Good to go" is on screen for a
        // one-line narration and a thirty-line one alike.
        .frame(width: 620, height: 640)
        .background(
            RoundedRectangle(cornerRadius: FoveaStyle.panelRadius)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: FoveaStyle.panelRadius)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
        )
    }

    // ── Wording ─────────────────────────────────────────────────────────────

    private var isWorking: Bool {
        if case .working = model.phase { return model.digest == nil }
        return false
    }

    private var coinKind: CoinView.Kind {
        switch model.phase {
        case .working: return .working
        case .failed: return .failed
        case .ready, .sent: return .ready
        }
    }

    /// `0:43 captured · 6 things pointed at` — mono, because it is data.
    private func capturedLine(_ stats: SessionStats) -> String {
        var parts: [String] = []
        if let ms = stats.durationMs {
            let total = Int((ms / 1000).rounded())
            parts.append(String(format: "%d:%02d captured", total / 60, total % 60))
        }
        parts.append("\(stats.referentCount) thing\(stats.referentCount == 1 ? "" : "s") pointed at")
        return parts.joined(separator: " · ")
    }

    private var digestLine: String? {
        guard let d = model.digest else { return nil }
        let seconds = Int((d.summary.durationMs / 1000).rounded())
        let apps = d.summary.apps.isEmpty ? "no app" : d.summary.apps.joined(separator: ", ")
        return "\(seconds)s · \(d.summary.referentCount) things pointed at · \(apps)"
    }

    private var sentLine: String {
        model.handedTo.map { "Handed to \($0)" } ?? "Handed over"
    }

    private var accessibilitySummary: String {
        switch model.phase {
        case .working: return "Fovea brief, preparing"
        case .ready: return "Fovea brief, ready. Drag onto your coding agent's window to send, click to review."
        case .failed: return "Fovea brief, needs attention"
        case .sent: return "Fovea brief, handed over"
        }
    }
}

/// A soft breathing pulse for the working state — motion says "busy" without a
/// spinner fighting the summary for attention. Under Reduce Motion the scale
/// becomes an opacity breath: still visibly alive, nothing moves.
/// (Not Overlay's `Pulse`, which is a captured-referent ring; the name is
/// taken.)
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var up = false

    func body(content: Content) -> some View {
        let reduce = FoveaStyle.reduceMotion
        content
            .scaleEffect(active && up && !reduce ? 1.06 : 1.0)
            .opacity(active && up && reduce ? 0.7 : 1.0)
            .animation(
                active ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                value: up
            )
            .onAppear { up = true }
    }
}
