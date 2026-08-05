import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS — the one thing a fresh install needs
//
// A transcription key. Nothing else belongs here: every other decision Fovea
// makes is either settled in the design or answered per-session on the orb.
// There used to be a row per coding client, writing that client's MCP config —
// gone along with the bridge it pointed at. Nothing needs connecting any more.
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
    /// Momentary, so the button can say it worked.
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel("TRANSCRIPTION")
                keys
                Text("Keys never leave the login keychain. Your recording is deleted as soon as the brief is made — what stays on this Mac is the brief and its screenshots.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                about
            }
            .padding(24)
        }
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

    /// The version, and one button that makes a bug report answerable.
    private var about: some View {
        HStack(spacing: 10) {
            Text("Fovea \(FoveaVersion.current) (\(FoveaVersion.build))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy diagnostics") {
                Diagnostics.copyToPasteboard()
                copied = true
                // Long enough to notice, short enough that the button is not
                // stuck reading "Copied" the next time somebody needs it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            .help("Version, permissions and where the log is — no session content.")
            Button("Reveal log") { Diagnostics.revealLog() }
        }
        .font(.system(size: 12))
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
