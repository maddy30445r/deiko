import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// FIRST RUN
//
// What a new install used to do: put an eye in the menu bar and wait. The
// hotkey did nothing, because `startListeningIfPermitted` installs no event tap
// until all four grants are in — and the list of what was missing lived inside
// a menu the user had no reason to open. The app presented as working and
// silently ignored every gesture.
//
// So this appears once, unprompted, and states the three things nothing else
// says: what Fovea does, which permissions it needs and exactly why, and where
// the key goes. It is not a tour — one screen, four rows, a button.
//
// Shown again from Settings, because "I clicked past it" is not a reason to
// have to reinstall.
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

    /// Open Settings — set by `MenuBar`, which owns that window.
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

        let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(model: model)))
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
        let purpose: String
        let granted: Bool
    }

    @Published var rows: [Row] = []
    @Published var needsRelaunch = false

    var onOpenSettings: (() -> Void)?
    var onDone: (() -> Void)?

    /// True once every permission is in.
    var allGranted: Bool { rows.allSatisfy(\.granted) }

    private var screenRecordingWasMissing = false

    init() { refresh() }

    func refresh() {
        rows = Permission.allCases.map {
            Row(id: $0.rawValue, purpose: $0.purpose, granted: $0.isGranted)
        }
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
            VStack(alignment: .leading, spacing: 20) {
                header
                permissions
                Divider()
                nextSteps
            }
            .padding(24)
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.system(size: 26))
                Text("Fovea").font(.largeTitle.weight(.semibold))
            }
            Text("Point at things across your apps while talking. Fovea turns that into a brief your coding agent can act on — with the screenshots and the exact text you pointed at.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fovea needs four permissions").font(.headline)
            Text("Each one is used for exactly one thing. Nothing is captured unless you start a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.granted ? .green : .secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.id)
                        Text("to \(row.purpose)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !row.granted {
                        Button("Grant") { model.request(row.id) }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if model.needsRelaunch {
                // Stated here rather than discovered later as crops that never
                // arrive with no reason given.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Text("Screen Recording needs a relaunch before Fovea can capture.")
                        .font(.caption)
                    Spacer()
                    Button("Relaunch") { model.relaunch() }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Two more things").font(.headline)
            Label(
                "Add a Sarvam API key in Settings — Fovea needs it to transcribe.",
                systemImage: "key"
            )
            .font(.callout)
            Label(
                "Connect your coding agent in Settings, so it can fetch what you capture.",
                systemImage: "app.connected.to.app.below.fill"
            )
            .font(.callout)

            Text("Then: double-tap Right Option to start, talk while pointing, tap it again to stop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Settings") { model.onOpenSettings?() }
                Spacer()
                Button(model.allGranted ? "Done" : "Later") { model.onDone?() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }
}
