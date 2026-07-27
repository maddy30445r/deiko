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
}

@MainActor
final class MenuBar: NSObject, NSApplicationDelegate {
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
                    action: #selector(openSettings(_:)),
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

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = Permission(rawValue: raw),
              let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
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
