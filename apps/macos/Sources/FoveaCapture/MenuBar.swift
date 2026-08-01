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

    var purpose: String {
        switch self {
        case .accessibility:
            "read what you point at, and watch for the hotkey"
        case .screenRecording:
            "capture the crop around what you point at"
        case .microphone:
            "record your narration while a session is capturing"
        case .speech:
            "work out when each word was said, on-device"
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

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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
        // Put back a connection that has gone missing. Two ordinary things
        // break it: Claude Code rewrites `~/.claude.json` wholesale and can drop
        // our entry, and moving Fovea (to /Applications, say) invalidates the
        // absolute paths the entry points at. Both look identical to the user —
        // the brief stops arriving — and both are repaired by rewriting the
        // entry. Only clients they actually connected are touched.
        Connectors.selfHeal()

        startListeningIfPermitted()
        refresh()

        // First run says something. Before this, a new install put an eye in
        // the menu bar and waited — and the hotkey did nothing, because no tap
        // is installed until every grant is in.
        welcome.onOpenSettings = { [weak self] in self?.settings.present() }
        welcome.presentIfNeeded()
    }

    private func refresh() {
        setIcon()
        rebuildMenu()
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        // SF Symbols: a filled eye while recording, an outline otherwise.
        // "Fovea" is the part of the retina that sees detail — the icon is the
        // product's whole thesis in one glyph.
        //
        // THE THIRD STATE EARNS ITS PLACE. Without a grant, the hotkey does
        // nothing: `startListeningIfPermitted` returns early and no tap is
        // installed. The icon used to look identical whether Fovea was armed or
        // completely dead, so a new install presented as a working app that
        // silently ignored every gesture — and the only explanation lived
        // inside a menu nobody had a reason to open.
        let recording = recorder.isRecording
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)

        let symbol = blocked ? "eye.trianglebadge.exclamationmark" : (recording ? "eye.fill" : "eye")
        let description =
            blocked
            ? "Fovea — needs permission" : (recording ? "Fovea — recording" : "Fovea — ready")

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.contentTintColor = recording ? .systemRed : (blocked ? .systemOrange : nil)
        // Read aloud by VoiceOver, and shown on hover — the only place the
        // reason is available without opening the menu.
        button.toolTip = blocked ? "Fovea needs permission to work — click to grant" : nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let missing = Permission.allCases.filter { !$0.isGranted }

        if missing.isEmpty {
            addCaptureItems(to: menu)
        } else {
            addPermissionItems(missing, to: menu)
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
        // ALWAYS present, not only while permissions are missing.
        //
        // Screen Recording takes effect only after a relaunch, and it used to
        // live in the permissions branch — which `rebuildMenu` stops drawing the
        // moment the last grant lands. So the button vanished at exactly the
        // point it applied, and the failure it fixes is silent: ScreenCaptureKit
        // keeps failing in the running process, crops come back with no path and
        // no withheld reason, and the orb reports "0 screenshots going" with
        // nothing anywhere saying why.
        menu.addItem(NSMenuItem(
            title: "Relaunch Fovea",
            action: #selector(relaunch),
            keyEquivalent: ""
        ))
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

    /// The normal menu. Exactly one button ever appears here — Stop session —
    /// and only when there is a session to stop.
    private func addCaptureItems(to menu: NSMenu) {
        if let id = recorder.sessionId {
            menu.addItem(disabled("Session \(id)"))

            let referents = recorder.referentCount
            menu.addItem(disabled(
                (recorder.isRecording ? "  ● Recording · " : "  ")
                    + "\(referents) referent\(referents == 1 ? "" : "s")"
            ))

            menu.addItem(NSMenuItem(
                title: "Stop session",
                action: #selector(stopSession),
                keyEquivalent: ""
            ))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Reveal this session",
                action: #selector(revealSession),
                keyEquivalent: ""
            ))
        } else {
            menu.addItem(disabled(
                isListening
                    ? "Double-tap Right Option to start capturing"
                    : "Not listening — could not create the event tap"
            ))
        }
    }

    /// Missing permissions are the whole menu when present — there is nothing
    /// else worth showing until they are resolved, and each one states what it
    /// is FOR rather than just naming itself (PRD §10: every permission
    /// explained with its exact use).
    private func addPermissionItems(_ missing: [Permission], to menu: NSMenu) {
        menu.addItem(disabled("Fovea needs permission to:"))

        for permission in missing {
            let item = NSMenuItem(
                title: "  \(permission.rawValue) — \(permission.purpose)",
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

    @objc private func revealSession() {
        guard let dir = recorder.sessionDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
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
