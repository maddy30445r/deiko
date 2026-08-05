import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// FIRST RUN — the one screen where reading is the point
//
// What a new install used to do: put a mark in the menu bar and wait. The
// hotkey did nothing, because `startListeningIfPermitted` installs no event tap
// until all four grants are in — and the list of what was missing lived inside
// a menu the user had no reason to open. The app presented as working and
// silently ignored every gesture.
//
// So this appears once, unprompted. One column, one read: what Fovea does,
// each permission with the DATA it takes (that is what earns trust, not
// reassurance copy), the key — its row granting itself directly — and the
// gesture. The primary button is "Start pointing", not "Done": the moment
// everything is in, the next action is the product.
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
        window.title = "Welcome to Fovea"
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
    }

    @Published var rows: [Row] = []
    @Published var needsRelaunch = false
    @Published var keyPresent = Credentials.exists("SARVAM_API_KEY")

    var onOpenSettings: (() -> Void)?
    var onDone: (() -> Void)?

    /// "Start pointing" enables when the app can actually deliver on it —
    /// which is the four grants, and nothing else. It used to require a Sarvam
    /// key too, back when a session without one produced nothing at all. A
    /// keyless install now transcribes; asking for a key before letting anyone
    /// start would be demanding something the product no longer needs.
    var readyToPoint: Bool { rows.allSatisfy(\.granted) }

    private var screenRecordingWasMissing = false

    init() { refresh() }

    func refresh() {
        rows = Permission.allCases.map {
            Row(id: $0.rawValue, symbol: $0.symbol, purpose: $0.purpose, granted: $0.isGranted)
        }
        // `exists`, not `value` — first run must not demand the login password
        // just to draw a checkmark.
        keyPresent = Credentials.exists("SARVAM_API_KEY")
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

        Task {
            // `ask()` is the shared path: request first — which is what puts
            // Fovea in the privacy pane at all — then open Settings if that was
            // not enough.
            await permission.ask()

            // The grant lands asynchronously: the user is in a system dialog or
            // a Settings pane, and nothing tells us when they answer. Poll for
            // ten seconds rather than reporting the state from before they did.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                refresh()
                if screenRecordingWasMissing, Permission.screenRecording.isGranted {
                    needsRelaunch = true
                }
            }
        }
    }

    func relaunch() { Relauncher.relaunch() }
}

// ── View ────────────────────────────────────────────────────────────────────

private struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SectionLabel("FOVEA NEEDS TO SEE AND HEAR WHAT YOU POINT AT")
                permissions
                SectionLabel("ONE MORE THING")
                setupRows
                gestureStrip
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(FoveaStyle.coinFill)
                Circle().fill(
                    LinearGradient(colors: [FoveaStyle.coinShine, .clear], startPoint: .top, endPoint: .center)
                )
                Circle().strokeBorder(FoveaStyle.accent, lineWidth: 1.5)
                FoveaMark(diameter: 16, color: FoveaStyle.mark)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fovea").font(.system(size: 22, weight: .semibold))
                Text("Point at your screen and talk. What you said — and what you pointed at — becomes a brief for your coding agent.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if row.granted {
                        grantedTag("Granted")
                    } else {
                        Button("Grant") { model.request(row.id) }
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
                            .foregroundStyle(FoveaStyle.needsYou)
                        Spacer()
                        Button("Relaunch now") { model.relaunch() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(FoveaStyle.needsYou.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
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
                    Text("Your own Sarvam key").font(.system(size: 13, weight: .semibold))
                    Text(model.keyPresent
                        ? "in your login keychain — Fovea's servers never see your narration"
                        : "optional — transcription works without one")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
        HStack(spacing: 16) {
            keycap("⌥ ⌥", "double-tap right Option — start")
            keycap("⌥ + drag", "left Option — lasso a region")
            keycap("⌥", "tap — stop")
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FoveaStyle.insetRadius))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Finish later") { model.onDone?() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            // "Start pointing", not "Done" — the moment it enables, the next
            // action is the product itself. Half-lit until the app can
            // actually deliver on the promise.
            Button("Start pointing") { model.onDone?() }
                .keyboardShortcut(.defaultAction)
                .tint(FoveaStyle.accent)
                .disabled(!model.readyToPoint)
        }
        .padding(.top, 2)
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

    private func glyphTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func grantedTag(_ word: String) -> some View {
        Label(word, systemImage: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FoveaStyle.sentGreen)
            .labelStyle(.titleAndIcon)
    }

    private func keycap(_ keys: String, _ meaning: String) -> some View {
        HStack(spacing: 7) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                        )
                )
            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
