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
//
// The three agent states keep their exact distinctions — "Connected ·
// /fovea:brief" (mono, because it is a command), "Installed, not connected",
// "Not found on this Mac" — because collapsing them is how a user ends up
// connecting a client they don't have, or hunting for one they do.
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
        // The window's size is the design's, not SwiftUI's — see `Orb.swift`'s
        // `makeWindow` for what the default does to a fixed frame.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fovea Settings"
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

    /// The boxes start EMPTY even when a key is stored.
    ///
    /// Pre-filling them meant decrypting on every open, which is what made
    /// macOS demand the login password every single time this window appeared.
    /// It also pulled two live credentials into view state for no reason —
    /// nothing here ever needed to read a key back, only to replace one.
    @Published var sarvamKey: String = ""
    @Published var groqKey: String = ""
    /// Whether the developer has actually typed in each box. An untouched box
    /// means "leave this alone"; a touched-and-emptied one means "remove it".
    @Published var sarvamTouched = false
    @Published var groqTouched = false

    @Published private(set) var sarvamStored = Credentials.exists("SARVAM_API_KEY")
    @Published private(set) var groqStored = Credentials.exists("GROQ_API_KEY")

    /// "Sarvam: from your login keychain · Groq: not set" — per key, because
    /// the two can genuinely come from different places.
    var keySources: String {
        "Sarvam: \(Credentials.source(of: "SARVAM_API_KEY")) · Groq: \(Credentials.source(of: "GROQ_API_KEY"))"
    }

    /// Whether a key is set at all — no longer a warning, because a session
    /// without one now works. What it changes is WHO transcribes, and that is
    /// worth saying plainly rather than as an alarm.
    var usingOwnKey: Bool {
        if sarvamTouched { return !sarvamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return sarvamStored
    }

    /// Where narration audio goes, in one sentence, stated before anything is
    /// recorded rather than after.
    var whereAudioGoes: String {
        if usingOwnKey {
            return "Your narration goes straight to Sarvam with your key. Fovea's servers never see it."
        }
        if Credentials.relayURL != nil {
            return "Your narration goes to Fovea, which passes it to a transcription service and keeps nothing. Add your own key below to skip Fovea entirely."
        }
        return "Transcription runs on this Mac. Nothing is uploaded — accuracy is lower, especially for mixed-language speech."
    }

    func placeholder(stored: Bool) -> String {
        stored ? "•••••••••• — type to replace" : "paste a key…"
    }

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

    /// Only boxes the developer actually touched are written. An untouched
    /// empty box must not delete a perfectly good stored key — which is
    /// exactly what saving would have done once the boxes stopped pre-filling.
    /// The text is deliberately NOT cleared afterwards: `onChange` cannot tell
    /// a programmatic reset from typing, so clearing here would mark the box
    /// touched-and-empty and the next Save would delete the key that was just
    /// stored.
    func saveKeys() {
        if sarvamTouched {
            Credentials.store(sarvamKey, for: "SARVAM_API_KEY")
            sarvamTouched = false
        }
        if groqTouched {
            Credentials.store(groqKey, for: "GROQ_API_KEY")
            groqTouched = false
        }
        sarvamStored = Credentials.exists("SARVAM_API_KEY")
        groqStored = Credentials.exists("GROQ_API_KEY")
    }
}

// ── View ────────────────────────────────────────────────────────────────────

private struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel("CODING AGENTS — WHERE BRIEFS LAND")
                clients
                SectionLabel("TRANSCRIPTION")
                    .padding(.top, 2)
                keys
                Text("Keys never leave the login keychain. Your recording is deleted as soon as the brief is made — what stays on this Mac is the brief and its screenshots.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .onAppear { model.refresh() }
    }

    private var clients: some View {
        VStack(alignment: .leading, spacing: 8) {
            InsetCard {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    HStack(spacing: 12) {
                        roundel(for: row)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.system(size: 13, weight: .semibold))
                            if row.isConnected {
                                Text("Connected · \(row.commandForm)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(row.isInstalled ? "Installed, not connected" : "Not found on this Mac")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if row.isConnected {
                            // Every state this window can reach has to be one
                            // you can leave. Connect without Disconnect is a
                            // one-way door into a file the user cannot see.
                            Button("Disconnect") { model.disconnect(row.id) }
                        } else {
                            // The canvas drops this button on not-found rows.
                            // Kept, deliberately: "Not found" is a guess from
                            // three filesystem signals, all of which have false
                            // negatives — a wrong guess must not stand between
                            // someone and the button they came here to press.
                            Button("Connect") { model.connect(row.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .opacity(row.isConnected || row.isInstalled ? 1 : 0.55)
                }
            }

            if let problem = model.problem {
                // The whole message, selectable. A connector failure is about a
                // file path, and a truncated path is not actionable.
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(FoveaStyle.needsYou)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func roundel(for row: SettingsModel.Row) -> some View {
        ZStack {
            if row.isConnected {
                Circle().fill(FoveaStyle.sentGreen.opacity(0.14))
                Circle().strokeBorder(FoveaStyle.sentGreen, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FoveaStyle.sentGreen)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(row.isInstalled ? 0.5 : 0.35), lineWidth: 1.5)
                if !row.isInstalled {
                    Text("–").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 22, height: 22)
    }

    private var keys: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.whereAudioGoes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                keyRow(label: "Sarvam", tag: "optional", text: $model.sarvamKey,
                       touched: $model.sarvamTouched,
                       prompt: model.placeholder(stored: model.sarvamStored))
                keyRow(label: "Groq", tag: "optional", text: $model.groqKey,
                       touched: $model.groqTouched,
                       prompt: model.groqStored ? model.placeholder(stored: true) : "gsk_…")
                HStack {
                    // No longer a warning. A missing key used to mean briefs
                    // stopped at "Transcribing…"; now it means somebody else
                    // transcribes, which the sentence above already explains.
                    Text(model.keySources)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { model.saveKeys() }
                        .keyboardShortcut(.defaultAction)
                        .tint(FoveaStyle.accent)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    private func keyRow(
        label: String, tag: String, text: Binding<String>,
        touched: Binding<Bool>, prompt: String
    ) -> some View {
        HStack(spacing: 10) {
            (Text(label).font(.system(size: 13))
                + Text("  \(tag)").font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(width: 96, alignment: .leading)
            SecureField(prompt, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { touched.wrappedValue = true }
        }
    }
}

// ── Shared pieces (Settings + first run share this vocabulary) ──────────────

/// The uppercase 11pt section label the canvas uses everywhere.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.66)
            .foregroundStyle(.secondary)
    }
}

/// A white/inset rounded card holding rows — the canvas's grouping surface.
struct InsetCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FoveaStyle.insetRadius)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: FoveaStyle.insetRadius)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}
