import AppKit
import Combine
import SwiftUI
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE ORB — the session's last step, on screen instead of in a terminal
//
// A session ends and the orb appears: a small always-on-top glass card, centred,
// showing Deiko's three-line reading of what it heard. Its 56pt COIN — a disc
// wearing the Deiko mark — is the drag handle: fling it onto the window running
// Claude Code and the brief lands in that live session — the app switch, the
// paste of the prompt itself, and the Return that submits it — all inside one
// gesture.
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
// The gesture's decisions live in `DeikoHandoff.FlingGesture`, tested without a
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
    /// The app a brief goes to without a fling — the last one used before
    /// Deiko — named on the review panel's Send button and the coin's action.
    @Published var sendTo: String?
    var isAiming: Bool { if case .idle = aim { return false }; return true }
    /// Aiming AND over something a brief can actually go to.
    var isOverTarget: Bool { if case .over = aim { return true }; return false }
}

/// One below the lasso overlay, and written as arithmetic so the rule cannot drift.
///
/// `.floating` (3) WAS NOT ENOUGH, and the proof was already in the app: the red
/// capture bar is visible over a full-screen Space with the SAME
/// `collectionBehavior` and differs only in level (`Overlay.swift`, `.screenSaver`).
/// A full-screen app's own window is elevated above the floating band, so a
/// non-activating panel at 3 sits behind it however many Spaces it may join —
/// which is why the orb appeared over Chrome and not over a full-screened editor,
/// and `.fullScreenAuxiliary` could not save it: that covers auxiliary panels of
/// the app that OWNS the full-screen window, not a third-party accessory app.
///
/// Expressed as `screenSaver - 1` rather than a literal so that raising the
/// overlay raises the orb with it: the documented invariant is that the lasso
/// overlay stays the topmost thing Deiko draws, and subtraction cannot invert it.
private let orbWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

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
    /// The system drag the fling is upgraded to over a browser, and whether
    /// the destination took the file. See `upgradeToSystemDrag`.
    private let dragSource = CoinDragSource()
    private var dragAttempted = false
    private var personaDroppedOnTarget = false
    private var releasing = false
    /// The last travel the coin reported, so the aim keeps updating while a
    /// system drag is running — the gesture's own `translation` stops arriving
    /// the moment AppKit takes the mouse.
    private var lastTranslation = CGSize.zero

    private var aimPoint: CGPoint?

    /// The last app other than Deiko to come to the front: where ⌘↩ and
    /// VoiceOver's Send action deliver, since neither can aim at a window.
    private var lastApp: NSRunningApplication? {
        didSet { state.sendTo = lastApp?.localizedName }
    }
    private var activationObserver: NSObjectProtocol?

    // ── Presenting ──────────────────────────────────────────────────────────

    /// A session has just closed: show the orb and run the pipeline behind it.
    func present(sessionDir: String, stats: SessionStats? = nil) {
        // Narrate every handoff into the app's log. The first live fling
        // failed with nothing on screen and nothing on disk — the only trace
        // hook lived in a test subcommand, so the field run was undiagnosable
        // and the whole investigation started from "nothing happened". A field
        // run must never be quieter than a harness; this is now the only hook,
        // and Diagnostics (`deiko-capture diagnostics`, or Settings' "Copy
        // diagnostics") is what reads it back, alongside
        // `~/Library/Logs/Deiko/launch.jsonl` directly.
        if Handoff.trace == nil {
            Handoff.trace = { Emit.log("handoff: \($0)") }
        }
        fadeTask?.cancel()
        resizeCount = 0
        state.captured = stats
        trackLastApp()
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
        // A NEW PANEL EVERY TIME, never the last one ordered front again.
        //
        // The orb was one panel for the life of the app, and a panel that has
        // been through a delivered fling stops joining all Spaces: it was key
        // while `Handoff.deliver` activated another app and the Space changed
        // under it, and from then on the window server kept it on ONE Space,
        // whatever `collectionBehavior` said. Every session after the first
        // fling then ended with transcription succeeding and "nothing
        // happening" — the orb was up, on a Space nobody was looking at. Two
        // launches on 18 Sep show the same line: fine until the first
        // "handoff: done", `ordered front but not on screen` ever after.
        //
        // Measured rather than reasoned, because the last fix for this was
        // reasoned (`orbWindowLevel`) and did not hold: fourteen throwaway
        // panels with this exact configuration, put through hide/reshow,
        // resize, becoming key and app activation, ALL reached every Space.
        // The only thing a fresh panel lacks is a past. Everything the orb
        // knows lives in `model` and `state`, so nothing is lost with it.
        window?.close()
        window = makeWindow()
        applyMode()
        window?.orderFrontRegardless()
        installEscapeMonitor()
        verifyOnScreen()
    }

    /// ORDERING FRONT IS A REQUEST, NOT A RESULT.
    ///
    /// The whole of the full-screen bug was the orb being ordered front and
    /// simply not arriving, while the app carried on as though it had. Nothing
    /// in here fixes that — `orbWindowLevel` does — but it turns the next
    /// occurrence from "sometimes nothing appears" into one line of a grep.
    ///
    /// LOG ONLY, never act. A Space transition reads as occluded for a frame or
    /// two, and hiding or re-ordering on that reading would make the orb flicker
    /// for real. Checked a beat later because occlusion is answered by the
    /// window server on a later turn, not synchronously.
    private func verifyOnScreen() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard let window else { return }
            let onScreen = window.isVisible && window.occlusionState.contains(.visible)
            guard !onScreen else { return }
            Emit.log(
                "orb: ordered front but not on screen — isVisible=\(window.isVisible) "
                    + "visible=\(window.occlusionState.contains(.visible)) "
                    + "level=\(window.level.rawValue) frame=\(window.frame) "
                    + "screens=\(NSScreen.screens.count)"
            )
        }

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
        // ended, INCLUDING over a full-screen app. See `orbWindowLevel`.
        panel.level = orbWindowLevel
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
                    onDelete: { [weak self] in self?.deleteSession() },
                    onSend: { [weak self] in self?.sendToLastApp() },
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

    /// How many times the panel has been resized since it appeared, and when
    /// the first one was — see the warning in `setFrame`.
    private var resizeCount = 0
    private var firstResizeAt = Date()

    private func setFrame(to size: NSSize) {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard window.frame.size != size else { return }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        // A settled orb resizes a handful of times: once when it appears, once
        // when the summary lands, once per phase. A LOOP resizes forever, and
        // the difference between "the layout is jittering" and "the layout is
        // fine" is not something anybody can judge by watching it. So count.
        //
        // Instrumented because this was guessed at once already and the guess
        // was wrong: the first fix assumed a spring on the mode change, and the
        // orb kept moving during a phase that never changes mode.
        resizeCount += 1
        if resizeCount == 1 { firstResizeAt = Date() }
        let elapsed = Date().timeIntervalSince(firstResizeAt)
        if resizeCount % 20 == 0 {
            Emit.log(
                "orb: \(resizeCount) resizes in \(String(format: "%.1f", elapsed))s "
                    + "— latest \(Int(size.width))×\(Int(size.height)). This is a layout loop."
            )
        }

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

    /// Delete the session on screen, folder and all.
    ///
    /// The `×` only puts the orb away — deliberately, because a dismissed
    /// session is still on disk and still openable. That left no way at all to
    /// say "this should not exist": a session recorded by mistake, or one that
    /// caught something private, could be dismissed but not removed, and the
    /// screenshots stayed. Confirmed, and refused while the pipeline is still
    /// running, because deleting a directory being written to is the one
    /// mistake worth making impossible rather than merely unlikely.
    private func deleteSession() {
        guard let dir = model.currentSessionDir, extending != dir else { return }
        if case .working = model.phase, model.digest == nil { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete this session?"
        alert.informativeText =
            "The brief and its screenshots go to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // ABOVE THE ORB, explicitly. An alert opens at the modal-panel level
        // (8); the orb sits at `orbWindowLevel` (999) and its expanded panel is
        // bigger than the alert, so the alert opened entirely behind it. The
        // modal loop then blocked the orb while the only way out was invisible
        // — which reads as a hang, in an app that Force Quit does not list.
        //
        // HELD there for as long as the alert is up, not set once. `runModal`
        // resets the level to 8 as it starts (measured: 1000 before, 8 during),
        // so it has to be set from inside the modal loop — and setting it once
        // in there still lost on the FIRST alert after launch and won on the
        // second, which is AppKit resetting it again as it activates this
        // accessory app. Rather than guess when the last reset lands, put it
        // back whenever it is found changed, and say so.
        //
        // ponytail: a 50ms poll for the life of one alert. If the log below
        // pins down the exact reset, replace with a single set after it.
        let above = NSWindow.Level(rawValue: orbWindowLevel.rawValue + 1)
        let hold = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard alert.window.level != above else { return }
                Emit.log("  delete alert was at level \(alert.window.level.rawValue) — raised above the orb")
                alert.window.level = above
                alert.window.orderFrontRegardless()
            }
        }
        RunLoop.main.add(hold, forMode: .modalPanel)
        defer { hold.invalidate() }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // THE ALERT SPINS A NESTED RUNLOOP, so the world can move while it is
        // up: the hotkey tap stays live (`.commonModes`) and main-actor work
        // keeps draining. By the time Delete is clicked, this orb may have been
        // extended into a new hold, or be showing an entirely different
        // session. So act on the directory captured BEFORE the alert — that is
        // what the user was looking at and agreed to delete — and only touch
        // the model if it is still pointing at it.
        //
        // The first version re-read the model here. It would have cancelled a
        // newer session's pipeline and hidden its orb while deleting the old
        // directory, and — because `extending` could be set during the alert —
        // could also return early and do nothing at all, having just told the
        // user it would.
        do {
            guard Sessions.trash(dir) else { throw CocoaError(.fileWriteUnknown) }
            Emit.log("✕ session \((dir as NSString).lastPathComponent) deleted from the review panel")
        } catch {
            Emit.log("✕ could not delete \(dir): \(error.localizedDescription)")
        }
        guard model.currentSessionDir == dir else { return }
        model.cancelPendingWork()
        dismiss()
    }

    /// Put the orb away if it is showing this session, and otherwise leave it
    /// alone. For a session deleted from somewhere else — the menu's discard,
    /// once the recording had already stopped.
    func dismissIfShowing(_ dir: String) {
        guard model.currentSessionDir == dir, window?.isVisible == true else { return }
        model.cancelPendingWork()
        dismiss()
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

    // ── Sending without a fling ─────────────────────────────────────────────

    private func trackLastApp() {
        let isOther = { (app: NSRunningApplication?) in
            app.map { $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.activationPolicy == .regular } ?? false
        }
        if isOther(NSWorkspace.shared.frontmostApplication) { lastApp = NSWorkspace.shared.frontmostApplication }
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard isOther(app) else { return }
            MainActor.assumeIsolated { self?.lastApp = app }
        }
    }

    /// SENDING IS NOT DRAG-ONLY. The fling is the gesture; this is the same
    /// send for a keyboard (⌘↩ on the review panel) and for VoiceOver (the
    /// coin's Send action), into the last app used — its focused field, as a
    /// fling with no drop point would.
    private func sendToLastApp() {
        guard let app = lastApp, !app.isTerminated else { return }
        switch model.phase {
        case .ready, .failed: guard model.digest != nil else { return }
        case .working: guard model.digest == nil else { return }
        case .sent: return
        }
        state.mode = .collapsed
        applyMode()
        send(to: HandoffTarget(pid: app.processIdentifier, appName: app.localizedName ?? "the app"))
    }

    // ── The fling ───────────────────────────────────────────────────────────

    private func flingPressed() {
        dragAttempted = false
        personaDroppedOnTarget = false
        releasing = false
        // STALE TRAVEL IS A FLING NOBODY MADE. The first update of a press can
        // carry a zero translation, and `flingDragged` falls back to the last
        // one when it does — so without this, a click after a long throw
        // measured as a throw and sent the brief to whatever was behind the
        // orb, which is the exact failure `travelThreshold` exists to prevent.
        lastTranslation = .zero
        // Armed whenever a throw can still mean something — which now includes
        // BEFORE the brief exists. `.working` with no digest is the pipeline
        // still rendering; the throw is held and delivered the moment it
        // finishes (`ReviewModel.queuedHandoff`). It used to refuse, and refuse
        // in complete silence: no detached coin, no aim label, no highlight, no
        // message. Whether the gesture worked came down to how fast you reached
        // for the coin after the orb appeared.
        //
        // `.working` WITH a digest is a different thing — a correction being
        // applied, or a send already in flight — and a second throw on top of
        // that is not a throw anyone meant.
        fling.isArmed = {
            switch model.phase {
            case .ready, .failed: return model.digest != nil
            case .working: return model.digest == nil
            case .sent: return false
            }
        }()
        if !fling.isArmed {
            // Said out loud, because this is the branch that made the bug
            // undiagnosable: a refused press left nothing on screen AND nothing
            // on disk, so the report could only ever be "sometimes nothing
            // happens". A field run must never be quieter than a harness.
            Handoff.trace?("fling: not armed — phase \(model.phase), digest \(model.digest == nil ? "absent" : "present")")
            Emit.event(FlingEvent(FlingReport(
                outcome: .notArmed,
                reason: model.digest == nil ? "no-digest" : "phase-\(model.phase)"
            )))
        }
        _ = fling.press()
    }

    /// Upgrade the fling to a real system drag, once, the first time it is
    /// over a browser and there is a persona file to hand over.
    ///
    /// Not at press: a system drag delivers to whatever is under the cursor
    /// when it ends, and a `.md` dropped on a terminal types its path into the
    /// prompt. Browsers are the only destination that gains anything here —
    /// they attach a dropped file and ignore a pasted one.
    private func upgradeToSystemDrag(target: HandoffTarget) {
        guard UserDefaults.standard.object(forKey: "DEIKO_DRAG_HANDOFF") as? Bool ?? true,
              !dragSource.isDragging, !dragAttempted,
              Handoff.needsAttachedImages(target),
              let file = model.currentSessionDir.flatMap({ Personas.file(forSession: $0) }),
              let anchor = coinCursor.dragAnchor,
              let image = coinCursor.snapshot(kind: coinKindForDrag)
        else { return }
        dragAttempted = true

        dragSource.onMoved = { [weak self] _ in
            // AppKit owns the mouse now, but the aim label and the target
            // highlight are still ours to draw. `.zero` means "no fresh
            // translation" — `flingDragged` falls back to the last one so the
            // gesture does not read this as a coin that never travelled.
            self?.flingDragged(.zero)
        }
        dragSource.onEnded = { [weak self] _, operation in
            guard let self else { return }
            // `.none` means nothing took it — the paste path still has to carry
            // the persona, exactly as it did before any of this existed.
            self.personaDroppedOnTarget = operation != []
            Handoff.trace?(operation != []
                           ? "fling: the persona file was accepted by the drop"
                           : "fling: the drop was refused — the persona travels as text")
            self.flingReleased()
        }
        let started = dragSource.begin(
            from: anchor.view,
            file: URL(fileURLWithPath: file),
            image: image,
            at: anchor.pointInWindow
        )
        if started {
            // Two coins otherwise: AppKit draws its own drag image from here on.
            coinCursor.hide()
        }
        Handoff.trace?(started
                       ? "fling: upgraded to a system drag over \(target.appName)"
                       : "fling: could not start a system drag — keeping the paste path")
    }

    /// What the coin looks like for the drag image.
    private var coinKindForDrag: CoinView.Kind {
        state.isOverTarget ? .ready : .overNothing
    }

    private func flingDragged(_ translation: CGSize) {
        if translation != .zero { lastTranslation = translation }
        let travel = translation == .zero ? lastTranslation : translation
        let mouse = NSEvent.mouseLocation
        let cgPoint = cocoaToCG(mouse)
        let overOrb = window?.frame.contains(mouse) ?? false
        let resolved = overOrb ? nil : Handoff.targetUnder(point: cgPoint, excluding: window)

        let decision = fling.drag(
            distance: hypot(travel.width, travel.height),
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
            if let target { upgradeToSystemDrag(target: target) }
        }
    }

    private func flingReleased() {
        // ONE RELEASE PER FLING. While a system drag runs, AppKit owns the
        // mouse and the drag session reports the end; the coin's own gesture
        // may report it too. Sending twice would deliver two briefs.
        guard !releasing else { return }
        guard !dragSource.isDragging else { return }   // the session will call us
        releasing = true
        highlight.hide()
        coinCursor.hide()
        state.aim = .idle
        dragAttempted = false
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
        case .cancelled:
            // Released back over the orb, or over something with no app behind
            // it — the desktop, a menu, one of Deiko's own windows. Deliberate
            // for the first, a miss for the rest, and indistinguishable on disk
            // until now.
            Handoff.trace?("fling: cancelled — released over nothing sendable")
            Emit.event(FlingEvent(FlingReport(outcome: .cancelled, reason: "no-target")))
        case .none, .aiming:
            break
        }
    }

    private func cancelFling() {
        _ = fling.cancel()
        highlight.hide()
        coinCursor.hide()
        state.aim = .idle
        dragAttempted = false
        personaDroppedOnTarget = false
    }

    /// The drop pastes and submits. If either half misses, `prompt.txt` is
    /// still on disk — that is the fallback, and the orb names the file rather
    /// than a command form, because there is no longer a command to type.
    private func send(to target: HandoffTarget) {
        let sessionDir = model.currentSessionDir
        // Read HERE, not inside the closure: `approve` queues the handoff when
        // the brief is still rendering, and a press in the meantime resets it.
        let dropped = personaDroppedOnTarget
        model.approve(handingTo: target.appName) { prompt in
            do {
                // Decided HERE, at the release, from the app actually under the
                // cursor — not baked into the rendered file, which is written
                // long before anybody knows where this is going. A browser gets
                // the image bytes because the model behind it cannot open a
                // path on this Mac; everything else gets the paths, which is
                // what Claude Code reads with its own tools.
                let attach = Handoff.needsAttachedImages(target)
                // Already dropped as a file, so it must not be pasted again —
                // and the short text is what the paste path sends INSTEAD of
                // the file, so that goes too.
                try await Handoff.deliver(
                    to: target,
                    text: attach ? prompt.attachedText : prompt.text,
                    images: attach ? prompt.images : [],
                    // Only where a path is useless. A local agent was already
                    // told where the persona file is and reads it itself;
                    // pasting its contents there too would put the same
                    // instructions in the chat twice.
                    persona: (attach && !dropped) ? prompt.personaText : nil,
                    personaFile: (attach && !dropped) ? prompt.personaFile : nil
                )
                await MainActor.run {
                    Handoff.lastReport.outcome = .delivered
                    Emit.event(FlingEvent(Handoff.lastReport))
                }
            } catch {
                // EMITTED BEFORE THE RETHROW, because this is the path that was
                // silent. `Handoff.deliver` fills the report as it goes and then
                // throws; the sentence below is shown in the orb and dropped, so
                // without this a failed fling left no terminal line in the log
                // at all — a narration that simply stopped.
                await MainActor.run {
                    Handoff.lastReport.outcome = .refused
                    if let handoff = error as? HandoffError {
                        Handoff.lastReport.reason = handoff.reason
                    }
                    Emit.event(FlingEvent(Handoff.lastReport))
                }
                let where_ = sessionDir.map { "\($0)/prompt.txt" } ?? "the session folder"
                throw HandoffError(
                    "\(error.localizedDescription) Your prompt is at \(where_) — "
                        + "paste it into \(target.appName) yourself."
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

    /// The view a system drag is begun from, and where the coin sits inside
    /// it — so the drag image starts where the coin already is rather than
    /// jumping to the cursor.
    var dragAnchor: (view: NSView, pointInWindow: NSPoint)? {
        guard let window, let view = window.contentView else { return nil }
        return (view, NSPoint(x: Self.panelSize.width / 2,
                              y: Self.panelSize.height - Self.coinCenterFromTop))
    }

    /// The coin as it looks right now, for the drag image. A default document
    /// icon would make the gesture read as moving a file; what leaves the card
    /// has to be what lands.
    func snapshot(kind: CoinView.Kind) -> NSImage? {
        let renderer = ImageRenderer(content: CoinView(kind: kind).frame(width: 56, height: 56))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
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
        panel.level = orbWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // NSPanel defaults this to true, and the card beside it sets it false.
        // A fling crosses apps by definition, so the one window that follows the
        // cursor is the last one that may vanish when Deiko deactivates.
        panel.hidesOnDeactivate = false
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
/// you can pick up. Wears the Deiko mark; the failed state swaps it for `!`.
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
    /// 56 is the coin you throw. EVERYTHING inside scales with this, because
    /// the size used to be hard-coded at the bottom of `body` — so asking for
    /// a smaller one with `.frame(width: 26)` clipped the layout box and left
    /// a 56pt coin painting straight over the window's own title bar. The
    /// sidebar's brand row was exactly that bug.
    var diameter: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(fill)
            // Rim light: bright at the top, gone by the middle.
            Circle().fill(
                LinearGradient(
                    colors: [DeikoStyle.coinShine, .clear],
                    startPoint: .top, endPoint: .center
                )
            )
            Circle().strokeBorder(ring, lineWidth: 1.5 * scale)
            glyph
        }
        .frame(width: diameter, height: diameter)
        .shadow(
            color: .black.opacity(held ? 0.45 : 0.3),
            radius: (held ? 14 : 3) * scale,
            y: (held ? 8 : 2) * scale
        )
    }

    /// Everything inside the coin is drawn against the 56pt original.
    private var scale: CGFloat { diameter / 56 }

    private var fill: Color {
        switch kind {
        case .working, .overNothing: return Color.primary.opacity(0.06)
        case .ready: return DeikoStyle.coinFill
        case .failed: return DeikoStyle.needsYou.opacity(0.12)
        }
    }

    private var ring: Color {
        switch kind {
        case .working, .overNothing: return Color.secondary.opacity(0.5)
        case .ready: return DeikoStyle.accent
        case .failed: return DeikoStyle.needsYou
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .working:
            DeikoMark(diameter: 20 * scale, color: Color.secondary)
        case .ready:
            DeikoMark(diameter: 20 * scale, color: DeikoStyle.mark)
        case .overNothing:
            // Dashed and hollow — the mark's dot is what "this is aimed at
            // something" looks like, so over nothing it is absent.
            Circle()
                .strokeBorder(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                )
                .frame(width: 20 * scale, height: 20 * scale)
        case .failed:
            Text("!")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DeikoStyle.needsYou)
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
            w.level = orbWindowLevel
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
            DeikoStyle.accentNS.setStroke()
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
    /// Delete this session's folder outright — the recourse for a session that
    /// should not exist, which until now had none.
    let onDelete: () -> Void
    /// Send to the last app used, without a fling.
    let onSend: () -> Void
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
    /// The placement line names tasks by title, and titles live on the board.
    @ObservedObject private var store = SessionsStore.shared
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
        // The controls Deiko did not draw take the SYSTEM accent — whatever
        // colour the person set in System Settings. One line puts them on
        // the palette instead; see `MainWindowView` for the long version.
        .tint(DeikoStyle.accent)
    }

    /// Report how tall this is, so the window can be exactly that. Measured on
    /// the way out rather than guessed on the way in.
    private func measured<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            // `.topLeading`, NOT `.top`. `.top` means
            // `Alignment(horizontal: .center, vertical: .top)`, so anything
            // that made the card momentarily narrower or wider than 400 —
            // an animating width, a re-layout after a window resize — moved
            // its contents sideways to keep them centred. Pinned to the
            // leading edge, a width that wobbles cannot translate into the
            // coin sliding across the card.
            .frame(width: 400, alignment: .topLeading)
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
        // Material FIRST, card colour over it. The material is what makes this
        // legible over a dark editor and what answers Reduce Transparency
        // without a second code path; the card colour on top pulls it to the
        // paper white every other Deiko surface is made of.
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                        .fill(DeikoStyle.card.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                        .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            // ALWAYS present, in every phase. A pipeline that failed before
            // producing a digest once left a borderless, always-on-top,
            // all-Spaces panel with no close box and no way out but quitting
            // Deiko. Hidden only while aiming, where it would sit under the
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
                .deikoFocusRing(Circle())
                .foregroundStyle(DeikoStyle.ink2)
                .padding(10)
                .help("Put the orb away. The session stays on disk.")
            }
        }
        .opacity(state.isAiming ? 0.35 : 1)
        // NO SPRING ON THE MODE CHANGE.
        //
        // A spring overshoots — that is what makes it feel like a spring — and
        // this one was applied to a view whose WIDTH changes when the mode
        // does: coming back from the 620pt panel, `maxWidth: .infinity`
        // re-resolves to 400 and the spring carried it past 400 and back.
        // With the frame above centring its contents, that read as the coin
        // bouncing left and right until it settled.
        //
        // It bought nothing even when it worked: `body` swaps the whole card
        // for `expandedPanel` on a mode change, so this was animating a layout
        // on its way out of the hierarchy. The aiming fade below stays — it is
        // an opacity change on a view that remains, and easeOut cannot
        // overshoot.
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
                .padding(5)
                .background(DeikoStyle.accentSoft, in: Circle())
                .modifier(Breathing(active: isWorking))
                // THE COIN MUST NOT ANIMATE ITS OWN POSITION.
                //
                // `Breathing` runs a `repeatForever` animation, and a
                // repeating animation is PERSISTENT — it stays the active
                // animation for this subtree. When the panel resizes (it does,
                // once, the moment the first height measurement corrects the
                // default the window opened at), the coin's resolved position
                // moves, SwiftUI animates that move with whatever animation is
                // active, and "forever" turns a one-off 40pt correction into a
                // permanent oscillation. The coin swung left and right until
                // the view was rebuilt — which is exactly why opening the
                // review panel and coming back appeared to fix it: that path
                // resizes to an already-measured height, so `setFrame`
                // early-returns and there is no geometry change to capture.
                //
                // `geometryGroup()` resolves this subtree's geometry as a unit
                // with its parent instead of letting it animate independently.
                // It is the API Apple added for precisely this.
                .geometryGroup()
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
                .accessibilityAction(named: Text("Send to \(state.sendTo ?? "your agent")")) { actions.onSend() }
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
                    .foregroundStyle(DeikoStyle.ink2)
            } else {
                phaseReadout
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var phaseReadout: some View {
        switch model.phase {
        case .working(let what):
            Text(what).deikoTitle(15)
            if let captured = state.captured {
                Text(capturedLine(captured))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DeikoStyle.accentSoft, in: Capsule())
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
            Text("That didn\u{2019}t work").deikoTitle(15)
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
                .foregroundStyle(DeikoStyle.ink2)
            }
        }
    }

    /// Deiko's reading when it exists; the digest's counts when it does not
    /// (no `GROQ_API_KEY`). Either way, "did it hear me" is answerable here.
    @ViewBuilder private var summaryLines: some View {
        // One title line, so the card says what STATE it is in before it says
        // what it heard. Everything under it stays in the system face.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Ready to hand over").deikoTitle(15)
            // WHICH PERSONA IS ABOUT TO SHAPE THIS. The one moment somebody
            // would want to know is the moment before they throw the coin,
            // and until now nothing on this card said it — the answer lived
            // two windows away in Settings.
            if let persona = model.personaName {
                Text(persona)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DeikoStyle.accentSoft, in: Capsule())
                    .help("Your brief will be written up as a \(persona). Change it in Deiko's Personas.")
            }
        }
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
        // WHERE IT IS BEING FILED, on the card most throws leave from. The
        // panel has the menus; this is one line so nobody has to open it to
        // know whether the brief joined its task.
        if let placement = placementLine {
            Text(placement)
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
                .lineLimit(1)
                .help(model.notFiled ? ReviewView.notFiledHelp : "")
        }
        // ONCE, for somebody on their own key: filing now sends what they
        // said to the relay. Here because every brief passes this card, and
        // the next one never shows it again — nothing to dismiss.
        if model.sortingNotice {
            Text("Deiko can now sort briefs into tasks. To do that it sends what you said, a one-line summary, your window and page titles, web addresses (just the host and path, never what's after the ?), open document names and notes on earlier work through its relay to TypeSafe's Jev sorting model; the relay keeps nothing. You can turn this off in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        // WHY THIS ONE READS WORSE, on the card somebody actually looks at.
        //
        // The expanded panel carries this too, but most sessions never open it
        // — the coin is thrown straight off this card. A degraded transcript
        // with no explanation is precisely what turned "your free minutes ran
        // out" into "the transcription is bad" in the inbox. Same sentence,
        // from the same function, so the two surfaces cannot drift.
        if let d = model.digest,
           let sentence = ReviewView.degradedSentence(
               d.summary.degradedReason, degraded: d.summary.degraded == true
           ) {
            Text(sentence)
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.needsYou)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let repo = model.digest?.summary.repoHints.first {
            HStack(spacing: 8) {
                Text(repo)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DeikoStyle.accent.opacity(0.16), in: Capsule())
                Text("drag the coin onto Claude Code · click it for more")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            .padding(.top, 3)
        } else if model.digest != nil {
            Label("No repo named — confirm where this belongs", systemImage: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.needsYou)
            Text("drag the coin onto Claude Code · click it for more")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
        }
    }

    // ── The sent pill ───────────────────────────────────────────────────────

    /// The card collapses to a capsule on the way out the door — less to read
    /// once there is nothing left to decide. Fades 2.5s later.
    private var sentPill: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(DeikoStyle.sentGreen.opacity(0.18))
                Circle()
                    .strokeBorder(DeikoStyle.sentGreen, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DeikoStyle.sentGreen)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(sentLine)
                    .font(.system(size: 13))
                // What was pasted carries no task, whatever the filing does next.
                if model.sentUnfiled {
                    Text("Sent before Deiko finished filing it")
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(DeikoStyle.hairline, lineWidth: 1))
        )
        // Centred in the 400pt width but NOT stretched to it — the canvas
        // draws a pill on its own, and a pill inside an invisible card carries
        // the card's shadow with it.
        .frame(maxWidth: .infinity)
        .accessibilityLabel(model.sentUnfiled ? "\(sentLine). Sent before Deiko finished filing it" : sentLine)
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
                        .foregroundStyle(DeikoStyle.mark)
                }
                .buttonStyle(.plain)
                .deikoFocusRingLoose()
                Spacer()
                Button {
                    actions.onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .deikoFocusRingLoose(radius: 10)
                .foregroundStyle(.tertiary)
                .help("Put the orb away. The session stays on disk.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            ReviewView(
                model: model,
                onExtend: actions.onExtend,
                onCollapse: { actions.onSetMode(.collapsed) },
                onDelete: actions.onDelete,
                sendTo: state.sendTo,
                onSend: actions.onSend
            )
        }
        // The design's panel, exactly. Nothing inside may grow it: the content
        // scrolls and the footer is pinned, so "Good to go" is on screen for a
        // one-line narration and a thirty-line one alike.
        .frame(width: 620, height: 640)
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                        .fill(DeikoStyle.card.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.panelRadius)
                        .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
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

    /// Nothing until a placement exists — with no relay, only odds and ends
    /// or a short follow-up ever make one. Once one exists there is always a
    /// line — "A new task" when it joined nothing — so the card does not
    /// shrink under the coin as "Filing…" goes.
    private var placementLine: String? {
        if model.placing { return "Filing…" }
        if model.notFiled { return "Not filed" }
        if !model.openCandidates.isEmpty { return "Which task? Open the card to choose" }
        if model.context?.isOdds == true { return "In odds and ends" }
        if let joined = model.joinedTask { return "Carries on from \(joined)" }
        return model.context == nil ? nil : "A new task"
    }

    private var accessibilitySummary: String {
        switch model.phase {
        case .working: return "Deiko brief, preparing"
        case .ready: return "Deiko brief, ready. Drag onto your coding agent's window, or use the Send action, to send it. Click to review."
        case .failed: return "Deiko brief, needs attention"
        case .sent: return "Deiko brief, handed over"
        }
    }
}

/// A soft breathing pulse for the working state — motion says "busy" without a
/// spinner fighting the summary for attention.
///
/// **Opacity, never scale.** This used to scale the coin 1.0↔1.06. A 6% swell
/// on a 56pt disc moves each edge about 1.7pt outward and back, once a second,
/// for the whole twenty seconds a transcription takes — and because `CoinView`
/// carries a drop shadow, `scaleEffect` scaled the shadow's blur and its
/// y-offset along with it. Watched rather than glanced at, that does not read
/// as breathing. It reads as the coin twitching left and right, and it was
/// reported as a bug twice.
///
/// The design canvas offers exactly this form as its Reduce Motion
/// alternative. Making it the only form costs nothing — the coin still says
/// "busy" — and it cannot move anything, because no geometry changes at all.
///
/// (Not Overlay's `Pulse`, which is a captured-referent ring; the name is
/// taken.)
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        let animate = active && !DeikoStyle.reduceMotion
        content
            .opacity(animate && dim ? 0.55 : 1)
            .animation(
                animate ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = true }
    }
}
