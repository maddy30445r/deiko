import AppKit
import AVFoundation
import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────────────
// THE MENU-BAR SHELL
//
// [BOX] work — boilerplate around the capture core, deliberately thin.
//
// It exists for two reasons beyond looking like an app:
//
//   1. PERMISSIONS. macOS attributes privacy requests to the *responsible*
//      process, which for a terminal-launched binary is the terminal (or, from
//      an IDE's embedded shell, Electron). Running as a real bundle makes Fovea
//      answer for itself, so the four permissions attach to Fovea.app and stop
//      depending on which terminal happened to start it.
//
//   2. It is the honest place to show what state capture is in. The overlay
//      says "recording right now"; the status item says "armed and listening
//      for the hotkey", which is a different and equally important claim.
// ─────────────────────────────────────────────────────────────────────────────

/// The four things macOS must let us do, and what each is actually for. The
/// strings are user-facing — they appear in the menu when something is missing.
enum Permission: String, CaseIterable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case microphone = "Microphone"
    case speech = "Speech Recognition"

    /// The canvas's rule: each reason is the DATA the permission takes,
    /// stated plainly — that is what earns trust, not reassurance copy.
    var purpose: String {
        switch self {
        case .accessibility:
            "reads the label under your cursor, and watches for the hotkey"
        case .screenRecording:
            "crops a screenshot of what you point at"
        case .microphone:
            "records your narration while you point — deleted once your brief is made"
        case .speech:
            "turns your words into text, on this Mac"
        }
    }

    /// SF Symbol for the first-run row's glyph tile.
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic"
        case .speech: "waveform"
        }
    }

    /// Deep-link into the exact Settings pane. Saves the user hunting.
    var settingsURL: URL? {
        let pane = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    /// Checked without prompting, so opening the menu never triggers a dialog.
    var isGranted: Bool {
        switch self {
        case .accessibility:
            AXIsProcessTrusted()
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech:
            SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// Actually ASK. This is not the same as checking, and the difference is
    /// user-visible: macOS does not list an app in a privacy pane until that
    /// app has requested the permission at least once. Fovea was absent from
    /// the Microphone list entirely — checking `authorizationStatus` never
    /// prompts, and the mic is only opened once a session starts, which cannot
    /// happen while the app is unarmed. Nothing to toggle, so nothing to grant.
    ///
    /// Requesting registers us with TCC and shows the system prompt. If the
    /// user has already denied it, the prompt does not reappear — hence the
    /// Settings deep-link afterwards.
    func request(completion: @escaping @Sendable (Bool) -> Void) {
        switch self {
        case .accessibility:
            // The only one with no async callback: it prompts and returns the
            // status as it was, since granting requires a trip to Settings.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            completion(AXIsProcessTrustedWithOptions(options))
        case .screenRecording:
            completion(CGRequestScreenCaptureAccess())
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { completion($0 == .authorized) }
        }
    }

    /// Ask first, then send them to Settings if asking wasn't enough.
    ///
    /// Asking is what makes the app appear in the privacy pane at all, so this
    /// must happen even when we expect the prompt to be suppressed — otherwise
    /// the Settings link lands the user on a list Fovea isn't in, with nothing
    /// to switch on. That was the reported bug: Fovea was absent from the
    /// Microphone pane entirely because nothing had ever requested it.
    ///
    /// On `Permission` rather than on `MenuBar` because the welcome window asks
    /// the same question, and two implementations of "how do we request this"
    /// is two places for that hard-won detail to be forgotten.
    @MainActor
    func ask() async {
        let granted = await withCheckedContinuation { continuation in
            request { continuation.resume(returning: $0) }
        }
        guard !granted, let url = settingsURL else { return }
        // Either already denied, or granting needs Settings anyway
        // (Accessibility and Screen Recording always do).
        NSWorkspace.shared.open(url)
    }
}

/// Quit and come back.
///
/// Screen Recording is only re-read at process start, so "grant it then
/// relaunch" is the actual flow — done for the user rather than left as an
/// instruction they have to follow by hand. Shared because both the menu and
/// the welcome window offer it.
@MainActor
enum Relauncher {
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor
final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder: Recorder

    /// Set once the event tap is up. Not a user-facing concept and deliberately
    /// not a toggle: there used to be Pause/Resume here, and it was both
    /// meaningless ("pause what? I'm not recording") and broken — `menuWillOpen`
    /// re-armed automatically, so a pause silently undid itself the next time
    /// the menu was opened. Fovea listens whenever it has permission to, and
    /// Quit is how you stop it.
    private var isListening = false

    /// Held for the app's lifetime, not created per session: a second session
    /// while the orb is still up reuses it rather than stacking orbs.
    private let review = OrbController()
    private let settings = SettingsWindowController()
    private let welcome = WelcomeWindowController()

    /// Whether Screen Recording was still ungranted when this process came up.
    /// Granted-now + missing-then = a relaunch is pending, and that is the ONE
    /// moment the menu offers Relaunch Fovea.
    private var screenRecordingMissingAtLaunch = false
    private var relaunchPending: Bool {
        screenRecordingMissingAtLaunch && Permission.screenRecording.isGranted
    }

    /// The `● Capturing · 0:43` header of the OPEN menu, so a timer can keep
    /// its clock honest while the user is looking at it.
    private weak var capturingItem: NSMenuItem?
    private var menuClock: Timer?

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        screenRecordingMissingAtLaunch = !Permission.screenRecording.isGranted

        // Any change in the recorder — hold started, hold ended, session
        // opened — redraws both the icon and the menu from `recorder` itself.
        // Nothing about session state is mirrored into this class, so there is
        // nothing to fall out of sync.
        recorder.onStateChange = { [weak self] in
            self?.refresh()
        }
        // Stop talking and the brief comes to you. Hung off the recorder rather
        // than the Stop menu item so it fires however the session ended — hotkey
        // tap, menu, or the silence watchdog.
        recorder.onSessionClosed = { [weak self] dir, stats in
            self?.review.present(sessionDir: dir, stats: stats)
        }
        // "Point at more" reopens the session the orb is showing and starts
        // another hold. Routed through the recorder rather than done in the
        // window, because reopening has to restore the session's counters and
        // tell the hotkey a session is live again.
        review.onExtend = { [weak self] dir in
            self?.recorder.resumeForExtraHold(dir: dir) ?? false
        }
        // The start gesture, thrown while the orb is up, adds to the session
        // the orb is showing — the redesign's replacement for the orb's old
        // "Add more" button.
        recorder.onStartGestureWhileIdle = { [weak self] in
            self?.review.extendPresentedSession() ?? false
        }
        review.onOpenSettings = { [weak self] in self?.settings.present() }
        // Remove the MCP entry earlier versions wrote. Nothing registers
        // anything any more; this is only clearing up after what did.
        LegacyMCP.cleanUpOnce()

        startListeningIfPermitted()
        refresh()

        // First run says something. Before this, a new install put an eye in
        // the menu bar and waited — and the hotkey did nothing, because no tap
        // is installed until every grant is in.
        welcome.onOpenSettings = { [weak self] in self?.settings.present() }
        welcome.presentIfNeeded()

        // Detached, and nothing waits for it: the menu is already usable, and a
        // slow or absent network must not delay the app coming up. When it
        // finds something the menu rebuilds and grows one item.
        Task { @MainActor in
            await Update.check()
            if Update.available != nil { rebuildMenu() }
        }
    }

    private func refresh() {
        setIcon()
        rebuildMenu()
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        // The fovea mark — the same ring-and-dot the orb's coin wears, so the
        // status item and the orb are visibly the same object. "Fovea" is the
        // part of the retina that sees detail; the mark is the product's whole
        // thesis in one glyph: "I'm pointing at this."
        //
        // THE THIRD STATE EARNS ITS PLACE. Without a grant, the hotkey does
        // nothing: `startListeningIfPermitted` returns early and no tap is
        // installed. The icon used to look identical whether Fovea was armed or
        // completely dead, so a new install presented as a working app that
        // silently ignored every gesture — and the only explanation lived
        // inside a menu nobody had a reason to open.
        //
        // Each state is a SHAPE change, not a tint: capturing swells the dot
        // to fill the ring (and goes record-red), blocked hangs an `!` off the
        // ring. Colour is never the only signal.
        let recording = recorder.isRecording
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)

        let image = FoveaStyle.menuBarIcon(recording: recording, blocked: blocked)
        image.accessibilityDescription =
            blocked
            ? "Fovea — needs permission" : (recording ? "Fovea — capturing" : "Fovea — ready")
        button.image = image
        // The template above is black; the tint is applied here, where AppKit
        // resolves it against the menu bar's own appearance. Nil = follow the
        // bar, which is what "ready" should do.
        button.contentTintColor =
            recording ? FoveaStyle.recordRedNS : (blocked ? FoveaStyle.needsYouNS : nil)
        // Read aloud by VoiceOver, and shown on hover — the only place the
        // reason is available without opening the menu.
        button.toolTip = blocked ? "Fovea needs permission to work — click to grant" : nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let missing = Permission.allCases.filter { !$0.isGranted }

        if !missing.isEmpty {
            addPermissionItems(missing, to: menu)
        } else if relaunchPending, recorder.sessionDir == nil {
            // Never while a session is open — a live session needs its Stop
            // item more than it needs relaunch advice, and relaunching would
            // kill the recording anyway.
            // Screen Recording was granted this launch. The system reports it
            // granted immediately, but ScreenCaptureKit in THIS process keeps
            // failing until a restart — and that failure is silent: crops come
            // back with no path and no withheld reason. So the relaunch leads
            // the menu at exactly the moment it applies, and ONLY then — an
            // always-there Relaunch item quietly says "this app breaks".
            menu.addItem(disabled("Relaunch to finish"))
            menu.addItem(disabled("Screen Recording takes effect after a relaunch"))
            menu.addItem(NSMenuItem(
                title: "Relaunch Fovea",
                action: #selector(relaunch),
                keyEquivalent: ""
            ))
        } else {
            addCaptureItems(to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Open sessions folder",
            action: #selector(openSessionRoot),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem(
            title: "Getting started…",
            action: #selector(openWelcome),
            keyEquivalent: ""
        ))
        // Only when there is one. An always-present "Check for updates…" is a
        // chore the user has to perform; this is an answer they already have.
        if let update = Update.available {
            menu.addItem(NSMenuItem(
                title: "Update to \(update.version)…",
                action: #selector(openUpdatePage),
                keyEquivalent: ""
            ))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fovea", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        // Rebuild every time it opens. Permission state changes outside this
        // process — the user flips a switch in Settings — so a menu built once
        // at launch confidently reports stale facts: it listed Speech
        // Recognition as missing while Settings showed it granted.
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The normal menu: a state block first, then the utility tail. Idle names
    /// the gesture, so the menu doubles as the cheat-sheet. Capturing leads
    /// with the red dot and a LIVE mono timer, and Stop is the emphasised item.
    ///
    /// Cut, per the redesign: the session id line (nobody types it anywhere —
    /// it lives in the sessions folder) and "Reveal this session" (the orb
    /// arrives the moment a session closes; "Open sessions folder" covers the
    /// archaeology case).
    private func addCaptureItems(to menu: NSMenu) {
        if recorder.sessionDir != nil {
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = capturingHeader()
            menu.addItem(header)
            capturingItem = header

            let referents = recorder.referentCount
            menu.addItem(disabled(
                "\(referents) thing\(referents == 1 ? "" : "s") pointed at so far"
            ))

            let stop = NSMenuItem(
                title: "Stop capturing — tap right ⌥",
                action: #selector(stopSession),
                keyEquivalent: ""
            )
            // The one action that matters mid-session, bold so it reads as the
            // default even though NSMenu has no real notion of one.
            stop.attributedTitle = NSAttributedString(
                string: "Stop capturing — tap right ⌥",
                attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]
            )
            menu.addItem(stop)
        } else {
            capturingItem = nil
            menu.addItem(disabled(
                isListening
                    ? "Ready — ⌥⌥ to start"
                    : "Not listening — could not create the event tap"
            ))
            if isListening {
                menu.addItem(disabled("double-tap right Option, then talk and point"))
            }
        }
    }

    /// `● Capturing · 0:43` — the dot in record red, the timer in mono.
    private func capturingHeader() -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: FoveaStyle.recordRedNS]
        )
        line.append(NSAttributedString(
            string: "Capturing",
            attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]
        ))
        if let ms = recorder.sessionElapsedMs {
            let total = Int(ms / 1000)
            line.append(NSAttributedString(
                string: String(format: " · %d:%02d", total / 60, total % 60),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)]
            ))
        }
        return line
    }

    /// Missing permissions are the whole menu when present — there is nothing
    /// else worth showing until they are resolved. The header says what the
    /// user actually experiences ("the hotkey is doing nothing"), in words,
    /// not an icon tint.
    private func addPermissionItems(_ missing: [Permission], to menu: NSMenu) {
        menu.addItem(disabled("The hotkey is doing nothing"))
        menu.addItem(disabled(
            missing.count == 1
                ? "one permission is missing"
                : "\(missing.count) permissions are missing"
        ))

        for permission in missing {
            let item = NSMenuItem(
                title: "Grant \(permission.rawValue) — \(permission.purpose)",
                action: #selector(requestPermission(_:)),
                keyEquivalent: ""
            )
            item.representedObject = permission.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // One click for the whole set. Four rows to work through one at a time
        // was the friction being reported — this asks for each in turn and only
        // falls back to Settings for the ones a prompt cannot grant.
        menu.addItem(NSMenuItem(
            title: "Grant permissions…",
            action: #selector(grantAll),
            keyEquivalent: ""
        ))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    /// The one button. Closes the session out — which includes waiting for crops
    /// still being written — and the review window takes it from there, via
    /// `onSessionClosed`. This used to reveal the session folder in Finder; a
    /// folder of JSON and PNGs was the best answer available before there was a
    /// window that could show what is in it.
    @objc private func stopSession() {
        Task { @MainActor in
            _ = await recorder.stopSession()
        }
    }

    @objc private func openUpdatePage() {
        Update.openReleasePage()
    }

    /// Ask for every missing permission in turn.
    @objc private func grantAll() {
        Task { @MainActor in
            for permission in Permission.allCases where !permission.isGranted {
                await ask(permission)
            }
            startListeningIfPermitted()
            refresh()
        }
    }

    @objc private func requestPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = Permission(rawValue: raw) else { return }
        Task { @MainActor in
            await ask(permission)
            startListeningIfPermitted()
            refresh()
        }
    }

    private func ask(_ permission: Permission) async {
        await permission.ask()
    }

    @objc private func relaunch() {
        Relauncher.relaunch()
    }

    @objc private func openSettings() {
        settings.present()
    }

    @objc private func openWelcome() {
        welcome.onOpenSettings = { [weak self] in self?.settings.present() }
        welcome.present()
    }

    @objc private func openSessionRoot() {
        // The root, not the open session — "Reveal this session" is the item
        // for that, and it only exists when there is one.
        let root = recorder.sessionRoot
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    @objc private func quit() {
        // Route through the same close-out as the button, so quitting can never
        // truncate a session that still has crops in flight.
        Task { @MainActor in
            await recorder.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A permission granted in Settings should take effect without a click
        // here as well. This only ever STARTS listening — it can no longer
        // fight a user decision, because there is no longer a way to pause.
        // Listening first, ONE rebuild after: each rebuild costs four tccd
        // round-trips for the permission checks, and this path used to do it
        // twice per menu open.
        startListeningIfPermitted()
        rebuildMenu()

        // The capturing header carries a clock; a menu held open for a minute
        // must not claim 0:43 the whole time. `.common` because menu tracking
        // runs the loop in a mode plain timers never fire in.
        menuClock?.invalidate()
        if capturingItem != nil {
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let item = self.capturingItem else { return }
                    item.attributedTitle = self.capturingHeader()
                }
            }
            RunLoop.main.add(clock, forMode: .common)
            menuClock = clock
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuClock?.invalidate()
        menuClock = nil
    }

    /// Bring the event tap up once everything is granted. Idempotent. The
    /// caller rebuilds the menu.
    private func startListeningIfPermitted() {
        guard !isListening, Permission.allCases.allSatisfy(\.isGranted) else { return }
        isListening = recorder.start()
        if !isListening {
            Emit.event(ErrorEvent(
                "could not create the event tap",
                hint: "Accessibility is granted but the tap was refused. Quit and relaunch Fovea; if it persists, remove Fovea from Accessibility and add it again."
            ))
        }
    }
}

private extension NSFont {
    /// The menu font at a different weight — NSFont has no variant API, and
    /// the system font at menu size is the menu font.
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
