import AppKit
import DeikoGesture
import ServiceManagement
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

    /// The session being recorded right now, so "delete all past sessions"
    /// cannot remove the folder being written to. Set by `MenuBar`, which owns
    /// the recorder — this window has no reference to it and should not grow
    /// one for a single guard.
    var openSessionDir: (() -> String?)?

    /// Which folder this run is actually using. `--out` moves it, and Settings
    /// reading the default instead would count one folder while deleting
    /// another — pointing "Delete all past sessions" at the user's real
    /// sessions during a run that never touched them.
    var sessionRoot: String = Sessions.defaultRoot

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView(openSessionDir: openSessionDir, sessionRoot: sessionRoot)
        )
        // The window's size is the design's, not SwiftUI's — see `Orb.swift`'s
        // `makeWindow` for what the default does to a fixed frame.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Deiko Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Tall enough that Save is reachable without scrolling. 460 was right
        // when this window held two key rows; the plan card added ~160pt and
        // pushed the button below the fold, which makes a form look broken.
        // The usage bar, the buy/remove row and the sessions card have each
        // taken another slice since — same rule, same consequence.
        window.setContentSize(NSSize(width: 520, height: 760))
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

    /// The numbers behind that line — what is used, what is left.
    ///
    /// Seeded from the cache so the card draws real figures the moment the
    /// window opens instead of an empty bar that fills in a second later. On a
    /// failed refresh the last known numbers STAY: "we could not ask" is not
    /// the same fact as "you have nothing", and blanking the bar would say the
    /// second one.
    @Published private(set) var quota: License.Quota? = License.cachedQuota

    var isPro: Bool { License.isPro }

    /// Whether the relay's LATEST answer says Pro — which is what the buttons
    /// follow. `License.isPro` carries a seven-day grace so a developer on a
    /// plane keeps their own API keys editable; following it here would keep
    /// offering "manage your subscription" to somebody whose key lapsed a week
    /// ago, and hide the way to renew it.
    var isProNow: Bool { quota?.isPro ?? License.isPro }

    /// Ask the relay what this install is. Also the confirmation that a pasted
    /// key worked, which is why it runs on open and again on save.
    func refreshPlan() async {
        checking = true
        defer { checking = false }
        do {
            let quota = try await License.refresh()
            self.quota = quota
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

    // ── Sessions ────────────────────────────────────────────────────────────

    @Published private(set) var sessionCount = 0
    @Published private(set) var sessionSize = ""

    /// The session currently being recorded, so "delete all" cannot remove the
    /// folder being written to. Supplied by `MenuBar`, which owns the recorder;
    /// this window has no reference to it and should not grow one.
    var openSessionDir: (() -> String?)?

    /// The folder this run is using — see the controller's property.
    var sessionRoot = Sessions.defaultRoot

    /// Counted and measured off the main thread — `sizeBytes` walks the whole
    /// tree, and a year of sessions is thousands of PNGs.
    func refreshSessions() async {
        let root = sessionRoot
        let names = await Task.detached(priority: .utility) { Sessions.list(root: root) }.value
        let bytes = await Task.detached(priority: .utility) { Sessions.sizeBytes(root: root) }.value
        sessionCount = names.count
        sessionSize = Sessions.humanSize(bytes)
    }

    func deleteAllSessions() async {
        let open = openSessionDir?()
        let root = sessionRoot
        _ = await Task.detached(priority: .utility) {
            Sessions.deleteAll(root: root, keeping: open)
        }.value
        await refreshSessions()
    }

    // ── Startup ─────────────────────────────────────────────────────────────

    /// Whether macOS launches Deiko at login.
    ///
    /// Read from `SMAppService` rather than mirrored in a default, so the
    /// toggle reflects what the SYSTEM believes — somebody who turns Deiko off
    /// in System Settings → General → Login Items must not come back to a
    /// switch still showing on.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Throws for a bare SwiftPM binary, which has no bundle to
            // register — the development path. Re-read rather than assert, so
            // the toggle snaps back to the truth instead of lying.
            Emit.log("launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // ── The session key ─────────────────────────────────────────────────────

    @Published var sessionKey = SessionKey.selected

    func setSessionKey(_ key: SessionKey) {
        SessionKey.selected = key
        sessionKey = key
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
    /// Passed down rather than read from a global: see the controller's
    /// properties of the same names.
    let openSessionDir: (() -> String?)?
    let sessionRoot: String
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
                SectionLabel("CAPTURING")
                capturing
                SectionLabel("SESSIONS")
                sessions
                Divider()
                about
            }
            .padding(24)
        }
        .task {
            model.openSessionDir = openSessionDir
            model.sessionRoot = sessionRoot
            await model.refreshPlan()
            await model.refreshSessions()
        }
    }

    /// Which key starts a session, and whether Deiko is here when you log in.
    private var capturing: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Session key")
                        .font(.system(size: 13))
                        .frame(width: 96, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.sessionKey },
                        set: { model.setSessionKey($0) }
                    )) {
                        ForEach(SessionKey.allCases, id: \.self) { key in
                            Text(key.name).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Spacer()
                }
                // Named because the default collides with a real key on most
                // of the world's keyboards, and somebody hitting that has no
                // way to guess this setting exists.
                Text("Double-tap to start, tap to stop. Right Option is AltGr on many "
                    + "layouts — if typing brackets keeps starting a session, pick another key.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Open Deiko at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .font(.system(size: 13))
            }
            .padding(14)
        }
    }

    /// What the sessions folder is costing, and the two things to do about it.
    private var sessions: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.sessionCount == 0
                    ? "No sessions yet."
                    : "\(model.sessionCount) session\(model.sessionCount == 1 ? "" : "s") · \(model.sessionSize) in ~/Documents/Deiko")
                    .font(.system(size: 13))

                Text(Sessions.retentionDays > 0
                    ? "Sessions older than \(Sessions.retentionDays) days are removed when Deiko starts. Your recordings were already deleted as each brief was made — this is the screenshots."
                    : "Nothing is removed automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Open folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.sessionRoot))
                    }
                    Spacer()
                    Button("Delete all past sessions…", role: .destructive) {
                        let alert = NSAlert()
                        alert.alertStyle = .critical
                        alert.messageText = "Delete every past session?"
                        alert.informativeText =
                            "Removes \(model.sessionCount) session\(model.sessionCount == 1 ? "" : "s") "
                            + "and their screenshots. A session being recorded right now is kept. "
                            + "This cannot be undone."
                        alert.addButton(withTitle: "Delete")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Task { await model.deleteAllSessions() }
                    }
                    .disabled(model.sessionCount == 0)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
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
                    // The card only asked on open and on Apply, so a bar
                    // somebody was watching never moved. Same fetch, on demand;
                    // "checking…" above is the feedback, so no spinner.
                    Button { Task { await model.refreshPlan() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.checking)
                    .help("Ask Deiko again how much is left")
                }

                // HOW MUCH IS LEFT, as a quantity rather than a sentence.
                //
                // The trial's whole shape — thirty minutes, once — was
                // knowable only by reading a sentence in a window nobody
                // opens, so the first anybody learned of running out was a
                // transcript that quietly read worse. A bar answers "am I
                // close?" at a glance, which a sentence never does.
                if let quota = model.quota {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: quota.usedFraction)
                            .tint(quota.isSpent ? DeikoStyle.needsYou : DeikoStyle.accent)
                        Text(quota.isPro
                            ? "\(quota.usedSentence) · \(License.Quota.proResetSentence)"
                            : "\(quota.usedSentence) · one-time trial, then this Mac transcribes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

                // BUY, RENEW, REMOVE — the three things a licence needs doing
                // to it that were not possible from inside the app at all.
                //
                // "Get Pro" appears when the relay's latest answer is not Pro,
                // which covers both the never-bought case and the lapsed one:
                // a key that has stopped validating needs a way to renew, and
                // that way is the same checkout.
                //
                // ONLY when a checkout URL was stamped into this build. As
                // things stand the published site answers 404 on every path,
                // so a link derived from it would send somebody who had just
                // decided to pay to a broken page — the worst possible moment
                // for the product to look unfinished.
                HStack(spacing: 12) {
                    if !model.isProNow, let buy = Credentials.buyURL {
                        Button("Get Pro…") { NSWorkspace.shared.open(buy) }
                            .buttonStyle(.link)
                    }
                    // There is no "manage subscription" BUTTON, and that is not
                    // an omission: Polar's customer portal is authenticated by
                    // an emailed code, and the link that arrives with the
                    // purchase is the shortest path back to it. Saying where it
                    // is beats sending somebody to a sign-in they did not want.
                    if model.isProNow {
                        Text("Manage or cancel from the link in your purchase email.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if License.key != nil {
                        Button("Remove key from this Mac") {
                            model.licenseKey = ""
                            Task { await model.saveLicense() }
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .help("Forgets the key and its cached plan. Nothing is cancelled — "
                            + "your subscription is between you and Polar.")
                    }
                }
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
            // Only when this build knows where feedback goes. Copying
            // diagnostics with nowhere to send them was the whole of the old
            // bug-report story.
            if Diagnostics.feedbackURL() != nil {
                Button("Send feedback…") {
                    if let url = Diagnostics.feedbackURL() { NSWorkspace.shared.open(url) }
                }
            }
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
