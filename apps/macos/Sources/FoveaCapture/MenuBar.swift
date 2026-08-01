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
        recorder.onSessionClosed = { [weak self] dir in
            self?.review.present(sessionDir: dir)
        }
        // "Forgot something?" reopens the session the window is showing and
        // starts another hold. Routed through the recorder rather than done in
        // the window, because reopening has to restore the session's counters
        // and tell the hotkey a session is live again.
        review.onExtend = { [weak self] dir in
            self?.recorder.resumeForExtraHold(dir: dir) ?? false
        }
        // Put back a connection that has gone missing. Two ordinary things
        // break it: Claude Code rewrites `~/.claude.json` wholesale and can drop
        // our entry, and moving Fovea (to /Applications, say) invalidates the
        // absolute paths the entry points at. Both look identical to the user —
        // the brief stops arriving — and both are repaired by rewriting the
        // entry. Only clients they actually connected are touched.
        Connectors.selfHeal()

        startListeningIfPermitted()
        refresh()
    }

    private func refresh() {
        setIcon()
        rebuildMenu()
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        // SF Symbols: a filled eye while the key is down, an outline otherwise.
        // "Fovea" is the part of the retina that sees detail — the icon is the
        // product's whole thesis in one glyph.
        let recording = recorder.isRecording
        button.image = NSImage(
            systemSymbolName: recording ? "eye.fill" : "eye",
            accessibilityDescription: recording ? "Fovea — recording" : "Fovea — ready"
        )
        button.image?.isTemplate = true
        button.contentTintColor = recording ? .systemRed : nil
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
        // Screen Recording in particular only takes effect after a relaunch,
        // and there was previously no way to relaunch from inside the app.
        menu.addItem(NSMenuItem(
            title: "Relaunch Fovea",
            action: #selector(relaunch),
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

    /// Ask first, then send them to Settings if asking wasn't enough.
    ///
    /// Asking is what makes the app appear in the privacy pane at all, so this
    /// must happen even when we expect the prompt to be suppressed — otherwise
    /// the Settings link lands the user on a list Fovea isn't in, with nothing
    /// to switch on. That was the reported bug: Fovea was absent from the
    /// Microphone pane entirely because nothing had ever requested it.
    private func ask(_ permission: Permission) async {
        let granted = await withCheckedContinuation { continuation in
            permission.request { continuation.resume(returning: $0) }
        }
        guard !granted, let url = permission.settingsURL else { return }
        // Either already denied, or granting needs Settings anyway
        // (Accessibility and Screen Recording always do).
        NSWorkspace.shared.open(url)
    }

    @objc private func relaunch() {
        // Screen Recording is only re-read at process start, so "grant it then
        // relaunch" is the actual flow — done here rather than left as an
        // instruction the user has to follow by hand.
        let bundle = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    @objc private func openSettings() {
        settings.present()
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
