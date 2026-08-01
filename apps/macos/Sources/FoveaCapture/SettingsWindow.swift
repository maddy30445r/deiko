import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS — the two things a fresh install needs
//
// A connected coding client, and a transcription key. Nothing else belongs
// here: every other decision Fovea makes is either settled in the design or
// answered per-session on the orb.
//
// The connector rows are modelled on JetBrains Rider's MCP pane, which offers
// exactly this — one row per coding client, with a button that writes that
// client's config. There is no documented third-party API for registering an
// MCP server, so this is the shape the ecosystem has converged on.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fovea — Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // An accessory app's window opens behind whatever the developer was
        // looking at unless it asks — the same reason the orb activates.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// ── State ───────────────────────────────────────────────────────────────────

@MainActor
final class SettingsModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let name: String
        let isInstalled: Bool
        let isConnected: Bool
        let commandForm: String
    }

    @Published var rows: [Row] = []
    @Published var problem: String?

    @Published var sarvamKey: String = Credentials.value(for: "SARVAM_API_KEY") ?? ""
    @Published var groqKey: String = Credentials.value(for: "GROQ_API_KEY") ?? ""

    /// Where the keys currently come from, so a developer with a `.env` is not
    /// told to type a key they already have.
    var keySource: String { Credentials.sourceDescription() }

    func refresh() {
        rows = Connectors.all.map {
            Row(
                id: $0.name,
                name: $0.name,
                isInstalled: $0.isInstalled,
                isConnected: $0.isConnected,
                commandForm: $0.commandForm
            )
        }
    }

    func connect(_ id: String) {
        guard let connector = Connectors.all.first(where: { $0.name == id }) else { return }
        problem = nil
        do {
            try Connectors.connect(connector)
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func disconnect(_ id: String) {
        guard let connector = Connectors.all.first(where: { $0.name == id }) else { return }
        problem = nil
        do {
            try Connectors.disconnect(connector)
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    func saveKeys() {
        Credentials.store(sarvamKey, for: "SARVAM_API_KEY")
        Credentials.store(groqKey, for: "GROQ_API_KEY")
    }
}

// ── View ────────────────────────────────────────────────────────────────────

private struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                clients
                Divider()
                keys
            }
            .padding(22)
        }
        .onAppear { model.refresh() }
    }

    private var clients: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coding agents").font(.headline)
            Text("Connecting registers Fovea's bridge so the agent can fetch a brief you hand it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(row.isConnected ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(
                            row.isConnected
                                ? "Connected · \(row.commandForm)"
                                : row.isInstalled ? "Installed, not connected" : "Not found on this Mac"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.isConnected {
                        // Every state this window can reach has to be one you
                        // can leave. Connect without Disconnect is a one-way
                        // door into a file the user cannot see.
                        Button("Disconnect") { model.disconnect(row.id) }
                    } else {
                        // Never disabled on detection. "Not found" is a guess
                        // from three filesystem signals, all of which have false
                        // negatives — and a wrong guess must not stand between
                        // someone and the button they came here to press.
                        Button("Connect") { model.connect(row.id) }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let problem = model.problem {
                // The whole message, selectable. A connector failure is about a
                // file path, and a truncated path is not actionable.
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcription").font(.headline)
            Text(model.keySource).font(.caption).foregroundStyle(.secondary)

            LabeledContent("Sarvam") {
                SecureField("required — transcribes your narration", text: $model.sarvamKey)
            }
            LabeledContent("Groq") {
                SecureField("optional — the orb's three-line reading", text: $model.groqKey)
            }
            HStack {
                Spacer()
                Button("Save") { model.saveKeys() }.keyboardShortcut(.defaultAction)
            }
            Text("Keys are stored in your login keychain, never in the app bundle.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
