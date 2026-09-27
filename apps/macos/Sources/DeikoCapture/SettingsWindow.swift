import AppKit
import DeikoGesture
import ServiceManagement
import SwiftUI
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// SETTINGS — a section of the Deiko window, not a window of its own
//
// A licence key, and a transcription key. Nearly every other decision Deiko
// makes is either settled in the design or answered per-session on the orb —
// the one exception is the Memory section's button, which is the only thing
// here that writes to a file this app does not own (see `MemoryHelper`).
// There used to be a row per coding client too, writing that client's own
// bridge config — gone along with the bridge it pointed at.
//
// The licence row is not a sign-in. There is no email, no password, no account
// to recover — the key IS the entitlement, and the window says so, because a
// box that looks like a login makes people go looking for a password they were
// never given.
//
// It had its own 520pt window until the board and personas arrived and made a
// second, smaller window with its own chrome look like what it was: a settings
// sheet bolted onto an app. `MainWindow` presents this view now; the sizing
// note that used to live here belongs to that window.
// ─────────────────────────────────────────────────────────────────────────────

// ── State ───────────────────────────────────────────────────────────────────

@MainActor
final class SettingsModel: ObservableObject {

    @Published var appearance: Appearance = Appearance.selected

    func setAppearance(_ next: Appearance) {
        appearance = next
        Appearance.selected = next
    }

    /// The boxes start EMPTY even when a key is stored.
    ///
    /// Pre-filling them meant decrypting on every open, which is what made
    /// macOS demand the login password every single time this window appeared.
    /// It also pulled two live credentials into view state for no reason —
    /// nothing here ever needed to read a key back, only to replace one.
    /// ONE KEY, and that is what makes the promise beside it true. There were
    /// two — Sarvam for the words, Groq for the summary — and "Deiko's servers
    /// never see it" was false for anybody who brought only the first, which is
    /// what most people did. Whisper does both, so bringing one key really does
    /// take us out of the path.
    @Published var groqKey: String = ""
    /// Whether the developer has actually typed in the box. An untouched box
    /// means "leave this alone"; a touched-and-emptied one means "remove it".
    @Published var groqTouched = false

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
    /// follow. `License.isPro` carries a seven-day grace so a paying customer on
    /// a plane still reads as Pro; following it here would keep
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
            // A KEY THAT DOES NOT VALIDATE HAS NO ALLOWANCE OF ITS OWN, and
            // the sentence has to say so. It used to read "that key is not
            // active — 30 min left of your trial" beside a full bar, which
            // reads as a trial that reset. Nothing had reset: the bearer had
            // changed, so a different subject's empty counter was on screen,
            // and the machine's own trial was sitting where it was left. Say
            // what to do instead of describing a trial they never started.
            planDetail = quota.isPro
                ? "\(quota.remainingSentence) this month"
                : (License.key == nil
                    ? "\(quota.remainingSentence) of your trial"
                    : "that key is not active — remove it to use this Mac's trial")
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

    /// Whether a brief the classifier called quick carries the line telling
    /// the agent a fast model is probably enough.
    ///
    /// OFF by default, and advisory even when on: Deiko does not pick the
    /// model — whichever harness the brief lands in already did — so the most
    /// this can honestly do is say what the brief looks like and leave the
    /// judgement where it actually sits.
    @Published var optimizeCosts = UserDefaults.standard.bool(forKey: BriefPipeline.optimizeCostsKey)

    /// The Monday note — see `WeeklyNote`. Off unless turned on.
    @Published var weeklyNote = WeeklyNote.enabled

    func setWeeklyNote(_ on: Bool) {
        WeeklyNote.setEnabled(on)
        weeklyNote = on
    }

    func setOptimizeCosts(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BriefPipeline.optimizeCostsKey)
        optimizeCosts = on
    }

    /// "Sort briefs into tasks" — see `Credentials.sortsBriefs`, which the
    /// pipeline reads when it next runs. Published so the sentence about what
    /// leaves this Mac changes the moment the switch does.
    @Published var sortBriefs = Credentials.sortsBriefs

    func setSortBriefs(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Credentials.sortBriefsKey)
        sortBriefs = on
    }

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

    // ── What language the brief is in ───────────────────────────────────────

    @Published var narration = Narration.selected
    @Published var speechLocale = SpeechLocale.selected
    /// Asked once, on first read: the speech framework answers per locale.
    let onDeviceLocales = SpeechLocale.onDevice

    func setNarration(_ value: Narration) {
        Narration.selected = value
        narration = value
    }

    func setSpeechLocale(_ identifier: String) {
        SpeechLocale.selected = identifier
        speechLocale = identifier
    }

    /// "Groq: from your login keychain" — named, because
    /// the two can genuinely come from different places.
    var keySources: String {
        "Groq: \(Credentials.source(of: "GROQ_API_KEY"))"
    }

    /// Whether a key will actually be USED — not merely whether one is stored.
    ///
    /// The two agree now that BYO is free, and the call stays anyway: `willUse`
    /// is the same question the pipeline asks, which is the point — this used
    /// to be its own rule and told a developer their live key was not in play.
    var usingOwnKey: Bool {
        if groqTouched { return !groqKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Credentials.willUse("GROQ_API_KEY")
    }

    /// The little grey word beside a key's label.
    ///
    /// Reports what is TRUE of this key rather than what is true of the plan:
    /// bringing one is free, so the only two states are "there is one and it is
    /// what runs" and "there is none and nothing needs one".
    func tag(for name: String) -> String {
        Credentials.willUse(name) ? "in use" : "optional"
    }

    /// Where narration audio goes, in one sentence, stated before anything is
    /// recorded rather than after.
    var whereAudioGoes: String {
        if usingOwnKey {
            // NO LONGER "Deiko's servers never see it" — the owner decided
            // sorting runs through the relay for everyone, own-key users
            // included, so a brief can still be placed into a task. Audio
            // goes straight to Groq with the user's own key, exactly as
            // before, and never reaches Deiko; the summary is produced there
            // too, but a redacted copy of it still travels through the
            // classifier — so this sentence has to admit that, not claim the
            // summary never reaches Deiko either.
            //
            // THE SORTING CLAUSE IS CONDITIONAL, NOT ALWAYS TRUE. A build with
            // no relay stamped at all (`Credentials.relayURL == nil`) never
            // gets `DEIKO_CLASSIFY_URL` either — `childEnvironment` sets it
            // from the same `relayURL` — and nor does anybody who turned
            // "Sort briefs into tasks" off, so nothing is sorted and nothing
            // reaches Deiko. Saying otherwise there would be the exact bug
            // this sentence exists to avoid, just moved one line down.
            let goesToGroq = "Your narration goes straight to Groq with your key. \(narration.comesBackAs)"
            guard sortBriefs, Credentials.relayURL != nil else { return goesToGroq }
            return goesToGroq + " To sort each brief into its task, what you said, a one-line summary, your window and page titles, web addresses (just the host and path, never what's after the ?), open document names and notes on earlier work go to Deiko, which passes them to TypeSafe's Jev sorting model and keeps nothing."
        }
        if Credentials.relayURL != nil {
            let ownKey = sortBriefs
                ? "Add your own key below and transcription and the summary happen at Groq instead; sorting still sends what you said, a one-line summary, your window and page titles, web addresses (just the host and path, never what's after the ?), open document names and notes on earlier work through Deiko to TypeSafe's Jev sorting model; Deiko keeps nothing."
                : "Add your own key below and transcription and the summary happen at Groq instead."
            return isPro
                ? "Your narration goes to Deiko, which passes it to a transcription service and keeps nothing. \(narration.comesBackAs) \(ownKey)"
                : "Your narration goes to Deiko, which passes it to a transcription service and keeps nothing. \(narration.comesBackAs) When your trial runs out, transcription continues on this Mac, in the offline language below. \(ownKey)"
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
        if groqTouched {
            Credentials.store(groqKey, for: "GROQ_API_KEY")
            groqTouched = false
        }
        groqStored = Credentials.exists("GROQ_API_KEY")
    }
}

// ── View ────────────────────────────────────────────────────────────────────

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @ObservedObject private var meaning = MeaningModel.shared
    /// Passed down rather than read from a global: see the controller's
    /// properties of the same names.
    let openSessionDir: (() -> String?)?
    let sessionRoot: String
    /// Momentary, so the button can say it worked.
    @State private var copied = false
    /// Which agents are on this Mac, and which already have the memory helper.
    @State private var helper = MemoryHelper.Status()
    /// What the button's last press said, or nil for the default caption.
    @State private var helperMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").deikoTitle(24)
                    Text("Keys, capture and what stays on this Mac.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeikoStyle.ink2)
                }
                .padding(.bottom, 2)
                SectionLabel("Plan")
                licence
                SectionLabel("Transcription")
                language
                keys
                Text("Keys are kept in your login keychain. Your recording is deleted as soon as the brief is made — what stays on this Mac is the brief and its screenshots. If a brief fails, its recording stays until you delete that session.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                // Only with a relay: without one nothing is filed through
                // Deiko either way, and what needs no relay is placed anyway.
                if Credentials.relayURL != nil {
                    SectionLabel("Tasks")
                    sorting
                }
                SectionLabel("Memory")
                memory
                SectionLabel("Capturing")
                capturing
                SectionLabel("Appearance")
                appearance
                SectionLabel("Sessions")
                sessions
                Divider()
                about
            }
            .padding(.horizontal, 26)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Open Deiko at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .font(.system(size: 13))

                Divider()

                Toggle("Mention when a brief looks quick", isOn: Binding(
                    get: { model.optimizeCosts },
                    set: { model.setOptimizeCosts($0) }
                ))
                .font(.system(size: 13))
                Text("Adds one line to a small brief saying a fast model is probably enough. Your agent still decides for itself — Deiko has never picked the model and this does not change that.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("A Monday note on where things stand", isOn: Binding(
                    get: { model.weeklyNote },
                    set: { model.setWeeklyNote($0) }
                ))
                .font(.system(size: 13))
                Text("Monday morning, one notification: how many pieces of work moved last week and how many still have something open. Click it for the list. Made on your Mac from your board.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    /// Whether a brief is filed with the earlier work it belongs to — the one
    /// switch over what leaves this Mac besides the key above.
    private var sorting: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Sort briefs into tasks", isOn: Binding(
                    get: { model.sortBriefs },
                    set: { model.setSortBriefs($0) }
                ))
                .font(.system(size: 13))
                Text("Files each brief with the earlier work it belongs to. To do that, what you said, a one-line summary, your window and page titles, web addresses (just the host and path, never what's after the ?), open document names and notes on earlier work go through Deiko's relay to TypeSafe's Jev sorting model; the relay keeps nothing. Off: nothing is sent to file them, and a new brief joins earlier work only when you move it there or it's a short follow-up on the same window.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    /// What Deiko keeps on this Mac to remember earlier work. The model line
    /// is quiet on purpose: it is a download in the background, not a task.
    private var memory: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                switch meaning.state {
                case .checking:
                    captionLine("Meaning model: checking…")
                case .downloading(let done, let total):
                    captionLine(total > 0
                        ? "Meaning model: downloading, \(done / 1_000_000) of \(total / 1_000_000) MB"
                        : "Meaning model: starting the download…")
                case .ready:
                    captionLine("Meaning model ready. Deiko matches briefs by what they mean, not only the words.")
                case .failed(let why):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        captionLine("Meaning model not downloaded (\(why)). Deiko matches briefs by their words until it is.")
                        Button("Try again") { meaning.start() }
                    }
                case .off:
                    captionLine("Meaning model off. Deiko matches briefs by their words.")
                }

                Divider()

                HStack(spacing: 8) {
                    Button(helper.allSet ? "Remove Deiko memory from your agents" : "Give your agent your Deiko memory") {
                        let removing = helper.allSet
                        Task.detached(priority: .userInitiated) {
                            let message: String
                            if removing {
                                message = Self.sentence(MemoryHelper.disconnect(), did: "Removed from")
                                    + " Restart your agents to drop it."
                            } else {
                                do {
                                    let outcome = try MemoryHelper.connect()
                                    message = Self.sentence(outcome, did: "Set up in")
                                        + (outcome.done.isEmpty ? "" : " Restart \(outcome.done.count == 1 ? "it" : "them") to pick it up.")
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                            let status = MemoryHelper.status()
                            await MainActor.run { helperMessage = message; helper = status }
                        }
                    }
                    .disabled(helper.found.isEmpty)
                    Button("Copy setup") {
                        helperMessage = MemoryHelper.copySetup()
                            ? "Copied the command and a JSON entry. Paste either into your agent's MCP settings."
                            : MemoryHelper.Failure.noRuntime.localizedDescription
                    }
                    .tip("For any agent that takes MCP servers: copies the helper's command and a ready JSON entry.")
                }
                captionLine(helperMessage ?? Self.found(helper))
                captionLine("A small helper that runs only on this Mac. Your agent can search past briefs and open a task's history. It hands back only what your briefs already share: prompts, outcome notes, task notes and the screenshots you kept — never ones you removed. Using another agent? Copy setup gives you what to paste into its MCP settings.")
            }
            .padding(14)
        }
        .task {
            helper = await Task.detached { MemoryHelper.status() }.value
        }
    }

    /// The caption under the memory buttons before anything is pressed.
    private static func found(_ status: MemoryHelper.Status) -> String {
        let joined = { (names: [String]) in names.joined(separator: ", ") }
        let rest = status.found.filter { !status.connected.contains($0) }
        if status.found.isEmpty {
            return "No agent found on this Mac to set up. Copy setup works with any agent that takes MCP servers."
        }
        if status.connected.isEmpty { return "Found on this Mac: \(joined(status.found))." }
        if rest.isEmpty { return "Set up in: \(joined(status.connected))." }
        return "Set up in: \(joined(status.connected)). Not yet: \(joined(rest))."
    }

    /// What a press did, agent by agent — one that failed says why, and does
    /// not hide the ones that worked.
    nonisolated private static func sentence(_ outcome: AgentSetup.Outcome, did verb: String) -> String {
        var parts: [String] = []
        if !outcome.done.isEmpty { parts.append("\(verb): \(outcome.done.joined(separator: ", ")).") }
        for failure in outcome.failed { parts.append("\(failure.agent): \(failure.reason)") }
        return parts.isEmpty ? "Nothing to change." : parts.joined(separator: " ")
    }

    private func captionLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DeikoStyle.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Light, dark, or the system's answer — for every Deiko window, the orb
    /// included. See `Appearance`.
    private var appearance: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(Appearance.allCases) { choice in
                        Text(choice.name).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("Applies to every Deiko window, including the orb over your editor. The capturing pill stays red in both — it has one job and one colour.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
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
                    : "\(model.sessionCount) session\(model.sessionCount == 1 ? "" : "s") · \(model.sessionSize) on this Mac")
                    .font(.system(size: 13))

                Text(Sessions.retentionDays > 0
                    ? "Sessions older than \(Sessions.retentionDays) days are removed when Deiko starts. Your recordings were already deleted as each brief was made — this is the screenshots."
                    : "Nothing goes on a timer. The board is what Deiko remembers, so every brief here is one the next brief can be filed beside. Delete one from its card, or all of them below.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
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
                            + "and their screenshots, and the task notes made from them. "
                            + "A session being recorded right now is kept. "
                            + "The sessions go to the Trash; the task notes are deleted."
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
                    .deikoFocusRingLoose()
                    .foregroundStyle(DeikoStyle.ink2)
                    .disabled(model.checking)
                    .tip("Ask Deiko again how much is left")
                }

                // HOW MUCH IS LEFT, as a quantity rather than a sentence.
                //
                // The trial's whole shape — thirty minutes, once — was
                // knowable only by reading a sentence in a window nobody
                // opens, so the first anybody learned of running out was a
                // transcript that quietly read worse. A bar answers "am I
                // close?" at a glance, which a sentence never does.
                //
                // NOTHING TO DRAW WHEN THERE IS NO ALLOWANCE. A licence the
                // store does not recognise now has a cap of zero, and a bar of
                // zero read "none of none used · one-time trial, then this Mac
                // transcribes" — three claims, none of them true of a subject
                // that has no trial and never had one. The plan line above
                // already says what happened and what to do about it.
                if let quota = model.quota, quota.capSeconds > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        // DRAWN, not an NSProgressIndicator. The system bar
                        // ignores `.tint` on macOS — it follows the user's own
                        // accent colour — so the indigo fill this design asks
                        // for, and the red one when the trial is spent, simply
                        // never appeared. Two capsules cost less than the
                        // workaround would.
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DeikoStyle.hairline)
                                Capsule()
                                    .fill(quota.isSpent ? DeikoStyle.needsYou : DeikoStyle.accent)
                                    .frame(width: bar.size.width * min(max(quota.usedFraction, 0), 1))
                            }
                        }
                        .frame(height: 6)
                        .accessibilityElement()
                        .accessibilityLabel("Transcription minutes used")
                        .accessibilityValue(quota.usedSentence)
                        Text(quota.isPro
                            ? "\(quota.usedSentence) · \(License.Quota.proResetSentence)"
                            : "\(quota.usedSentence) · one-time trial, then this Mac transcribes")
                            .font(.system(size: 11))
                            .foregroundStyle(DeikoStyle.ink2)
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
                        // Return in this field applies THIS field. Pasting a
                        // key and pressing Return is the whole interaction.
                        .onSubmit { Task { await model.saveLicense() } }
                    // A licence is meant to live on more than one Mac — the
                    // hours are per licence — and it gets to the next one by
                    // being copied off this one. The STORED key, not the
                    // field's draft: what goes on the clipboard is what the
                    // relay is actually being sent.
                    if let key = License.key {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .deikoFocusRingLoose()
                        .foregroundStyle(DeikoStyle.ink2)
                        .tip("Copy the key — to put it on another Mac")
                    }
                }

                HStack {
                    Text("No account, no password. The key is the whole thing.")
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                    Spacer()
                    Button("Apply") { Task { await model.saveLicense() } }
                        .disabled(model.checking)
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
                            .foregroundStyle(DeikoStyle.ink2)
                    }
                    Spacer()
                    if License.key != nil {
                        Button("Remove key from this Mac") {
                            model.licenseKey = ""
                            Task { await model.saveLicense() }
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(DeikoStyle.ink2)
                        .tip("Forgets the key and its cached plan. Nothing is cancelled — "
                            + "your subscription is between you and Polar.")
                    }
                }
            }
            .padding(14)
        }
    }

    /// Which language the brief is written in, and which recogniser runs when
    /// the cloud is not involved. Two pickers because they answer different
    /// questions: the first is about the brief, the second about this Mac.
    private var language: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Brief language")
                        .font(.system(size: 13))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.narration },
                        set: { model.setNarration($0) }
                    )) {
                        ForEach(Narration.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Spacer()
                }
                Text(model.narration == .english
                    ? "Whatever you speak, the brief is written in English — the language your agent works in. Mixing languages in one sentence is fine."
                    : "The brief is written in the language you spoke, with Whisper's own word timing. Agents read Chinese, Japanese, Spanish and the rest just fine.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 10) {
                    Text("Offline recogniser")
                        .font(.system(size: 13))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.speechLocale },
                        set: { model.setSpeechLocale($0) }
                    )) {
                        ForEach(model.onDeviceLocales, id: \.self) { id in
                            Text(SpeechLocale.name(id)).tag(id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Spacer()
                }
                Text("Apple's on-device recogniser for this language runs when the cloud is not used — after the free minutes, or offline. Only languages this Mac can recognise without the network are listed; nothing is ever sent to Apple.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private var keys: some View {
        InsetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.whereAudioGoes)
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                keyRow(label: "Groq", tag: model.tag(for: "GROQ_API_KEY"),
                       text: $model.groqKey,
                       touched: $model.groqTouched,
                       prompt: model.groqStored ? model.placeholder(stored: true) : "gsk_…",
                       onSubmit: { model.saveKeys() })
                HStack {
                    // No longer a warning. A missing key used to mean briefs
                    // stopped at "Transcribing…"; now it means somebody else
                    // transcribes, which the sentence above already explains.
                    Text(model.keySources)
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                    Spacer()
                    // NOT `.defaultAction`. It was the only one in the pane,
                    // so Return anywhere in Settings — including in the licence
                    // field two cards up — saved transcription keys and left
                    // the licence unapplied, silently. Each field submits
                    // itself now (see `keyRow` and the licence row).
                    Button("Save") { model.saveKeys() }
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    /// The version, and one button that makes a bug report answerable.
    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Deiko \(DeikoVersion.current) (\(DeikoVersion.build))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DeikoStyle.ink2)
                    .textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy diagnostics") {
                    Diagnostics.copyToPasteboard()
                    copied = true
                    // Long enough to notice, short enough that the button is not
                    // stuck reading "Copied" the next time somebody needs it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .tip("Version, permissions and where the log is — no session content.")
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

            HStack(spacing: 10) {
                Text("Matching uses EmbeddingGemma by Google, under the Gemma Terms of Use.")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                Spacer()
                Button("Licences") {
                    if let folder = MeaningModel.licencesFolder() { NSWorkspace.shared.open(folder) }
                }
                .disabled(MeaningModel.licencesFolder() == nil)
                .tip("The licences of the model and the libraries Deiko runs it with.")
            }
        }
    }

    private func keyRow(
        label: String, tag: String, text: Binding<String>,
        touched: Binding<Bool>, prompt: String,
        onSubmit: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 10) {
            (Text(label).font(.system(size: 13))
                + Text("  \(tag)").font(.system(size: 11)).foregroundStyle(DeikoStyle.ink2))
                .frame(width: 96, alignment: .leading)
            SecureField(prompt, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: text.wrappedValue) { touched.wrappedValue = true }
                .onSubmit { onSubmit() }
        }
    }
}

// ── Shared pieces (Settings + first run share this vocabulary) ──────────────

/// The heading over a group of rows.
///
/// It used to be an 11pt tracked uppercase label, borrowed from System
/// Settings. It is a sentence-case title now: uppercase-tracked labels are
/// harder to read, macOS itself has been leaving them behind, and every
/// heading on the site is set this way. Same job, said at a normal volume.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // More room above than below: the heading belongs to what follows it.
        Text(text).deikoTitle(15).padding(.top, 8)
    }
}

/// A card holding rows — the grouping surface every window is built from.
/// Paper on a desk: solid, hairlined, with one long indigo-tinted shadow.
struct InsetCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .deikoCard()
    }
}

/// The primary action — ink, not the system accent.
///
/// The accent is spent on the GESTURE (the coin, the mark, a selected row);
/// spending it on buttons too would make "Deiko is pointing at something" and
/// "this is a button" the same colour. In dark mode ink inverts to the accent,
/// because near-black on near-black is a button nobody can find.
struct InkButtonStyle: ButtonStyle {
    // Named `Label`, not `Body`: `Body` is the protocol's own associated type,
    // and a nested struct by that name satisfies it instead — the conformance
    // then fails on a private type it never meant to name.
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }

    private struct Label: View {
        let configuration: Configuration
        // Read here rather than on the style: a ButtonStyle is not a View, so
        // this is the only place the environment actually resolves — and a
        // disabled primary that looks enabled is the bug that ships otherwise.
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? DeikoStyle.buttonInkText : DeikoStyle.ink2)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                // DISABLED IS ITS OWN PAIR, NOT AN OPACITY MULTIPLIER. At 35%
                // the label measured 1.37:1 against its own fill — the worst
                // contrast in the app, on the button a first run stares at
                // while it waits for permissions.
                .background(
                    RoundedRectangle(cornerRadius: DeikoStyle.controlRadius)
                        .fill(enabled ? DeikoStyle.buttonInk : DeikoStyle.hairline)
                )
                .opacity(configuration.isPressed && enabled ? 0.82 : 1)
        }
    }
}
