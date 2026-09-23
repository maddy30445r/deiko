import AppKit
import SwiftUI
import DeikoGesture
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// FIRST RUN — the one screen where reading is the point
//
// What a new install used to do: put a mark in the menu bar and wait. The
// hotkey did nothing, because `startListeningIfPermitted` installs no event tap
// until all four grants are in — and the list of what was missing lived inside
// a menu the user had no reason to open. The app presented as working and
// silently ignored every gesture.
//
// So this appears once, unprompted. One column, one read: what Deiko does,
// each permission with the DATA it takes (that is what earns trust, not
// reassurance copy), the key — its row deep-links to Settings to add one,
// rather than granting itself — and the gesture. The primary button is
// "Start pointing", not "Done": the moment everything is in, the next action
// is the product.
//
// Shown again from the menu's "Getting started…", because "I clicked past it"
// is not a reason to have to reinstall.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    /// Whether the user has ever finished first-run.
    private static let seenKey = "hasSeenWelcome"
    static var hasBeenSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// Open Settings — set by `MenuBar`, which owns that window. The key row
    /// deep-links there for typing the key itself.
    var onOpenSettings: (() -> Void)?

    /// Show on first launch, or whenever a permission is missing and the user
    /// has never completed the flow.
    func presentIfNeeded() {
        guard !Self.hasBeenSeen else { return }
        present()
    }

    func present() {
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
        // 540×720 is the design's size and the window keeps it; the content
        // scrolls. See `Orb.swift`'s `makeWindow`.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Deiko"
        window.styleMask = [.titled, .closable]
        // Tall enough that nothing scrolls. At 560 the content overflowed and
        // the window opened showing the description with the title scrolled off
        // the top — the first screen of a first run, missing its own name.
        window.setContentSize(NSSize(width: 540, height: 720))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as seen. Re-presenting a window somebody dismissed is
        // the behaviour that makes people uninstall things.
        Self.hasBeenSeen = true
    }
}

// ── State ───────────────────────────────────────────────────────────────────

@MainActor
final class WelcomeModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let symbol: String
        let purpose: String
        let granted: Bool
        /// What clicking this row's button will actually do — so the label can
        /// say it. A button reading "Grant" that silently opens System Settings
        /// instead of prompting is the same lie the old flow told by doing both.
        let step: PermissionStep
    }

    @Published var rows: [Row] = []
    @Published var needsRelaunch = false
    @Published var keyPresent = Credentials.willUse("GROQ_API_KEY")

    var onOpenSettings: (() -> Void)?
    var onDone: (() -> Void)?

    /// "Start pointing" enables when the app can actually deliver on it —
    /// which is the four grants, and nothing else. It used to require a Sarvam
    /// key too, back when a session without one produced nothing at all. A
    /// keyless install now transcribes; asking for a key before letting anyone
    /// start would be demanding something the product no longer needs.
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
        // `exists`, not `value` — first run must not demand the login password
        // just to draw a checkmark.
        keyPresent = Credentials.willUse("GROQ_API_KEY")
    }

    /// Ask for one permission, then re-read the whole set.
    func request(_ name: String) {
        guard let permission = Permission.allCases.first(where: { $0.rawValue == name }) else { return }

        // Screen Recording is the one that needs a restart: the system reports
        // it granted immediately, but ScreenCaptureKit in THIS process keeps
        // failing until relaunch. Remember that it was missing so the relaunch
        // prompt appears rather than the user discovering it later as crops
        // that silently never arrive.
        if permission == .screenRecording, !permission.isGranted {
            screenRecordingWasMissing = true
        }

        // ONE action — a dialog, or Settings, never both. See `Permission.ask`.
        Task { await permission.ask() }
    }

    /// Watch for as long as this window is on screen.
    ///
    /// It used to poll for ten seconds after a click and then stop, which is
    /// shorter than granting Accessibility actually takes: find the pane,
    /// unlock it, find Deiko, tick it. Anybody slower than ten seconds came
    /// back to a row still reading "Grant" for a permission they had just
    /// given, and the obvious next move is to restart the app. Now the window
    /// keeps looking while it is open, and stops when it closes.
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

// ── View ────────────────────────────────────────────────────────────────────

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
        // The controls Deiko did not draw take the SYSTEM accent — whatever
        // colour the person set in System Settings. One line puts them on
        // the palette instead; see `MainWindowView` for the long version.
        .tint(DeikoStyle.accent)
    }

    /// The header sits on the lavender wall — the one surface in the app that
    /// is allowed to be a colour rather than paper, and the same one the site
    /// stands its product windows on. It opens on the product's own sentence
    /// rather than its name: nobody installed this to read the word "Deiko".
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
                        // "Open Settings" once the dialog has been seen: it
                        // will not come back, and a second "Grant" that only
                        // opened a window would be the old confusion again.
                        Button(row.step == .openSettings ? "Open Settings" : "Grant") {
                            model.request(row.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                // The relaunch strip renders INLINE under Screen Recording,
                // with the fix on the same line — not discovered later as
                // crops that never arrive with no reason given.
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

    private var setupRows: some View {
        InsetCard {
            HStack(spacing: 12) {
                glyphTile("key")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own Groq key").font(.system(size: 13, weight: .semibold))
                    Text(model.keyPresent
                        ? "in your login keychain — Deiko's servers never see your narration"
                        : "optional — transcription works without one")
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

    /// The gesture, as three keycaps — the menu repeats this later, but the
    /// first run is where the muscle memory starts.
    private var gestureStrip: some View {
        // Reads the CURRENT key rather than the default, so the first-run
        // window teaches the gesture that actually works on this Mac. Left
        // Option is fixed — it is the drawing key, not the session key.
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
            // "Start pointing", not "Done" — the moment it enables, the next
            // action is the product itself. Half-lit until the app can
            // actually deliver on the promise.
            Button("Start pointing") { model.onDone?() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(InkButtonStyle())
                .disabled(!model.readyToPoint)
        }
        .padding(.top, 2)
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

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
