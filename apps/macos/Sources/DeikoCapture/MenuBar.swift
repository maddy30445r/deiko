import AppKit
import AVFoundation
import Foundation
import Speech
import DeikoGesture
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE MENU-BAR SHELL
//
// [BOX] work — boilerplate around the capture core, deliberately thin.
//
// It exists for two reasons beyond looking like an app:
//
//   1. PERMISSIONS. macOS attributes privacy requests to the *responsible*
//      process, which for a terminal-launched binary is the terminal (or, from
//      an IDE's embedded shell, Electron). Running as a real bundle makes Deiko
//      answer for itself, so the four permissions attach to Deiko.app and stop
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
    /// app has requested the permission at least once. Deiko was absent from
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

    /// Has this install ever requested this permission?
    ///
    /// Microphone and Speech carry it natively — `.notDetermined` means the
    /// dialog has never been shown, and anything else means it has. The other
    /// two have no such state (they are a bare true/false), so it is
    /// remembered here. Written at the moment of the request, not after the
    /// answer, because what it records is that the DIALOG has been seen — the
    /// answer is `isGranted`'s job.
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

    /// ONE ACTION PER CLICK — see `PermissionStep` for the whole reasoning.
    ///
    /// This used to request AND open Settings on every call, which for
    /// Accessibility and Screen Recording meant a system alert with a Settings
    /// window opening behind it, before the user had answered either. The alert
    /// is the system's and does not close when the permission is granted
    /// elsewhere, so it outlived the grant and only quitting Deiko cleared it.
    ///
    /// Asking is still what makes the app appear in the privacy pane at all —
    /// Deiko was once absent from the Microphone list because nothing had ever
    /// requested it — so the first click always requests. It is the SECOND
    /// click, on a permission whose dialog has been seen and will not return,
    /// that goes to Settings.
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
    /// the menu was opened. Deiko listens whenever it has permission to, and
    /// Quit is how you stop it.
    private var isListening = false

    /// Held for the app's lifetime, not created per session: a second session
    /// while the orb is still up reuses it rather than stacking orbs.
    private let review = OrbController()
    /// THE app window: the board, personas and every setting, in one place.
    /// Settings used to be its own 520pt sheet; it is a section in here now,
    /// because "where are my briefs" and "how do I change the hotkey" are the
    /// same window in every Mac app anybody already uses.
    private let main = MainWindowController()
    private let welcome = WelcomeWindowController()

    /// Whether Screen Recording was still ungranted when this process came up.
    /// Granted-now + missing-then = a relaunch is pending, and that is the ONE
    /// moment the menu offers Relaunch Deiko.
    private var screenRecordingMissingAtLaunch = false
    private var relaunchPending: Bool {
        screenRecordingMissingAtLaunch && Permission.screenRecording.isGranted
    }

    /// The `● Capturing · 0:43` header of the OPEN menu, so a timer can keep
    /// its clock honest while the user is looking at it.
    private weak var capturingItem: NSMenuItem?
    private var menuClock: Timer?
    /// Notices a permission granted or revoked in System Settings while Deiko
    /// is running. Lives for the life of the app, unlike `menuClock`.
    private var permissionPoll: Timer?
    /// The interval `permissionPoll` is currently running at, so `refresh()`
    /// can rebuild the timer only when the answer actually changes rather than
    /// on every tick.
    private var pollInterval: TimeInterval = 0

    init(recorder: Recorder) {
        self.recorder = recorder
        super.init()
    }

    func install() {
        // FIRST, before any window exists. Setting this after a window is on
        // screen repaints it mid-flight; applied here, the orb and the app
        // window come up already in the appearance somebody chose.
        Appearance.selected.apply()
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
        review.onOpenSettings = { [weak self] in self?.main.present(.settings) }
        // "Delete all past sessions" must never remove the one being recorded.
        // Settings has no recorder of its own and should not grow one.
        main.openSessionDir = { [weak self] in self?.recorder.sessionDir }
        main.sessionRoot = recorder.sessionRoot
        // Collections sit beside the sessions, wherever `--out` put them —
        // the scripts resolve the same file from a session's own parent.
        Collections.root = recorder.sessionRoot
        // Remove the MCP entry earlier versions wrote. Nothing registers
        // anything any more; this is only clearing up after what did.
        LegacyMCP.cleanUpOnce()
        // And read what those configs DO say, so the first brief of the
        // session already knows whether Jira is reachable. Off the main
        // thread; a cold answer only ever renders the cautious wording.
        AgentConfigs.warm()
        // The meaning model, if it isn't already there. Filing works on words
        // alone until this finishes, so nothing here blocks the app.
        MeaningModel.shared.start()

        // OLD SESSIONS GO. Nothing ever removed one before, and a session is a
        // folder of full-resolution screenshots — the folder grew for as long
        // as the app was used and nobody was told it existed. Off the main
        // thread because it walks a directory, and at launch because that is
        // the one moment no session is open.
        let root = recorder.sessionRoot
        let days = Sessions.retentionDays
        // `keeping:` is passed even though nothing is open at launch: a
        // reopened session carries a stamp from an earlier launch, so the guard
        // is not hypothetical, and an argument that is never supplied is a
        // guard that can never fire.
        let open = recorder.sessionDir
        Task.detached(priority: .utility) {
            Sessions.sweep(root: root, olderThanDays: days, keeping: open)
        }

        startListeningIfPermitted()
        refresh()

        // PERMISSIONS CHANGE OUTSIDE THIS PROCESS, and macOS does not tell us.
        // Without a poll the only things that re-read TCC are a recorder state
        // change and opening the menu, so revoking Accessibility left the icon
        // reading "ready" indefinitely, and re-granting it did nothing until
        // the app was quit.
        schedulePermissionPoll()

        // If the last run died, say so once — with the button that turns it
        // into a bug report. A menu-bar app with no window and no Dock icon
        // otherwise just "disappears", which is the whole of what a user is
        // able to report about it.
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
                if alert.runModal() == .alertFirstButtonReturn {
                    Diagnostics.copyToPasteboard()
                }
            }
        }

        // First run says something. Before this, a new install put an eye in
        // the menu bar and waited — and the hotkey did nothing, because no tap
        // is installed until every grant is in.
        welcome.onOpenSettings = { [weak self] in self?.main.present(.settings) }
        welcome.presentIfNeeded()

        // Detached, and nothing waits for it: the menu is already usable, and a
        // slow or absent network must not delay the app coming up. When it
        // finds something the menu rebuilds and grows one item.
        Task { @MainActor in
            await Update.check()
            if Update.available != nil { rebuildMenu() }
        }

        // What is left of the plan, so the menu's line is right the first time
        // it is opened rather than after the first session. Detached for the
        // same reason, and failure is silence — `planLine` simply says nothing
        // when there is no cached answer.
        Task { try? await License.refresh() }
    }

    /// How often TCC is re-read, and it is not one number.
    ///
    /// THIRTY SECONDS IS THE WRONG ANSWER WHILE SOMETHING IS MISSING. That is
    /// exactly the moment the user is in System Settings flipping a switch and
    /// then looking back at Deiko to see whether it noticed — and half a minute
    /// of no change reads as "it didn't work, I'll restart it", which is what
    /// was reported. Two seconds while blocked makes the grant land visibly.
    ///
    /// It stays thirty once everything is in, because then the poll is only
    /// watching for a REVOCATION, which nobody does by accident and nobody is
    /// standing there waiting to see acknowledged. The checks are local — see
    /// `isGranted` — so the fast rate costs little, and it only runs while the
    /// app is not working anyway.
    private func schedulePermissionPoll() {
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)
        let interval: TimeInterval = blocked ? 2 : 30
        guard pollInterval != interval else { return }
        pollInterval = interval

        permissionPoll?.invalidate()
        let poll = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common` so it keeps firing while a menu is open or a modal alert is
        // up — the two states the user is most likely to be in when the grant
        // finally lands.
        RunLoop.main.add(poll, forMode: .common)
        permissionPoll = poll
    }

    private func refresh() {
        // A REVOKED PERMISSION HAS TO TEAR THE TAP DOWN, or granting it again
        // can never bring it back. `isListening` was set true once and never
        // false, so `startListeningIfPermitted`'s guard short-circuited
        // forever: revoke Accessibility, grant it again, and the only recovery
        // was quitting the app — with nothing on screen saying so.
        if isListening, !Permission.allCases.allSatisfy(\.isGranted) {
            recorder.stopListening()
            isListening = false
        }
        startListeningIfPermitted()
        setIcon()
        rebuildMenu()
        // The last thing, so the rate follows the state that was just read.
        schedulePermissionPoll()
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        // The Deiko mark — the same ring-and-dot the orb's coin wears, so the
        // status item and the orb are visibly the same object. "Deiko" is the
        // part of the retina that sees detail; the mark is the product's whole
        // thesis in one glyph: "I'm pointing at this."
        //
        // THE THIRD STATE EARNS ITS PLACE. Without a grant, the hotkey does
        // nothing: `startListeningIfPermitted` returns early and no tap is
        // installed. The icon used to look identical whether Deiko was armed or
        // completely dead, so a new install presented as a working app that
        // silently ignored every gesture — and the only explanation lived
        // inside a menu nobody had a reason to open.
        //
        // Each state is a SHAPE change, not a tint: capturing swells the dot
        // to fill the ring (and goes record-red), blocked hangs an `!` off the
        // ring. Colour is never the only signal.
        let recording = recorder.isRecording
        let blocked = !Permission.allCases.allSatisfy(\.isGranted)

        let image = DeikoStyle.menuBarIcon(recording: recording, blocked: blocked)
        image.accessibilityDescription =
            blocked
            ? "Deiko — needs permission" : (recording ? "Deiko — capturing" : "Deiko — ready")
        button.image = image
        // NIL FOR EVERYTHING EXCEPT RECORDING, and the comment this replaces was
        // wrong about why.
        //
        // It said AppKit resolves the tint "against the menu bar's own
        // appearance". It does not — it resolves against the BUTTON's
        // effectiveAppearance, which follows the system Light/Dark setting,
        // while how dark the menu bar actually renders follows the desktop
        // content behind it. In Light Mode with a dark window under the bar the
        // two disagree, and `needsYouNS` resolved to its light variant:
        // rgb(201,52,0), a brick red at 4.0:1 against a dark bar. Reported as
        // "it looks blackish, and I only see it on the desktop".
        //
        // A template image with no tint has no such gap — AppKit draws it black
        // on a light bar and white on a dark one, always legible. The blocked
        // state loses nothing by dropping the orange, because the `!` hanging
        // off the ring is the signal; this file already says so two paragraphs
        // up ("Each state is a SHAPE change, not a tint … Colour is never the
        // only signal"). Recording keeps its red, because red MEANS recording
        // here — but a fixed bright one that reads on any bar.
        button.contentTintColor = recording ? DeikoStyle.menuBarRecordingNS : nil
        // Read aloud by VoiceOver, and shown on hover — the only place the
        // reason is available without opening the menu.
        button.toolTip = blocked ? "Deiko needs permission to work — click to grant" : nil
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
                title: "Relaunch Deiko",
                action: #selector(relaunch),
                keyEquivalent: ""
            ))
        } else {
            addCaptureItems(to: menu)
        }

        menu.addItem(.separator())

        // BACK TO A BRIEF YOU ALREADY DISMISSED.
        //
        // The orb was the only way to reach one, and `×` put it away for good:
        // a mis-clicked close meant the session was reachable only as a folder
        // of JSON in Finder. Re-presenting is cheap — the transcript cache
        // means the pipeline does not re-recognise anything.
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
        // Only when there is one. An always-present "Check for updates…" is a
        // chore the user has to perform; this is an answer they already have.
        if let update = Update.available {
            menu.addItem(NSMenuItem(
                title: "Update to \(update.version)…",
                action: #selector(openUpdatePage),
                keyEquivalent: ""
            ))
        }
        // Only when this build was stamped with somewhere to send it. The crash
        // alert has always offered to copy diagnostics and never said where
        // they should go; an item that opened an empty compose window would be
        // the same dead end wearing a button.
        if Credentials.supportEmail != nil {
            menu.addItem(NSMenuItem(
                title: "Send feedback…",
                action: #selector(sendFeedback),
                keyEquivalent: ""
            ))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deiko", action: #selector(quit), keyEquivalent: "q"))

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

            // The way out that does not produce a brief. A session started by
            // accident, or one where the wrong thing got said, used to have to
            // be carried all the way to an orb and dismissed — which left the
            // recording and its screenshots on disk regardless.
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

    /// How much transcription is left, where somebody already looks when they
    /// wonder what Deiko is doing.
    ///
    /// Read from the CACHE, never from the network. This runs on every menu
    /// open, and a menu that waited on a round trip would hang on a bad
    /// connection. Nil rather than a placeholder when there is nothing to say:
    /// a line reading "checking…" forever is worse than no line at all.
    private func planLine() -> String? {
        // Their key, their bill — nothing here is metered, so any quota would
        // be a number about an account Deiko does not hold.
        if Credentials.willUse("GROQ_API_KEY") { return "Your own Groq key — nothing metered" }
        guard Credentials.relayURL != nil, let quota = License.cachedQuota else { return nil }

        if quota.isPro {
            return quota.isSpent
                ? "Pro · this month's hours are used up — transcribing on this Mac"
                : "Pro · \(quota.remainingSentence) this month"
        }
        return quota.isSpent
            ? "Free trial used up — transcribing on this Mac"
            : "Free trial · \(quota.remainingSentence)"
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
        // OPENS THE GUIDED WINDOW; it does not fire four requests.
        //
        // It used to loop `ask()` over every missing permission. Accessibility
        // and Screen Recording return without waiting for an answer, so one
        // click could stack two system alerts and send System Settings jumping
        // between two panes before the microphone dialog had even appeared.
        //
        // The first-run window is already the surface for this — a row per
        // permission, each with the data it takes and its own button — so this
        // opens that instead of racing it. One click, one dialog, still true.
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

    /// Stop, and keep nothing. Confirmed, because the thing being thrown away
    /// is minutes of somebody's narration and the click is next to Stop.
    @objc private func discardSession() {
        // Captured BEFORE the alert. `runModal` spins a nested runloop and the
        // hotkey tap is installed in `.commonModes`, so the user can tap the
        // session key — or click the capture pill — while the sheet is up, and
        // the session closes underneath it. Re-reading `recorder.sessionDir`
        // after the click then found nil and returned: a confirmed, destructive
        // action that silently did nothing, leaving on disk the recording the
        // user had just agreed to throw away.
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

    /// "Next brief as ▸", with the current answer ticked.
    ///
    /// The menu is where somebody already is when they decide how the next
    /// brief should read — a window away is one window too many for a choice
    /// made this often. It sets the DEFAULT; a brief already on screen changes
    /// itself from the review window instead.
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

    @objc private func openWelcome() {
        welcome.onOpenSettings = { [weak self] in self?.main.present(.settings) }
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
            // The worst state the app can be in: every permission granted, the
            // icon reading ready, the menu listing nothing missing, and the
            // hotkey dead. Nothing on screen said so until this was shown.
            Emit.problem(
                "could not create the event tap",
                hint: "Accessibility is granted but macOS refused Deiko's keyboard listener, so the \(SessionKey.selected.name) shortcut won't work. Quit and relaunch Deiko. If it persists, remove Deiko from System Settings → Privacy & Security → Accessibility and add it again."
            )
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
