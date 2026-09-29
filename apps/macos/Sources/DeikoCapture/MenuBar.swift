import AppKit
import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers
import DeikoGesture
import DeikoHandoff

/// The four permissions macOS must grant, and what each is for. The strings are user-facing: they
/// appear in the menu when something is missing.
enum Permission: String, CaseIterable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case microphone = "Microphone"
    case speech = "Speech Recognition"

    /// Each reason states the data the permission takes, plainly.
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

    /// Deep-link into the exact Settings pane.
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

    /// Actually ask, which differs from checking: macOS lists an app in a privacy pane only after it has
    /// requested the permission once, and `authorizationStatus` never prompts. The microphone is opened
    /// only once a session starts, which cannot happen while the app is unarmed, so without this Deiko
    /// would be absent from the Microphone list.
    ///
    /// Requesting registers with TCC and shows the system prompt. If the user already denied it the
    /// prompt does not reappear, hence the Settings deep-link afterwards.
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

    /// Has this install ever requested this permission? Microphone and Speech carry it natively
    /// (`.notDetermined` means the dialog was never shown). The other two are a bare true/false, so it is
    /// remembered here, written when the request is made because it records that the dialog was seen,
    /// not the answer (`isGranted`'s job).
    var hasBeenAsked: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
        case .speech:
            return SFSpeechRecognizer.authorizationStatus() != .notDetermined
        case .accessibility, .screenRecording:
            return UserDefaults.standard.bool(forKey: "DEIKO_ASKED_\(rawValue)")
        }
    }

    private func rememberAsked() {
        switch self {
        case .microphone, .speech:
            break  // the system remembers for these
        case .accessibility, .screenRecording:
            UserDefaults.standard.set(true, forKey: "DEIKO_ASKED_\(rawValue)")
        }
    }

    /// One action per click; see `PermissionStep`. The first click requests: asking is what makes the
    /// app appear in the privacy pane at all. The second click, on a permission whose dialog has been
    /// seen and will not return, opens Settings. Doing both at once would leave a system alert, which does
    /// not close when the permission is granted elsewhere, behind the opening Settings window.
    @MainActor
    func ask() async {
        switch PermissionStep.next(granted: isGranted, asked: hasBeenAsked) {
        case .nothing:
            return
        case .request:
            rememberAsked()
            _ = await withCheckedContinuation { continuation in
                request { continuation.resume(returning: $0) }
            }
        case .openSettings:
            guard let url = settingsURL else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// Quit and come back. Screen Recording is only re-read at process start, so "grant it then relaunch"
/// is the real flow; this does it for the user. Shared by the menu and the welcome window.
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

/// The menu-bar shell around the capture core: the status item, its menu, and the app delegate.
///
/// It runs as a real bundle so macOS attributes the four privacy permissions to Deiko.app rather than to
/// whichever terminal or IDE shell launched the binary. The status item also shows that capture is armed
/// and listening for the hotkey, a different claim from the overlay's "recording right now".
@MainActor
final class MenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// The menu-bar icon's hover hint, in the same bubble as every other tip.
    private let iconTip = HoverTip()
    private let recorder: Recorder

    /// Set once the event tap is up. Not a user-facing concept and deliberately not a toggle: Deiko
    /// listens whenever it has permission to, and Quit is how you stop it.
    private var isListening = false

    /// Held for the app's lifetime, not created per session: a second session
    /// while the orb is still up reuses it rather than stacking orbs.
    private let review = OrbController()
    /// The app window: the board, personas and every setting, in one place.
    private let main = MainWindowController()
    private let welcome = WelcomeWindowController()

    /// Whether Screen Recording was still ungranted when this process came up. Granted now but missing
    /// then means a relaunch is pending, the one moment the menu offers Relaunch Deiko.
    private var screenRecordingMissingAtLaunch = false
    private var relaunchPending: Bool {
        screenRecordingMissingAtLaunch && Permission.screenRecording.isGranted
    }

    /// The `● Capturing · 0:43` header of the OPEN menu, so a timer can keep
    /// its clock honest while the user is looking at it.
    private weak var capturingItem: NSMenuItem?
    private var menuClock: Timer?
    /// One menu, refilled in place: the menu already opening is the old one, so a new `NSMenu` built in
    /// `menuWillOpen` would never show, and the capturing clock would tick on a copy nobody sees.
    private let menu = NSMenu()
    /// The permission answers the menu was last built from; the poll rebuilds
    /// only when they change.
    private var builtFor: [Bool] = []
    /// Notices a permission granted or revoked in System Settings while Deiko is running. Lives for
    /// the life of the app, unlike `menuClock`.
    private var permissionPoll: Timer?
    /// The interval `permissionPoll` is running at, so `refresh()` rebuilds the timer only when it changes.
    private var pollInterval: TimeInterval = 0

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
    }

    func install() {
        // First, before any window exists: setting it after a window is on screen repaints that window
        // mid-flight.
        Appearance.selected.apply()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: iconTip, userInfo: nil
        ))
        screenRecordingMissingAtLaunch = !Permission.screenRecording.isGranted

        // Any change in the recorder redraws the icon and the menu from `recorder` itself. Nothing about
        // session state is mirrored here, so nothing can fall out of sync.
        recorder.onStateChange = { [weak self] in
            self?.refresh()
        }
        // Hung off the recorder rather than the Stop menu item so it fires however the session ended:
        // hotkey tap, menu, or the silence watchdog.
        recorder.onSessionClosed = { [weak self] dir, stats in
            self?.review.present(sessionDir: dir, stats: stats)
        }
        // "Point at more" reopens the session the orb is showing and starts another hold. Routed through
        // the recorder because reopening must restore the session's counters and tell the hotkey a
        // session is live again.
        review.onExtend = { [weak self] dir in
            self?.recorder.resumeForExtraHold(dir: dir) ?? false
        }
        // The start gesture, thrown while the orb is up, adds to the session the orb is showing.
        recorder.onStartGestureWhileIdle = { [weak self] in
            self?.review.extendPresentedSession() ?? false
        }
        review.onOpenSettings = { [weak self] in self?.main.present(.settings) }
        // "Delete all past sessions" must never remove the one being recorded; Settings has no recorder.
        main.openSessionDir = { [weak self] in self?.recorder.sessionDir }
        main.sessionRoot = recorder.sessionRoot
        // The board must not show the session being recorded as "Unfinished recording"; see
        // `SessionsStore.load`.
        SessionsStore.openSessionDir = { [weak self] in self?.recorder.sessionDir }
        // Collections sit beside the sessions, wherever `--out` put them; the scripts resolve the same
        // file from a session's own parent.
        Collections.root = recorder.sessionRoot
        // Briefs that could not be filed when made (offline, filing service busy) are filed when the
        // network is back.
        FilingQueue.shared.start()
        WeeklyNote.shared.onOpen = { [weak self] in self?.main.present(.dashboard) }
        WeeklyNote.shared.start()
        // Clears the MCP entry written by earlier versions.
        LegacyMCP.cleanUpOnce()
        // Read those configs so the first brief of the session already knows whether Jira is reachable.
        // Off the main thread; a cold answer only ever renders the cautious wording.
        AgentConfigs.warm()
        // The meaning model, if it is not already there. Filing works on words alone until it finishes, so
        // nothing blocks. Its backfill must land on this launch's board, not the default one; see
        // `MeaningModel.root`.
        MeaningModel.shared.start(root: recorder.sessionRoot)

        // Sweep old sessions at launch, the one moment no session is open, and off the main thread
        // because it walks a directory.
        let root = recorder.sessionRoot
        let days = Sessions.retentionDays
        // `keeping:` is passed even though nothing is open at launch, so the guard can fire if that changes.
        let open = recorder.sessionDir
        Task.detached(priority: .utility) {
            Sessions.sweep(root: root, olderThanDays: days, keeping: open)
        }

        startListeningIfPermitted()
        refresh()

        // Permissions change outside this process and macOS does not say so. Without a poll only a
        // recorder state change or opening the menu re-reads TCC, so a revoked or re-granted permission
        // would go unnoticed.
        schedulePermissionPoll()

        // If the last run died, say so once, with the button that turns it into a bug report. A menu-bar
        // app with no window otherwise just "disappears".
        if CrashReport.previousRunCrashed() {
            CrashReport.clearPreviousRun()
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Deiko quit unexpectedly last time"
                alert.informativeText =
                    "Sorry about that. Nothing recorded was lost — sessions are written to disk as they happen. "
                    + "If you can, copy the diagnostics and send them over; they say what failed."
                alert.addButton(withTitle: "Copy diagnostics")
                alert.addButton(withTitle: "Ignore")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    Diagnostics.copyToPasteboard()
                }
            }
        }

        // First run says something: no tap is installed until every grant is in, so the hotkey does
        // nothing until then.
        welcome.onOpenSettings = { [weak self] in self?.main.present(.settings) }
        welcome.presentIfNeeded()

        // Detached, and nothing waits for it: the menu is usable already, and a slow or absent network
        // must not delay the app. When it finds something the menu rebuilds and grows one item. Repeated
        // every six hours, since a menu-bar app runs for weeks.
        let checkForUpdate = { [weak self] in
            Task { @MainActor in
                await Update.check()
                if Update.available != nil { self?.rebuildMenu() }
            }
        }
        checkForUpdate()
        let updates = Timer(timeInterval: 6 * 60 * 60, repeats: true) { _ in checkForUpdate() }
        RunLoop.main.add(updates, forMode: .common)

        // Refresh the plan cache so the menu's line is right the first time it is opened. Detached for the
        // same reason; failure is silence, and `planLine` says nothing without a cached answer.
        Task { try? await License.refresh() }
    }

    /// How often TCC is re-read: every 2s while a permission is missing, else every 30s.
    ///
    /// While something is missing the user is in System Settings flipping a switch and looking back to see
    /// whether Deiko noticed, so a slow poll reads as "it didn't work". Once everything is granted the poll
    /// only watches for a revocation, which nobody is waiting to see acknowledged. The checks are local
    /// (see `isGranted`), so the fast rate costs little.
    private func schedulePermissionPoll() {
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)
        let interval: TimeInterval = blocked ? 2 : 30
        guard pollInterval != interval else { return }
        pollInterval = interval

        permissionPoll?.invalidate()
        let poll = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common` so it keeps firing while a menu is open or a modal alert is up, when the grant is
        // most likely to land.
        RunLoop.main.add(poll, forMode: .common)
        permissionPoll = poll
    }

    private func refresh() {
        // A revoked permission must tear the tap down, or granting it again can never bring it back:
        // `startListeningIfPermitted`'s guard would short-circuit on a stale `isListening`.
        if isListening, !Permission.allCases.allSatisfy(\.isGranted) {
            recorder.stopListening()
            isListening = false
        }
        startListeningIfPermitted()
        setIcon()
        // Every open rebuilds anyway (`menuWillOpen`); a rebuild here is only
        // for a grant that changed while it was open.
        if Permission.allCases.map(\.isGranted) != builtFor { rebuildMenu() }
        // The last thing, so the rate follows the state that was just read.
        schedulePermissionPoll()
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        // The Deiko mark, the same ring-and-dot as the orb's coin, in one of three states. The third
        // exists because without a grant the hotkey does nothing (`startListeningIfPermitted` returns early
        // and no tap is installed), and the icon must not look identical to an armed one. Each state is a
        // shape change, not a tint: capturing swells the dot to fill the ring (and goes record-red), blocked
        // hangs an `!` off the ring. Colour is never the only signal.
        let recording = recorder.isRecording
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)

        let image = DeikoStyle.menuBarIcon(recording: recording, blocked: blocked)
        image.accessibilityDescription =
            blocked
            ? "Deiko — needs permission" : (recording ? "Deiko — capturing" : "Deiko — ready")
        button.image = image
        // Nil for everything except recording. AppKit resolves the tint against the button's
        // effectiveAppearance, which follows the system Light/Dark setting, while the menu bar's actual
        // darkness follows the desktop behind it. In Light Mode with a dark window under the bar the two
        // disagree and a dynamic colour resolves to its light variant, hard to read on a dark bar. An
        // untinted template image is drawn black on a light bar and white on a dark one. Blocked loses
        // nothing by dropping orange, since the `!` is the signal. Recording keeps red, a fixed bright one
        // that reads on any bar.
        button.contentTintColor = recording ? DeikoStyle.menuBarRecordingNS : nil
        // Shown on hover in the app's own tip, and read aloud by VoiceOver: the only place the reason is
        // available without opening the menu.
        let hint = blocked ? "Deiko needs permission to work — click to grant" : nil
        iconTip.text = hint
        button.setAccessibilityHelp(hint)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        builtFor = Permission.allCases.map(\.isGranted)
        let missing = Permission.allCases.filter { !$0.isGranted }

        if !missing.isEmpty {
            addPermissionItems(missing, to: menu)
        } else if relaunchPending, recorder.sessionDir == nil {
            // Never while a session is open: it needs its Stop item more than relaunch advice, and
            // relaunching would kill the recording. Screen Recording was granted this launch: the system
            // reports it granted immediately, but ScreenCaptureKit in this process keeps failing silently
            // until a restart (crops come back with no path and no withheld reason). So the relaunch leads
            // the menu only at the moment it applies; an always-there item would say "this app breaks".
            menu.addItem(disabled("Relaunch to finish"))
            menu.addItem(disabled("Screen Recording takes effect after a relaunch"))
            menu.addItem(NSMenuItem(
                title: "Relaunch Deiko",
                action: #selector(relaunch),
                keyEquivalent: ""
            ))
        } else {
            addCaptureItems(to: menu)
        }

        menu.addItem(.separator())

        // Back to a brief already dismissed: `×` puts the orb away for good, so without this the session
        // would be reachable only as a folder of JSON. Re-presenting is cheap since the transcript cache
        // avoids re-recognising anything.
        let recent = Sessions.list(root: recorder.sessionRoot).prefix(5)
        if !recent.isEmpty {
            let item = NSMenuItem(title: "Recent sessions", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for name in recent {
                let title = Sessions.stamp(name).map(formatter.string(from:)) ?? name
                let child = NSMenuItem(
                    title: title, action: #selector(openRecentSession(_:)), keyEquivalent: ""
                )
                child.representedObject = "\(recorder.sessionRoot)/\(name)"
                child.target = self
                submenu.addItem(child)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem(
            title: "Open sessions folder",
            action: #selector(openSessionRoot),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Export memory…",
            action: #selector(exportMemory),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Open Deiko",
            action: #selector(openMain),
            keyEquivalent: "d"
        ))
        menu.addItem(personaItem())
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
        // Only when there is one: an always-present "Check for updates…" is a chore, this is an answer
        // they already have.
        if let update = Update.available {
            menu.addItem(NSMenuItem(
                title: "Update to \(update.version)…",
                action: #selector(openUpdatePage),
                keyEquivalent: ""
            ))
        }
        // Only when this build was stamped with somewhere to send it; an item that opened an empty
        // compose window would be a dead end.
        if Credentials.supportEmail != nil {
            menu.addItem(NSMenuItem(
                title: "Send feedback…",
                action: #selector(sendFeedback),
                keyEquivalent: ""
            ))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About Deiko", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Deiko", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        // Rebuild every time it opens: permission state changes outside this process, so a menu built
        // once reports stale facts.
        menu.delegate = self
        if statusItem.menu !== menu { statusItem.menu = menu }
    }

    /// The normal menu: a state block first, then the utility tail. Idle names the gesture, so the menu
    /// doubles as the cheat-sheet. Capturing leads with the red dot and a live mono timer, and Stop is
    /// the emphasised item.
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

            // The way out that does not produce a brief: a session started by accident should not have to
            // reach an orb and be dismissed, which leaves the recording and screenshots on disk.
            let discard = NSMenuItem(
                title: "Stop and discard…",
                action: #selector(discardSession),
                keyEquivalent: ""
            )
            menu.addItem(discard)

            let key = SessionKey.selected
            let stopTitle = "Stop capturing — tap \(key.symbol)"
            let stop = NSMenuItem(
                title: stopTitle,
                action: #selector(stopSession),
                keyEquivalent: ""
            )
            // The one action that matters mid-session, bold so it reads as the
            // default even though NSMenu has no real notion of one.
            stop.attributedTitle = NSAttributedString(
                string: stopTitle,
                attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]
            )
            menu.addItem(stop)
        } else {
            capturingItem = nil
            menu.addItem(disabled(
                isListening
                    ? "Ready — \(SessionKey.selected.symbol)\(SessionKey.selected.symbol) to start"
                    : "Not listening — could not create the event tap"
            ))
            if isListening {
                menu.addItem(disabled(
                    "double-tap \(SessionKey.selected.name), then talk and point"))
            }
            if let line = planLine() { menu.addItem(disabled(line)) }
        }
    }

    /// How much transcription is left, where people already look when they wonder what Deiko is doing.
    /// Read from the cache, never the network: this runs on every menu open and must not hang on a bad
    /// connection. Nil rather than a "checking…" placeholder.
    private func planLine() -> String? {
        // Their key, their bill: nothing is metered, so any quota would describe an account Deiko does
        // not hold.
        if Credentials.willUse("GROQ_API_KEY") { return "Your own Groq key — nothing metered" }
        guard Credentials.relayURL != nil, let quota = License.cachedQuota else { return nil }

        if quota.isPro {
            return quota.isSpent
                ? "Pro · this month's hours are used up — transcribing on this Mac"
                : "Pro · \(quota.remainingSentence) this month"
        }
        return quota.isSpent
            ? "Free hours used up this month — transcribing on this Mac"
            : "Free · \(quota.remainingSentence) this month"
    }

    /// `● Capturing · 0:43` — the dot in record red, the timer in mono.
    private func capturingHeader() -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: DeikoStyle.recordRedNS]
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

    /// Missing permissions are the whole menu when present. The header says what the user experiences
    /// ("the hotkey is doing nothing"), in words rather than an icon tint.
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
        // Opens the guided first-run window rather than firing every request: Accessibility and Screen
        // Recording return without waiting for an answer, so a loop of `ask()` could stack system alerts
        // and bounce System Settings between panes. One click, one dialog.
        menu.addItem(NSMenuItem(
            title: "Grant permissions…",
            action: #selector(openWelcome),
            keyEquivalent: ""
        ))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    /// The one button. Closes the session out, including waiting for crops still being written; the
    /// review window takes it from there via `onSessionClosed`.
    @objc private func stopSession() {
        Task { @MainActor in
            _ = await recorder.stopSession()
        }
    }

    /// Stop, and keep nothing. Confirmed, because minutes of narration are being thrown away and the
    /// click is next to Stop.
    @objc private func discardSession() {
        // Captured before the alert: `runModal` spins a nested runloop and the hotkey tap runs in
        // `.commonModes`, so the session can close underneath the sheet. Re-reading `recorder.sessionDir`
        // afterwards would find nil and silently skip a confirmed discard.
        guard let dir = recorder.sessionDir else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Discard this session?"
        alert.informativeText =
            "The recording and any screenshots are deleted, and no brief is made. "
            + "This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            if recorder.sessionDir == dir {
                await recorder.discardSession()
            } else {
                // It stopped while the sheet was open. Honour what was agreed:
                // remove that session, and put away the orb if it is the one
                // now showing it.
                try? FileManager.default.removeItem(atPath: dir)
                Emit.log("✕ session \((dir as NSString).lastPathComponent) discarded after it had stopped")
                PickUp.shared.discarded(sessionDir: dir)
                review.dismissIfShowing(dir)
            }
        }
    }

    /// Re-open a finished session's brief in the orb.
    @objc private func openRecentSession(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        review.present(sessionDir: dir)
    }

    /// A bug report with the answers already in it.
    @objc private func sendFeedback() {
        guard let url = Diagnostics.feedbackURL() else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openUpdatePage() {
        Update.openReleasePage()
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

    /// "Next brief as ▸", with the current answer ticked. The menu is where people already are when they
    /// decide how the next brief should read. It sets the default; a brief already on screen changes
    /// itself from the review window.
    private func personaItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Next brief as", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = Personas.defaultID
        for persona in Personas.all() {
            let entry = NSMenuItem(
                title: persona.name,
                action: #selector(pickPersona(_:)),
                keyEquivalent: ""
            )
            entry.representedObject = persona.id
            entry.state = persona.id == current ? .on : .off
            entry.target = self
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "Personas…", action: #selector(openPersonas), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
        item.submenu = submenu
        return item
    }

    @objc private func pickPersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Personas.defaultID = id
    }

    @objc private func openPersonas() {
        main.present(.personas)
    }

    @objc private func openMain() {
        main.present(.dashboard)
    }

    @objc private func openSettings() {
        main.present(.settings)
    }

    /// The app menu's Settings… (⌘,), reached through the responder chain.
    @objc func showSettings(_ sender: Any?) { openSettings() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openWelcome() {
        welcome.onOpenSettings = { [weak self] in self?.main.present(.settings) }
        welcome.present()
    }

    @objc private func openSessionRoot() {
        // The root, not the open session.
        let root = recorder.sessionRoot
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    /// A zip of the board: every brief's words, screenshots, notes and task
    /// and project lists. Not the recordings (the words are already written
    /// down from them), the meaning vectors (rebuilt from the words) or the
    /// downloaded models, which together are most of the folder's size.
    @objc private func exportMemory() {
        let root = URL(fileURLWithPath: Collections.root)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withFullDate)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Deiko memory \(day).zip"
        panel.allowedContentTypes = [.zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let name = root.lastPathComponent
        Task.detached {
            // Zipped beside it, then swapped in: a failed export leaves the
            // file that was there untouched.
            let partial = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).partial")
            try? FileManager.default.removeItem(at: partial)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = root.deletingLastPathComponent()
            zip.arguments = ["-r", "-q", "-y", partial.path, name, "-x",
                             "\(name)/models/*", "*.wav", "*.f32", "*.DS_Store", "*/.lists.lock/*", "*.tmp-*", "*/.board-index.json"]
            let zipped = (try? zip.run()).map { zip.waitUntilExit(); return zip.terminationStatus == 0 } ?? false
            let fm = FileManager.default
            let ok = zipped && (fm.fileExists(atPath: dest.path)
                ? (try? fm.replaceItemAt(dest, withItemAt: partial)) != nil
                : (try? fm.moveItem(at: partial, to: dest)) != nil)
            if !ok { try? FileManager.default.removeItem(at: partial) }
            await MainActor.run {
                if ok { NSWorkspace.shared.activateFileViewerSelecting([dest]); return }
                Emit.log("export: zip failed for \(dest.lastPathComponent)")
                let alert = NSAlert()
                alert.messageText = "Couldn't export your memory"
                alert.informativeText = "Nothing was changed. Try saving it somewhere else, like your Desktop."
                alert.runModal()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Opening Deiko while it runs (double-clicking it in Finder, clicking its Dock tile) opens its
    /// window, the only way in when the menu-bar icon is hidden behind a notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { main.present(.dashboard) }
        return true
    }

    /// Every quit closes the session out first: this menu's Quit, ⌘Q from the app menu, a relaunch, logout
    /// and restart all land here. The stop is the one the button does, crops in flight and all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.sessionDir != nil else { return .terminateNow }
        Task { @MainActor in
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A permission granted in Settings takes effect without a click here as well. Listening first,
        // then one rebuild: each rebuild costs four tccd round-trips for the permission checks.
        startListeningIfPermitted()
        rebuildMenu()

        // The capturing header carries a clock, so a menu held open must not show a stale time. `.common`
        // because menu tracking runs the loop in a mode plain timers never fire in.
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
            // The worst state: every permission granted, the icon reading ready, the menu listing nothing
            // missing, and the hotkey dead.
            Emit.problem(
                "could not create the event tap",
                hint: "Accessibility is granted but macOS refused Deiko's keyboard listener, so the \(SessionKey.selected.name) shortcut won't work. Quit and relaunch Deiko. If it persists, remove Deiko from System Settings → Privacy & Security → Accessibility and add it again."
            )
        }
    }
}

private extension NSFont {
    /// The menu font at a different weight: NSFont has no variant API, and the system font at menu size
    /// is the menu font.
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
