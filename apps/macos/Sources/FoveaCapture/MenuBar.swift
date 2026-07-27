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
            "record your narration while the key is held"
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
    private var isArmed = false

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)
        rebuildMenu()

        // The recorder drives the icon: filled while a session is live, hollow
        // when merely armed. The menu bar is the one indicator visible even
        // when the overlay is not.
        recorder.onSessionStateChange = { [weak self] recording in
            self?.setIcon(recording: recording)
            self?.rebuildMenu()
        }
    }

    private func setIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        // SF Symbols: a filled eye while capturing, an outline when idle.
        // "Fovea" is the part of the retina that sees detail — the icon is the
        // product's whole thesis in one glyph.
        let name = recording ? "eye.fill" : "eye"
        button.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: recording ? "Fovea — recording" : "Fovea — ready"
        )
        button.image?.isTemplate = true
        button.contentTintColor = recording ? .systemRed : nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let missing = Permission.allCases.filter { !$0.isGranted }

        if missing.isEmpty {
            let state = NSMenuItem(
                title: isArmed
                    ? (recorder.isRecording ? "Recording…" : "Hold Right Option to capture")
                    : "Paused",
                action: nil,
                keyEquivalent: ""
            )
            state.isEnabled = false
            menu.addItem(state)

            menu.addItem(NSMenuItem(
                title: isArmed ? "Pause capture" : "Resume capture",
                action: #selector(toggleArmed),
                keyEquivalent: ""
            ))
        } else {
            // Missing permissions are the whole menu when present — there is
            // nothing else worth showing until they are resolved, and each one
            // states what it is FOR rather than just naming itself (PRD §10:
            // every permission explained with its exact use).
            let header = NSMenuItem(title: "Fovea needs permission to:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

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
            menu.addItem(NSMenuItem(
                title: "Re-check permissions",
                action: #selector(recheck),
                keyEquivalent: ""
            ))
        }

        menu.addItem(.separator())
        let sessions = NSMenuItem(
            title: "Open sessions folder",
            action: #selector(openSessions),
            keyEquivalent: ""
        )
        menu.addItem(sessions)
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

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func toggleArmed() {
        isArmed.toggle()
        // Pausing tears the event tap down rather than ignoring events. An
        // input peripheral that claims to be paused should not still be reading
        // your keystrokes.
        if isArmed { _ = recorder.start() } else { recorder.stop() }
        rebuildMenu()
    }

    /// Ask first, then send them to Settings if asking wasn't enough.
    ///
    /// Asking is what makes the app appear in the privacy pane at all, so this
    /// must happen even when we expect the prompt to be suppressed — otherwise
    /// the Settings link lands the user on a list Fovea isn't in, with nothing
    /// to switch on.
    @objc private func requestPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = Permission(rawValue: raw) else { return }

        permission.request { granted in
            Task { @MainActor in
                if granted {
                    self.rebuildMenu()
                    self.armIfReady()
                } else if let url = permission.settingsURL {
                    // Either already denied, or granting needs Settings anyway
                    // (Accessibility and Screen Recording always do).
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func recheck() {
        rebuildMenu()
    }

    @objc private func openSessions() {
        let dir = recorder.outputRoot ?? FileManager.default.currentDirectoryPath
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc private func quit() {
        recorder.stop()
        NSApplication.shared.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        // A permission granted in Settings should arm us without needing a
        // click here as well.
        if !isArmed, Permission.allCases.allSatisfy(\.isGranted) { armIfReady() }
    }

    /// Called once at launch: arm automatically when everything is granted, so
    /// the common case needs no clicks at all.
    func armIfReady() {
        guard Permission.allCases.allSatisfy(\.isGranted) else {
            rebuildMenu()
            return
        }
        isArmed = recorder.start()
        rebuildMenu()
    }
}
