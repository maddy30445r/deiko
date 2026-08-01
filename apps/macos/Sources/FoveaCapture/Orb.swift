import AppKit
import Combine
import SwiftUI
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE ORB — the session's last step, on screen instead of in a terminal
//
// A session ends and the orb appears: a small always-on-top card, centred,
// showing Fovea's three-line reading of what it heard. If the reading is right,
// fling the orb onto the window running Claude Code and the brief lands in that
// live session — the send, the app switch, and the typing of
// the brief's slash command all inside one gesture. If the reading is wrong, expand
// it: the full review panel (narration editor and all) is the orb's grown-up
// form, not a separate window.
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
    /// The card: summary and the fling handle.
    case collapsed
    /// The card with its actions unfolded (dismiss / add more / fix).
    case options
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
    /// The app the fling is currently over, for the `→ iTerm2` label.
    @Published var aim: Aim = .idle
    var isAiming: Bool { if case .idle = aim { return false }; return true }
}

@MainActor
final class OrbController: NSObject {

    private var window: NSPanel?
    private let model = ReviewModel()
    private let state = OrbState()
    private var fling = FlingGesture()
    private let highlight = TargetHighlight()
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

    /// Where the fling's mouse-down happened, in Cocoa screen coordinates.
    private var pressLocation: NSPoint = .zero

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
    func present(sessionDir: String) {
        // Narrate every handoff into the app's log. The first live fling
        // failed with nothing on screen and nothing on disk — the only trace
        // hook was in `handoff-test`, so the field run was undiagnosable and
        // the whole investigation started from "nothing happened". Field runs
        // must never be quieter than the test harness.
        if Handoff.trace == nil {
            Handoff.trace = { Emit.log("handoff: \($0)") }
        }
        fadeTask?.cancel()
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
                case .failed: self?.fadeTask?.cancel()
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

        panel.contentViewController = NSHostingController(
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
                    onOpenSettings: { [weak self] in self?.onOpenSettings?() }
                )
            )
        )
        return panel
    }

    /// Size and recentre for the current mode. Centred and fixed, on purpose —
    /// if that turns out to sit where you are looking, that is dogfooding
    /// feedback worth having, not a setting worth pre-building.
    private func applyMode() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size: NSSize
        switch state.mode {
        case .collapsed: size = NSSize(width: 400, height: 190)
        case .options: size = NSSize(width: 400, height: 236)
        case .expanded: size = NSSize(width: 620, height: 640)
        }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
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

    // ── "Add more" ──────────────────────────────────────────────────────────

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
        pressLocation = NSEvent.mouseLocation
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
            if let resolved, target != nil {
                highlight.show(cgRect: resolved.windowBounds)
            } else {
                highlight.hide()
            }
        }
    }

    private func flingReleased() {
        highlight.hide()
        state.aim = .idle
        switch fling.release() {
        case .openOptions:
            state.mode = state.mode == .options ? .collapsed : .options
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
            NSColor.controlAccentColor.setStroke()
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
            } else {
                card
            }
        }
    }

    // ── The card ────────────────────────────────────────────────────────────

    private var card: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                orbBody
                readout
                // ALWAYS present, in every phase — not inside `optionsRow`.
                // That row only appears after a click that only registers once
                // a digest exists, so a pipeline that failed before producing
                // one left a borderless, always-on-top, all-Spaces panel with
                // no close box and no way out but quitting Fovea. The title-bar
                // close box this orb replaced worked in every phase; this is
                // that guarantee, restored.
                //
                // Hidden only while aiming, where it would sit under the
                // cursor mid-fling.
                if !state.isAiming {
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
            }
            if state.mode == .options {
                optionsRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .opacity(state.isAiming ? 0.35 : 1)
        .animation(.spring(duration: 0.25), value: state.mode)
        .animation(.easeOut(duration: 0.15), value: state.isAiming)
    }

    /// The fling handle. A plain circle that pulses while the pipeline works
    /// and settles when the brief is ready to go.
    private var orbBody: some View {
        ZStack {
            Circle()
                .fill(orbColor.gradient)
                .frame(width: 56, height: 56)
            Image(systemName: orbSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
        }
        .modifier(Breathing(active: isWorking))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // The first update IS the press. Not `translation == .zero` —
                    // a fast fling's first event can arrive with the mouse
                    // already moved, and the press would never register.
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
        .help("Drag onto the window running Claude Code to hand the brief over. Click for options.")
    }

    @ViewBuilder private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            // AIMING OUTRANKS THE PHASE. This used to live inside `case .ready`,
            // but a fling also arms on `.failed` — so retrying after a failed
            // handoff showed the error text for the whole drag and never named
            // the target. That is the gesture most likely to be thrown in a
            // hurry, and it was the one without the safety label.
            switch state.aim {
            case .over(let target):
                Label("→ \(target.appName)", systemImage: "arrow.up.forward.app")
                    .font(.title3.weight(.semibold))
                Text("Let go to send the brief there")
                    .font(.caption).foregroundStyle(.secondary)
            case .overNothing:
                Text("Not over a window — let go to cancel")
                    .font(.callout).foregroundStyle(.secondary)
            case .idle:
                phaseReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var phaseReadout: some View {
        switch model.phase {
        case .working(let what):
            Text(what).font(.callout).foregroundStyle(.secondary)
        case .sent:
            Label("Handed over", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let problem):
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // One click to the fix, when the fix is a key. The alternative
                // is a sentence telling somebody to go and find Settings.
                if problem.opensSettings {
                    Button("Open Settings") { actions.onOpenSettings() }
                        .font(.caption)
                }
            }
        case .ready:
            summaryLines
            Text("Drag the orb onto your Claude Code window · click for more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Fovea's reading when it exists; the digest's counts when it does not
    /// (no `GROQ_API_KEY`). Either way, "did it hear me" is answerable here.
    @ViewBuilder private var summaryLines: some View {
        if let summary = model.summary {
            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if let d = model.digest {
            let seconds = Int((d.summary.durationMs / 1000).rounded())
            let apps = d.summary.apps.isEmpty ? "no app" : d.summary.apps.joined(separator: ", ")
            Text("\(seconds)s · \(d.summary.referentCount) things pointed at · \(apps)")
                .font(.callout)
            if model.summaryPending {
                ProgressView().controlSize(.small)
            }
        }
        if let repo = model.digest?.summary.repoHints.first {
            Label(repo, systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.digest != nil {
            Label("No repo named — confirm where this belongs", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 8) {
            Button("Add more") { actions.onExtend() }
                .help("Reopen this session and record more — talk and point again, then tap Right Option to stop.")

            Button("Wanna fix something?") { actions.onSetMode(.expanded) }
                .help("Open the full review — the narration is editable there.")

            Spacer()
        }
        .disabled(isWorking)
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
                    Label("Back to the orb", systemImage: "chevron.down.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            ReviewView(model: model, onExtend: actions.onExtend)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // ── Wording ─────────────────────────────────────────────────────────────

    private var isWorking: Bool {
        if case .working = model.phase { return model.digest == nil }
        return false
    }

    private var orbColor: Color {
        switch model.phase {
        case .working: return .gray
        case .ready: return .indigo
        case .sent: return .green
        case .failed: return .orange
        }
    }

    private var orbSymbol: String {
        switch model.phase {
        case .working: return "eye"
        case .ready: return "eye.fill"
        case .sent: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }
}

/// A soft breathing pulse for the working state — motion says "busy" without a
/// spinner fighting the summary for attention. (Not Overlay's `Pulse`, which is
/// a captured-referent ring; the name is taken.)
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && up ? 1.08 : 1.0)
            .animation(
                active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: up
            )
            .onAppear { up = true }
    }
}
