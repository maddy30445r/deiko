import AppKit
import SwiftUI
import DeikoGesture
import DeikoHandoff

// First run: one column shown once, unprompted. It says what Deiko does, lists
// each permission with the data it takes, and shows the key and the gesture.
// Gestures are ignored until every permission is granted, so this is where they
// are collected. Reachable again from the menu's "Getting started…".

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var holdsDock = false

    /// Whether the user has ever finished first-run.
    private static let seenKey = "hasSeenWelcome"
    static var hasBeenSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// Open Settings — set by `MenuBar`, which owns that window. The key row
    /// deep-links there for typing the key itself.
    var onOpenSettings: (() -> Void)?

    /// Shows the window unless the user has already finished first-run.
    func presentIfNeeded() {
        guard !Self.hasBeenSeen else { return }
        present()
    }

    func present() {
        if !holdsDock {
            DockPresence.acquire()
            holdsDock = true
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = WelcomeModel()
        model.onOpenSettings = { [weak self] in
            self?.onOpenSettings?()
        }
        model.onDone = { [weak self] in
            Self.hasBeenSeen = true
            self?.window?.close()
        }

        let hosting = NSHostingController(rootView: WelcomeView(model: model))
        // Fixed size: the hosting controller must not resize the window to its
        // content, which scrolls. See `makeWindow` in `Orb.swift`.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Deiko"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.useRoundedTitleBar("DeikoWelcome")
        // Tall enough that the title is never scrolled off the top.
        window.setContentSize(NSSize(width: 540, height: 720))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as seen: a dismissed window is never re-presented.
        Self.hasBeenSeen = true
        if holdsDock {
            DockPresence.release()
            holdsDock = false
        }
    }
}

@MainActor
final class WelcomeModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let symbol: String
        let purpose: String
        let granted: Bool
        /// What clicking this row's button will do, so the label can say it. A
        /// "Grant" button that silently opens System Settings would mislead.
        let step: PermissionStep
    }

    @Published var rows: [Row] = []
    @Published var needsRelaunch = false
    @Published var keyPresent = Credentials.willUse("GROQ_API_KEY")

    var onOpenSettings: (() -> Void)?
    var onDone: (() -> Void)?

    /// "Start pointing" enables once the four grants are in. A key is not
    /// required: a keyless install still transcribes.
    var readyToPoint: Bool { rows.allSatisfy(\.granted) }

    private var screenRecordingWasMissing = false
    private var watcher: Timer?

    init() { refresh() }

    func refresh() {
        rows = Permission.allCases.map {
            Row(
                id: $0.rawValue, symbol: $0.symbol, purpose: $0.purpose,
                granted: $0.isGranted,
                step: PermissionStep.next(granted: $0.isGranted, asked: $0.hasBeenAsked)
            )
        }
        // Presence check only: first run must not demand the login password
        // just to draw a checkmark.
        keyPresent = Credentials.willUse("GROQ_API_KEY")
    }

    /// Ask for one permission, then re-read the whole set.
    func request(_ name: String) {
        guard let permission = Permission.allCases.first(where: { $0.rawValue == name }) else { return }

        // Screen Recording needs a restart: the system reports it granted at
        // once, but ScreenCaptureKit in this process keeps failing until
        // relaunch. Remember it was missing so the relaunch prompt appears.
        if permission == .screenRecording, !permission.isGranted {
            screenRecordingWasMissing = true
        }

        // One action, a dialog or Settings, never both. See `Permission.ask`.
        Task { await permission.ask() }
    }

    /// Watch for as long as this window is on screen. Granting Accessibility
    /// takes longer than any fixed polling window (find the pane, unlock it,
    /// tick Deiko), so this polls until the window closes.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.screenRecordingWasMissing, Permission.screenRecording.isGranted {
                    self.needsRelaunch = true
                }
            }
        }
    }

    func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    func relaunch() { Relauncher.relaunch() }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SectionLabel("What Deiko needs to see and hear")
                permissions
                SectionLabel("One more thing")
                setupRows
                gestureStrip
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .background(DeikoStyle.paper)
        .onAppear {
            model.refresh()
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        // Controls Deiko did not draw would take the system accent; this puts
        // them on the palette. See `MainWindowView`.
        .tint(DeikoStyle.accent)
    }

    /// The header sits on the lavender wall, the one surface allowed to be a
    /// colour rather than paper. It opens on the product's own sentence rather
    /// than its name.
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(DeikoStyle.coinFill)
                Circle().fill(
                    LinearGradient(colors: [DeikoStyle.coinShine, .clear], startPoint: .top, endPoint: .center)
                )
                Circle().strokeBorder(DeikoStyle.accent, lineWidth: 1.5)
                DeikoMark(diameter: 16, color: DeikoStyle.mark)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Show, don\u{2019}t type.").deikoTitle(24)
                Text("Point at your screen and talk. What you said — and what you pointed at — becomes a brief for your coding agent.")
                    .font(.system(size: 13))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(DeikoStyle.wall, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
    }

    private var permissions: some View {
        InsetCard {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.horizontal, 14) }
                HStack(spacing: 12) {
                    glyphTile(row.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.id).font(.system(size: 13, weight: .semibold))
                        Text(row.purpose)
                            .font(.system(size: 11))
                            .foregroundStyle(DeikoStyle.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if row.granted {
                        grantedTag("Granted")
                    } else {
                        // "Open Settings" once the dialog has been seen: it will not
                        // come back.
                        Button(row.step == .openSettings ? "Open Settings" : "Grant") {
                            model.request(row.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                // The relaunch strip renders inline under Screen Recording,
                // next to the fix.
                if row.id == Permission.screenRecording.rawValue, model.needsRelaunch {
                    HStack(spacing: 8) {
                        Text("Takes effect after a relaunch.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DeikoStyle.needsYou)
                        Spacer()
                        Button("Relaunch now") { model.relaunch() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DeikoStyle.needsYou.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// The keychain sentence for the key row. Same claim as
    /// `SettingsWindow.whereAudioGoes`, kept in sync by hand; see that file for
    /// why the sorting clause is conditional.
    private var ownKeySubtitle: String {
        guard model.keyPresent else { return "optional — transcription works without one" }
        let local = "in your login keychain — transcription and the summary go straight to Groq"
        guard Credentials.filesBriefs else { return local }
        return local + "; to sort briefs, what you said and notes on earlier work pass through Deiko to TypeSafe's Jev sorting model, and Deiko keeps nothing"
    }

    private var setupRows: some View {
        InsetCard {
            HStack(spacing: 12) {
                glyphTile("key")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own Groq key").font(.system(size: 13, weight: .semibold))
                    Text(ownKeySubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                }
                Spacer()
                if model.keyPresent {
                    grantedTag("Added")
                } else {
                    Button("Add key…") { model.onOpenSettings?() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    /// The gesture, as three keycaps.
    private var gestureStrip: some View {
        // Reads the current key so the window teaches the gesture that works
        // on this Mac. Left Option is fixed: it is the drawing key.
        let key = SessionKey.selected
        return HStack(spacing: 16) {
            keycap("\(key.symbol) \(key.symbol)", "double-tap \(key.name) — start")
            keycap("⌥ + move", "left Option — lasso a region")
            keycap(key.symbol, "tap — stop")
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(DeikoStyle.wall, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Finish later") { model.onDone?() }
                .buttonStyle(.plain)
                .foregroundStyle(DeikoStyle.ink2)
                .deikoFocusRingLoose()
            // "Start pointing", not "Done"; disabled until the app can deliver.
            Button("Start pointing") { model.onDone?() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(InkButtonStyle())
                .disabled(!model.readyToPoint)
        }
        .padding(.top, 2)
    }

    private func glyphTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(DeikoStyle.accent)
            .frame(width: 26, height: 26)
            .background(DeikoStyle.accentSoft, in: RoundedRectangle(cornerRadius: DeikoStyle.controlRadius))
    }

    private func grantedTag(_ word: String) -> some View {
        Label(word, systemImage: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DeikoStyle.sentGreen)
            .labelStyle(.titleAndIcon)
    }

    private func keycap(_ keys: String, _ meaning: String) -> some View {
        HStack(spacing: 7) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DeikoStyle.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
                        )
                )
            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
        }
    }
}
