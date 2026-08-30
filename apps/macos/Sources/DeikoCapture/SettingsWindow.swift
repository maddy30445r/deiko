import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS — the one thing a fresh install needs
//
// A licence key, and a transcription key. Nothing else belongs here: every
// other decision Deiko makes is either settled in the design or answered
// per-session on the orb. There used to be a row per coding client, writing
// that client's MCP config — gone along with the bridge it pointed at. Nothing
// needs connecting any more.
//
// The licence row is not a sign-in. There is no email, no password, no account
// to recover — the key IS the entitlement, and the window says so, because a
// box that looks like a login makes people go looking for a password they were
// never given.
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
        window.title = "Deiko Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Tall enough that Save is reachable without scrolling. 460 was right
        // when this window held two key rows; the plan card added ~160pt and
        // pushed the button below the fold, which makes a form look broken.
        window.setContentSize(NSSize(width: 520, height: 620))
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

    // ── Licence ─────────────────────────────────────────────────────────────

    /// Shown in full rather than masked. It is not a secret — the relay treats
    /// it as a bearer and says so out loud — and somebody who has just pasted a
    /// key out of an email needs to be able to see that they pasted it right.
    @Published var licenseKey: String = License.key ?? ""
    @Published private(set) var checking = false

    /// What the relay last said about this install, in one line.
    @Published private(set) var plan = "Free"
    @Published private(set) var planDetail = "checking…"
    @Published private(set) var planIsProblem = false

    var isPro: Bool { License.isPro }

    /// Ask the relay what this install is. Also the confirmation that a pasted
    /// key worked, which is why it runs on open and again on save.
    func refreshPlan() async {
        checking = true
        defer { checking = false }
        do {
            let quota = try await License.refresh()
            plan = quota.isPro ? "Pro" : "Free"
            planDetail = quota.isPro
                ? "\(quota.remainingSentence) this month"
                : (License.key == nil
                    ? "\(quota.remainingSentence) of your trial"
                    : "that key is not active — \(quota.remainingSentence) of your trial")
            planIsProblem = !quota.isPro && License.key != nil
        } catch License.Failure.noRelay {
            plan = "On-device"
            planDetail = "this build has no transcription service — nothing is uploaded"
            planIsProblem = false
        } catch {
            // An unreachable relay is NOT reported as a downgrade. The cached
            // verdict still stands for a week, and telling somebody who has
            // paid that they are on Free because their wifi dropped is the
            // wrong failure to make loud.
            plan = License.isPro ? "Pro" : "Free"
            planDetail = "could not reach Deiko just now"
            planIsProblem = false
        }
    }

    func saveLicense() async {
        License.store(licenseKey)
        await refreshPlan()
    }

    /// "Sarvam: from your login keychain · Groq: not set" — per key, because
    /// the two can genuinely come from different places.
    var keySources: String {
        "Sarvam: \(Credentials.source(of: "SARVAM_API_KEY")) · Groq: \(Credentials.source(of: "GROQ_API_KEY"))"
    }

    /// Whether a key will actually be USED — not merely whether one is stored.
    ///
    /// The two differ now that BYO is gated: a key can sit in the keychain and
    /// be ignored, and a `.env` key is used even without a licence. `willUse`
    /// is the same question the pipeline asks, which is the point — this used
    /// to be its own rule and told a developer their live key was not in play.
    var usingOwnKey: Bool {
        if sarvamTouched { return !sarvamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Credentials.willUse("SARVAM_API_KEY")
    }

    /// The little grey word beside a key's label.
    ///
    /// "Pro" would be a lie on a checkout, where the `.env` key is live without
    /// anybody having paid — so the tag reports what is TRUE of this key rather
    /// than what is true of the plan.
    func tag(for name: String) -> String {
        if License.isPro { return "optional" }
        if Credentials.willUse(name) { return "in use" }
        return "Pro"
    }

    /// Where narration audio goes, in one sentence, stated before anything is
    /// recorded rather than after.
    var whereAudioGoes: String {
        if usingOwnKey {
            return "Your narration goes straight to Sarvam with your key. Deiko's servers never see it."
        }
        if Credentials.relayURL != nil {
            return isPro
                ? "Your narration goes to Deiko, which passes it to a transcription service and keeps nothing. Add your own key below to skip Deiko entirely."
                : "Your narration goes to Deiko, which passes it to a transcription service and keeps nothing. When your trial runs out, transcription continues on this Mac."
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
                SectionLabel("PLAN")
                licence
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
        .task { await model.refreshPlan() }
    }

    /// The plan, and the box that changes it. No email, no password — the line
    /// underneath says so, because a key field with a Save button next to it
    /// otherwise reads as half a login form.
    private var licence: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(model.plan)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.checking ? "checking…" : model.planDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(model.planIsProblem ? DeikoStyle.needsYou : .secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Text("Licence key")
                        .font(.system(size: 13))
                        .frame(width: 96, alignment: .leading)
                    TextField("paste the key from your email…", text: $model.licenseKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("No account, no password. The key is the whole thing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") { Task { await model.saveLicense() } }
                        .disabled(model.checking)
                        .tint(DeikoStyle.accent)
                }
                .padding(.top, 2)
            }
            .padding(14)
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

                keyRow(label: "Sarvam", tag: model.tag(for: "SARVAM_API_KEY"),
                       text: $model.sarvamKey,
                       touched: $model.sarvamTouched,
                       prompt: model.placeholder(stored: model.sarvamStored),
                       enabled: model.isPro)
                keyRow(label: "Groq", tag: model.tag(for: "GROQ_API_KEY"),
                       text: $model.groqKey,
                       touched: $model.groqTouched,
                       prompt: model.groqStored ? model.placeholder(stored: true) : "gsk_…",
                       enabled: model.isPro)
                if !model.isPro && !model.usingOwnKey {
                    Text("Using your own keys is part of Pro — then your narration never touches Deiko's servers at all.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        .tint(DeikoStyle.accent)
                        .disabled(!model.isPro)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    /// The version, and one button that makes a bug report answerable.
    private var about: some View {
        HStack(spacing: 10) {
            Text("Deiko \(DeikoVersion.current) (\(DeikoVersion.build))")
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
        touched: Binding<Bool>, prompt: String, enabled: Bool
    ) -> some View {
        HStack(spacing: 10) {
            (Text(label).font(.system(size: 13))
                + Text("  \(tag)").font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(width: 96, alignment: .leading)
            SecureField(prompt, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
                .onChange(of: text.wrappedValue) { touched.wrappedValue = true }
        }
        .opacity(enabled ? 1 : 0.55)
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
                RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}
