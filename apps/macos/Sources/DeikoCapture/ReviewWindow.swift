import AppKit
import DeikoHandoff
import SwiftUI
import DeikoGesture

// ─────────────────────────────────────────────────────────────────────────────
// THE REVIEW — the brief in short, before it goes anywhere
//
// What is on screen is deliberately small: the counts, the repo it targets, how
// many screenshots are going and how many were withheld, and the narration.
// The brief itself runs to a thousand lines of evidence; none of that is here,
// because none of it is a decision.
//
// Presented by the orb (`Orb.swift`): `ReviewView` is the orb's expanded form,
// and `ReviewModel` is the one model both forms share — which is why collapsing
// the panel loses nothing.
//
// THE NARRATION IS THE SUMMARY. Nothing writes a description of the session,
// and nothing should — the developer already said what the task was, out loud,
// while pointing at it. What they said is the context. `BUILD_PLAN.md` T3.1
// specified a screen of plan steps with confidence flags; there are no plan
// steps, because Deiko deliberately stopped generating them, so that spec
// describes a screen for data that does not exist.
//
// The one thing that IS editable is that narration, and it earns its place: the
// text comes from speech recognition, it is the first thing the coding agent
// reads, and a mis-heard identifier there does more damage than anywhere else in
// the document. Correcting it by hand is `T2.4` done properly.
//
// Nothing leaves the machine until the developer flings the orb or presses
// Good to go. That property is the reason the tool is trustworthy and it is not
// negotiable — a brief that injected itself into your editor the moment you
// stopped talking is a brief you would stop trusting.
// ─────────────────────────────────────────────────────────────────────────────

// ── State ───────────────────────────────────────────────────────────────────

@MainActor
final class ReviewModel: ObservableObject {

    enum Phase: Equatable {
        case working(String)
        case ready
        case sent
        /// A sentence naming the fix, plus the raw output behind it. The raw
        /// text used to BE the message — four hundred characters of provider
        /// JSON, or a stack trace telling the user to edit a file inside the
        /// app bundle.
        case failed(PipelineFailure)
    }

    @Published var phase: Phase = .working("Starting…")
    @Published var digest: BriefDigest?
    @Published var narration: String = ""

    /// Write this brief up as a different persona, and re-render it now.
    /// The pointer beside the session is what the renderer reads, so this is
    /// the whole change — and it lasts for this brief only.
    func setPersona(_ persona: Persona) {
        guard let sessionDir else { return }
        Personas.point(session: sessionDir, to: persona)
        personaName = persona.name
        task?.cancel()
        task = Task {
            do {
                let rerendered = try await BriefPipeline.rerender(sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                digest = rerendered
            } catch {
                guard stillCurrent(sessionDir) else { return }
                // The brief on disk is still the last good one; say so rather
                // than leaving the window claiming a persona it did not apply.
                personaName = Personas.name(forSession: sessionDir)
            }
        }
    }

    /// The persona this brief was written for, for the one line on the card
    /// that says so. Read when the digest lands, not in a view body: it is a
    /// file read, and the card re-renders on every keystroke of a correction.
    /// Not `private(set)`: `UIShot` poses this card to check that the chip
    /// still fits beside the title at 400pt, and every other display value on
    /// this model is settable for the same reason.
    @Published var personaName: String?

    /// Crop thumbnails, keyed by the path in `digest.cropPaths`, loaded once
    /// here rather than in the view body.
    ///
    /// `narration` is `@Published` and bound to the TextEditor below, so every
    /// keystroke while correcting the transcript republishes this object and
    /// re-evaluates `ReviewView.body` — including `cropRow`. If the thumbnail
    /// read `NSImage(contentsOfFile:)` itself, that synchronous disk read and
    /// PNG decode would run again on every keystroke, for every crop on
    /// screen. Loading once when the digest arrives — and only then — keeps
    /// typing free of disk I/O it has no reason to pay for.
    ///
    /// That fixed the FREQUENCY, not the cost of any one decode. These are
    /// full-resolution Retina screenshots of whatever the lasso enclosed, so
    /// a large region is a multi-megabyte PNG, and the first version still
    /// ran `NSImage(contentsOfFile:)` for every path right here on the main
    /// actor — once instead of once-per-keystroke, but still synchronously,
    /// still capable of hitching the review card at the exact moment `phase`
    /// flips to `.ready` and it first appears. `loadCropThumbnails` below is
    /// `async`, and the actual read-and-decode (`decodeThumbnails`) is
    /// `nonisolated`: awaiting a `nonisolated` function from this
    /// `@MainActor` class hops execution off the main actor for its body and
    /// back only when it returns, so the disk read and PNG decode happen off
    /// the main thread and only the finished `NSImage` values ever cross back
    /// to be published here.
    @Published private(set) var cropThumbnails: [String: NSImage] = [:]

    /// Reads and decodes every crop, off the main actor — see the comment on
    /// `cropThumbnails` for why this is `async`/`nonisolated` rather than a
    /// plain synchronous call.
    ///
    /// `stillCurrent` is checked again after the `await`, exactly as it is
    /// after every other suspension point in this file: the decode is now a
    /// real await, so a session switch (or a second edit re-rendering the
    /// same session) can land while it is in flight, and a slow decode for a
    /// session nobody is looking at anymore must not overwrite a newer one's
    /// thumbnails once it finally finishes. This is the same guard used
    /// everywhere else here — not a second mechanism.
    private func loadCropThumbnails(_ digest: BriefDigest, sessionDir: String) async {
        let thumbnails = await decodeThumbnails(digest.cropPaths)
        guard stillCurrent(sessionDir) else { return }
        cropThumbnails = thumbnails
    }

    /// `nonisolated` so it carries no actor of its own: called with `await`
    /// from the `@MainActor` `loadCropThumbnails`, it runs the disk read and
    /// PNG decode on the cooperative thread pool rather than the main thread,
    /// and control returns to the main actor the moment it completes. No
    /// `Task.detached` and nothing to cancel separately — the enclosing
    /// `Task` in `load`/`approve`/`reload(afterExtending:)` already owns
    /// that, via `stillCurrent`.
    ///
    /// This off-main-thread hop is SE-0338's behaviour, not `nonisolated`'s
    /// universal meaning, and it only holds because `Package.swift` still
    /// declares `swift-tools-version:6.0`. SE-0461 (Swift 6.2) flips the
    /// default: under a 6.2-or-later tools-version, a `nonisolated async`
    /// function runs on the *caller's* actor instead of hopping off, so this
    /// exact code would silently decode back on the main actor — no compiler
    /// error, no test failure, just a hitch the first time a multi-megabyte
    /// Retina PNG decodes. Established empirically, by building a probe
    /// package at each tools-version, not from documentation. Do not raise
    /// the tools-version without re-proving this decode still leaves the main
    /// thread.
    nonisolated private func decodeThumbnails(_ cropPaths: [String]) async -> [String: NSImage] {
        Dictionary(uniqueKeysWithValues: cropPaths.compactMap { path in
            NSImage(contentsOfFile: path).map { (path, $0) }
        })
    }

    /// Who the brief was handed to, once it was — the sent pill names the app
    /// ("Handed to Claude Code") rather than claiming a vague success.
    @Published var handedTo: String?

    /// Deiko's reading of the session, for this screen only — never sent.
    /// Nil while it is still arriving AND when it never arrives; `summaryPending`
    /// tells those apart, because a spinner that never resolves is worse than no
    /// spinner at all.
    @Published var summary: String?
    @Published var summaryPending = false

    private var sessionDir: String?
    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?

    /// The session on screen, for the controller to hand back to the recorder.
    var currentSessionDir: String? { sessionDir }

    /// Open Settings — set by whoever owns that window. A failure whose fix is
    /// "add your key" should be one click from the key, not an instruction.
    var onOpenSettings: (() -> Void)?

    /// Leave one screenshot out of the brief.
    ///
    /// Writes the exclusion and re-renders, which is what makes it real: the
    /// renderer drops the whole referent, so neither the image nor the text
    /// read off it reaches `prompt.txt`. The thumbnails are shown to catch a
    /// bad crop and until now there was nothing to DO about one — the only
    /// remedy was abandoning the session.
    func excludeCrop(_ path: String) {
        guard let sessionDir, digest != nil else { return }
        let name = (path as NSString).lastPathComponent
        var names = BriefPipeline.cropExclusions(sessionDir: sessionDir)
        guard !names.contains(name) else { return }
        names.append(name)
        try? BriefPipeline.writeCropExclusions(names, sessionDir: sessionDir)
        rerenderPending = true
        approve()
    }

    /// Something other than the narration changed and the brief has to be built
    /// again. `approve()` re-rendered only for an edited narration, so without
    /// this an excluded crop was written to disk and never acted on.
    private var rerenderPending = false

    /// The recorder refused to reopen the session — the events file is gone, or
    /// another session is already live. Say so and leave the brief usable.
    func noteExtendFailed() {
        phase = .failed(PipelineFailure(
            kind: .unknown,
            message: "Could not reopen this session to add to it. The brief above is still fine to send.",
            opensSettings: false,
            raw: ""
        ))
    }
    /// The narration as recognised, so "did the developer change it" is a
    /// comparison rather than a flag that has to be maintained.
    private var originalNarration = ""

    var narrationEdited: Bool {
        narration.trimmingCharacters(in: .whitespacesAndNewlines)
            != originalNarration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a result that has just come back still belongs on screen.
    ///
    /// `Task.isCancelled` alone is not enough. It reports only the task's OWN
    /// cancellation, and every entry point here used to overwrite `task` without
    /// cancelling what was there — so a session that finished transcribing after
    /// a NEWER one had already loaded would happily publish its digest,
    /// narration and summary into a model now pointing somewhere else. The orb
    /// would show one session while the fling sent another, and `narrationEdited`
    /// would compare the new text against the old original, writing an edit
    /// nobody made. Cancelling on entry fixes the common case; this check is what
    /// makes it true even for a task already past its last suspension point.
    private func stillCurrent(_ dir: String) -> Bool {
        !Task.isCancelled && sessionDir == dir
    }

    /// Turn a thrown error into something worth reading.
    ///
    /// `commandFailed` carries the stage and the script's raw output, which is
    /// what the taxonomy classifies. Everything else already has a written
    /// message — `HandoffError` and the like — and passes through.
    private func describe(_ error: Error) -> PipelineFailure {
        let failure: PipelineFailure
        if case BriefPipelineError.commandFailed(let stage, let output) = error {
            failure = PipelineFailure.classify(stage: stage, output: output)
        } else {
            failure = PipelineFailure(
                kind: .unknown,
                message: error.localizedDescription,
                opensSettings: false,
                raw: ""
            )
        }
        // Remembered here because this is the only place a failure is ever
        // named. Settings' "Copy diagnostics" is usually pressed minutes
        // later, from a window that knows nothing about this session.
        Diagnostics.lastFailure = failure
        return failure
    }

    func load(sessionDir: String) {
        cancelPendingWork()
        self.sessionDir = sessionDir
        handedTo = nil
        phase = .working("Transcribing…")
        task = Task {
            do {
                let digest = try await BriefPipeline.run(sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                self.digest = digest
                self.personaName = Personas.name(forSession: sessionDir)
                await self.loadCropThumbnails(digest, sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                self.narration = digest.summary.narration
                self.originalNarration = digest.summary.narration
                self.phase = .ready
                self.fetchSummary(sessionDir: sessionDir)
                self.runQueuedHandoff()
            } catch {
                guard stillCurrent(sessionDir) else { return }
                self.phase = .failed(describe(error))
                // The throw was waiting on this render, and it is not coming.
                // Leaving the queue armed would hand the developer an error
                // while they believed their fling was still in flight.
                self.queuedHandoff = nil
            }
        }
    }

    /// A fling thrown before the brief existed.
    ///
    /// The orb appears the moment a session closes, but the pipeline needs a
    /// few seconds more — so whether reaching for the coin worked came down to
    /// how fast you reached. The gesture armed only on `.ready`, and an unarmed
    /// press produced no detached coin, no aim label, no highlight and no
    /// message: it simply died, differently on different days. That is the
    /// whole of "sometimes nothing happens".
    ///
    /// Throwing it IS the decision. Holding the throw until there is something
    /// to send honours it, rather than discarding it for being early.
    private var queuedHandoff: (appName: String?, deliver: @MainActor (BriefPipeline.Prompt) async throws -> Void)?

    private func runQueuedHandoff() {
        guard let queued = queuedHandoff else { return }
        queuedHandoff = nil
        Handoff.trace?("fling: brief ready — sending the throw that was waiting")
        approve(handingTo: queued.appName, then: queued.deliver)
    }

    /// Save the edit, re-render, then — only on the fling path — send.
    ///
    /// ONE SEND GESTURE IN THE WHOLE PRODUCT. Called with no handoff closure
    /// (the panel's "Good to go"), this applies the correction and returns to
    /// `.ready`: nothing leaves the machine until the coin is thrown. The
    /// panel never sends, so there is exactly one gesture that does, and the
    /// developer can always answer "has anything been sent?" by whether they
    /// have thrown.
    ///
    /// On the fling path the order is edit → read `prompt.txt` → keystroke, and
    /// **the phase does not read `.sent` until the keystroke returns.** The
    /// first version set `.sent` before running it — so the orb said "Handed
    /// over" while nothing had reached the editor, and the checkmark was
    /// evidence only of a file being on disk. A success state must not outrun
    /// the work it claims.
    ///
    /// `prompt.txt` is read fresh here rather than passed down from `load`,
    /// deliberately: if the paste or keystroke fails, the file is still there
    /// and the orb points at it — pasting it by hand still works.
    func approve(handingTo appName: String? = nil, then after: (@MainActor (BriefPipeline.Prompt) async throws -> Void)? = nil) {
        guard let sessionDir else { return }

        // THROWN BEFORE THERE WAS ANYTHING TO SEND — hold it, do not cancel.
        //
        // `digest == nil` is the test for "the pipeline is still producing the
        // brief", and it has to be checked before the `task?.cancel()` below:
        // that line exists to stop a stale send racing a newer one, but the
        // task in flight right now IS the render this fling is waiting for.
        // Cancelling it would answer an early throw by destroying the thing
        // that would have satisfied it.
        if digest == nil, let after {
            queuedHandoff = (appName: appName, deliver: after)
            phase = .working("Sending to \(appName ?? "your editor") when it's ready…")
            Handoff.trace?("fling: queued for \(appName ?? "an editor") — brief not rendered yet")
            return
        }

        task?.cancel()
        task = Task {
            do {
                if narrationEdited || rerenderPending {
                    phase = .working(narrationEdited
                        ? "Applying your correction…"
                        : "Leaving that screenshot out…")
                    if narrationEdited {
                        try BriefPipeline.writeNarrationOverride(narration, sessionDir: sessionDir)
                    }
                    let rerendered = try await BriefPipeline.rerender(sessionDir: sessionDir)
                    guard stillCurrent(sessionDir) else { return }
                    // CLEARED ONLY ONCE THE RE-RENDER HAS ACTUALLY LANDED.
                    //
                    // Clearing it before the `await` looked equivalent and was
                    // not: `approve` cancels the task in flight, so a coin
                    // thrown while this was still rendering started a second
                    // pass that saw `rerenderPending == false` and
                    // `narrationEdited == false`, skipped the re-render, and
                    // handed over the PRE-EXCLUSION `prompt.txt` — the removed
                    // screenshot's path, its caption, its screen text and its
                    // image bytes, all delivered after the user had taken it
                    // out. `narrationEdited` never had this bug because it is
                    // derived state rather than a flag; clearing here makes
                    // this one self-healing in the same way.
                    rerenderPending = false
                    self.digest = rerendered
                    self.personaName = Personas.name(forSession: sessionDir)
                    await self.loadCropThumbnails(rerendered, sessionDir: sessionDir)
                    guard stillCurrent(sessionDir) else { return }
                }
                guard let after else {
                    // The panel's path ends here: corrected, re-rendered,
                    // nothing sent.
                    phase = .ready
                    return
                }
                let prompt = try BriefPipeline.prompt(sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                phase = .working("Handing to \(appName ?? "your editor")…")
                try await after(prompt)
                guard stillCurrent(sessionDir) else { return }
                handedTo = appName
                phase = .sent
            } catch {
                guard stillCurrent(sessionDir) else { return }
                phase = .failed(describe(error))
            }
        }
    }

    /// Runs alongside the visible brief, never in front of it. Its own task, so
    /// cancelling the window does not have to wait on a network call, and so a
    /// slow round trip cannot delay Good to go.
    private func fetchSummary(sessionDir: String) {
        summaryTask?.cancel()
        summaryPending = true
        summaryTask = Task {
            let text = await BriefPipeline.summary(sessionDir: sessionDir)
            guard stillCurrent(sessionDir) else { return }
            self.summary = text
            self.summaryPending = false
        }
    }

    /// What the developer had in the narration box, and which holds already
    /// existed, at the moment they pressed "Forgot something?". Nil when no
    /// extension is in flight.
    private var carriedNarration: String?
    private var holdsBeforeExtending: Set<Int> = []

    /// Called just before the window hands control back to the recorder.
    func prepareToExtend() {
        guard let sessionDir else { return }
        // Only an ACTUAL edit is carried. Carrying the untouched transcript would
        // write it back as an override, and the brief would then tell the agent
        // "corrected by the developer after capture" about text they never
        // touched — a claim that reads as authority the words have not earned.
        carriedNarration = narrationEdited ? narration : nil
        holdsBeforeExtending = Set(BriefPipeline.holdTexts(sessionDir: sessionDir).keys)
        phase = .working("Recording — tap \(SessionKey.selected.name) to stop")
    }

    /// Re-run the pipeline over a session that just gained a hold, keeping
    /// whatever the developer had already written.
    ///
    /// Their text wins and the new speech is appended to it. Re-transcribing
    /// would be simpler and would silently destroy a correction they made
    /// deliberately — the worst kind of surprise, and the reason this bookkeeping
    /// exists at all.
    func reload(afterExtending sessionDir: String) {
        let carried = carriedNarration
        let priorHolds = holdsBeforeExtending
        carriedNarration = nil
        holdsBeforeExtending = []

        cancelPendingWork()
        self.sessionDir = sessionDir
        summary = nil
        phase = .working("Transcribing what you added…")
        task = Task {
            do {
                var digest = try await BriefPipeline.run(sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }

                // Everything said in a hold that did not exist before the button
                // was pressed, in hold order.
                let added = BriefPipeline.holdTexts(sessionDir: sessionDir)
                    .filter { !priorHolds.contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map(\.value)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let kept = (carried ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !kept.isEmpty, !added.isEmpty {
                    let merged = "\(kept) \(added)"
                    try BriefPipeline.writeNarrationOverride(merged, sessionDir: sessionDir)
                    digest = try await BriefPipeline.rerender(sessionDir: sessionDir)
                    guard stillCurrent(sessionDir) else { return }
                }

                self.digest = digest
                self.personaName = Personas.name(forSession: sessionDir)
                await self.loadCropThumbnails(digest, sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                self.narration = digest.summary.narration
                self.originalNarration = digest.summary.narration
                self.phase = .ready
                self.fetchSummary(sessionDir: sessionDir)
            } catch {
                guard stillCurrent(sessionDir) else { return }
                self.phase = .failed(describe(error))
            }
        }
    }

    func retry() {
        guard let sessionDir else { return }
        summary = nil
        load(sessionDir: sessionDir)
    }

    func cancelPendingWork() {
        task?.cancel()
        task = nil
        summaryTask?.cancel()
        summaryTask = nil
        // A held throw belongs to the session it was thrown at, and nothing
        // else. `load` calls this on entry, so without it a fling queued
        // against one session would fire the moment the NEXT session finished
        // rendering — pasting a brief the developer never aimed at, into a
        // window they aimed at minutes ago. The same class of bug `stillCurrent`
        // exists to prevent, arriving by a route that predates it.
        queuedHandoff = nil
    }
}

// ── View ────────────────────────────────────────────────────────────────────

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    /// Which thumbnail the cursor is over, so only that one shows its ×.
    @State private var hoveredCrop: String?
    /// Reopening the session is the orb controller's job — it owns the window
    /// that has to get out of the way, and the recorder handoff.
    let onExtend: () -> Void
    /// "Good to go" returns to the collapsed orb — the panel corrects, the
    /// coin sends. Owned by the orb, which owns the window's shape.
    let onCollapse: () -> Void
    /// Delete the session outright. Owned by the orb, which owns the window
    /// that has to go away with it.
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .working(let what) where model.digest == nil:
                progress(what)
            case .failed(let problem) where model.digest == nil:
                failure(problem)
            default:
                brief
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DeikoStyle.paper)
    }

    // ── States ──────────────────────────────────────────────────────────────

    private func progress(_ what: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(what).foregroundStyle(DeikoStyle.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ failure: PipelineFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Could not prepare the brief", systemImage: "exclamationmark.triangle")
                .font(.headline)

            // The sentence first, in prose, at readable size. This used to be
            // the raw shell output in monospace — which for the commonest
            // failure told the user to edit a `.env` they do not have, from a
            // shell they are not in.
            Text(failure.message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if failure.opensSettings {
                    Button("Open Settings") { model.onOpenSettings?() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Try again") { model.retry() }
                // Here, because here is where somebody is when they decide to
                // ask for help. It used to live only in Settings, two windows
                // away, and the block it copied did not name the failure they
                // were looking at — `Diagnostics.lastFailure` fixes the second
                // half of that.
                Button("Copy diagnostics") { Diagnostics.copyToPasteboard() }
                Spacer()
            }

            // Kept, not discarded — it is the only thing worth having in a bug
            // report — but folded away, because it is not what the person in
            // front of it needs to read.
            if !failure.raw.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(failure.raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption)
            }
        }
        .padding(20)
    }

    /// Scrollable evidence, pinned decision.
    ///
    /// The footer sits OUTSIDE the scroll deliberately: this panel used to grow
    /// with its content and push "Point at more" and "Good to go" off the
    /// bottom of the display — two buttons that existed and could not be
    /// clicked. Whatever the narration's length, the two things you can do
    /// about it stay on screen.
    private var brief: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    summaryCard
                    narrationEditor
                }
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
    }

    /// Deiko's reading of the session — the only interpreted text anywhere in
    /// the product, and it stops at this window.
    ///
    /// Read-only on purpose: it is never sent, so an editable box would invite
    /// corrections that go nowhere. The narration below is the field that
    /// travels, and the one worth correcting. The "for you, not sent" pill is
    /// outlined at full label contrast — a privacy claim must not read like a
    /// watermark.
    ///
    /// Absent entirely when there is no summary. A card reading "no summary
    /// available" would take up the same room as the summary while telling the
    /// developer less than silence does.
    @ViewBuilder private var summaryCard: some View {
        if model.summaryPending || model.summary != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    HStack(spacing: 6) {
                        SectionLabel("Deiko's reading")
                            .foregroundStyle(DeikoStyle.mark)
                        if model.summaryPending {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Spacer()
                    Text("for you, not sent")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                }

                if let summary = model.summary {
                    Text(summary)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                    .fill(DeikoStyle.accent.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                            .strokeBorder(DeikoStyle.accent.opacity(0.22), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let d = model.digest {
                headline(d)
                bindingLine(d)
                cropRow(d)
                degradedRow(d)
                trustRow(d)
                repoRow(d)
                personaRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// How this brief will be written up, and the one place to change it for
    /// this brief alone. A menu rather than a segmented control: there are
    /// four personas today and no ceiling on how many somebody makes.
    @ViewBuilder private var personaRow: some View {
        if let current = model.personaName {
            HStack(spacing: 6) {
                Text("Written up as")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                Menu {
                    ForEach(Personas.all()) { persona in
                        Button {
                            guard persona.name != current else { return }
                            model.setPersona(persona)
                        } label: {
                            // A checkmark, because this is a choice with a
                            // current answer, not a list of commands.
                            Text(persona.name == current ? "✓ \(persona.name)" : "   \(persona.name)")
                        }
                    }
                } label: {
                    Text(current)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DeikoStyle.mark)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Write this brief up as a different persona. Only this one — your default does not change.")
            }
            .padding(.top, 1)
        }
    }

    /// `43s · 6 things pointed at · Code` — the app name in mono, because it
    /// is data.
    private func headline(_ d: BriefDigest) -> some View {
        let seconds = Int((d.summary.durationMs / 1000).rounded())
        let apps = d.summary.apps.isEmpty ? "no app" : d.summary.apps.joined(separator: ", ")
        return (
            Text("\(seconds)s · \(d.summary.referentCount) things pointed at · ")
                .font(.system(size: 15, weight: .semibold))
            + Text(apps)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        )
    }

    private func bindingLine(_ d: BriefDigest) -> some View {
        var line = Text("\(d.summary.boundCount) of \(d.summary.referentCount) bound to what you said")
            .foregroundStyle(DeikoStyle.ink2)
        // Surfaced because it is the one number that says "check this" — the
        // aligner had two equally plausible referents and picked one.
        if d.summary.needsReviewCount > 0 {
            line = line
                + Text(" · ").foregroundStyle(DeikoStyle.ink2)
                + Text("\(d.summary.needsReviewCount) worth checking")
                .foregroundStyle(DeikoStyle.needsYou)
        }
        return line.font(.system(size: 13))
    }

    /// The withheld line NEVER collapses into the stats — its own orange row,
    /// even mid-flow. Watching Deiko refuse to share a credential is the
    /// privacy model, visible.
    ///
    /// The released ones are SHOWN, not counted. A miscropped screenshot used
    /// to surface ten minutes later as an agent reasoning about the wrong
    /// window; here it is visible in the second before Good to go.
    /// One quiet line when the words came from this Mac rather than the cloud.
    ///
    /// The fallback itself is correct and deliberate — a spent trial or an
    /// unreachable relay keeps the session working instead of failing it. But
    /// it was entirely silent, so the only thing the developer saw was a
    /// transcript that read worse than usual, and the only thing that reached
    /// the inbox was "the transcription is bad". Secondary styling on purpose:
    /// this is an explanation, not a problem to solve.
    /// The sentence for one degradation reason. The wording lives in
    /// `SessionClaims` (DeikoHandoff) so it can be tested; the reset date is
    /// supplied from here, where the calendar is.
    ///
    /// `static` so the collapsed orb card shows the same sentence as the
    /// expanded panel — two spellings would drift the first time one was
    /// reworded.
    static func degradedSentence(_ reason: String?, degraded: Bool) -> String? {
        SessionClaims.degradedSentence(
            reason, degraded: degraded, resetSentence: License.Quota.proResetSentence
        )
    }

    /// One quiet line when the transcript is not what a clean session produces.
    ///
    /// The fallback itself is correct and deliberate — a spent trial or an
    /// unreachable relay keeps the session working instead of failing it. But
    /// it was entirely silent, so the only thing the developer saw was a
    /// transcript that read worse than usual, and the only thing that reached
    /// the inbox was "the transcription is bad". Secondary styling on purpose:
    /// this is an explanation, not a problem to solve — except for `trial`,
    /// which is the one with something to do about it.
    @ViewBuilder private func degradedRow(_ d: BriefDigest) -> some View {
        if let sentence = Self.degradedSentence(
            d.summary.degradedReason, degraded: d.summary.degraded == true
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(sentence, systemImage: "waveform.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                // Only where there is somewhere to send them. A build with no
                // checkout URL stamped must not grow a button that 404s.
                if d.summary.degradedReason == "trial", let buy = Credentials.buyURL {
                    Button("Get Pro") { NSWorkspace.shared.open(buy) }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.link)
                }
                // A rejected key is fixed in Settings, and nowhere else.
                if d.summary.degradedReason == "rejected" {
                    Button("Open Settings") { model.onOpenSettings?() }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.link)
                }
            }
        }
    }

    /// The one line that answers "did anything leave?" without reading source.
    private func trustRow(_ d: BriefDigest) -> some View {
        Label(
            Self.trustLine(
                d,
                hasSummary: model.summary != nil,
                ownGroqKey: Credentials.willUse("GROQ_API_KEY")
            ),
            systemImage: "arrow.up.forward.square"
        )
        .font(.system(size: 11))
        .foregroundStyle(DeikoStyle.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What left this Mac, for this session. The claim itself lives in
    /// `SessionClaims` (DeikoHandoff), which is testable; this only supplies
    /// the digest's fields.
    static func trustLine(_ d: BriefDigest, hasSummary: Bool, ownGroqKey: Bool) -> String {
        SessionClaims.trustLine(
            transcriber: d.summary.transcriber,
            degradedReason: d.summary.degradedReason,
            seconds: Int((d.summary.durationMs / 1000).rounded()),
            uploadedChunks: d.summary.uploadedChunks,
            hasSummary: hasSummary,
            ownGroqKey: ownGroqKey
        )
    }

    /// WHY the screenshots were held back, in their own words.
    ///
    /// `render-brief.mjs` withholds for two different reasons and only one of
    /// them is about a credential. The other — "never OCR'd, contents
    /// unverified" — is what happens when Screen Recording has been granted
    /// but Deiko has not been relaunched, which is to say on somebody's FIRST
    /// SESSION. Saying "a credential was visible" there is a false alarm about
    /// the user's own screen, raised in the one surface the entire privacy
    /// promise rests on, at the worst possible moment to be wrong.
    ///
    /// So the unverified case says what actually happened and names the fix,
    /// and the mixed case does not pretend to a single explanation.
    static func withheldSentence(_ d: BriefDigest) -> String {
        let n = d.cropsWithheld
        let noun = "\(n) screenshot\(n == 1 ? "" : "s")"
        let credential = d.withheldReasons.contains { $0.contains("credential") }
        let unverified = d.withheldReasons.contains { $0.contains("OCR") }

        if credential && !unverified {
            return "\(noun) withheld — a credential was visible. "
        }
        if unverified && !credential {
            return "\(noun) withheld — Deiko couldn't read \(n == 1 ? "it" : "them") to check. "
                + "Relaunch Deiko and they'll be included next time. "
        }
        return "\(noun) withheld — some held a credential, some couldn't be read to check. "
    }

    @ViewBuilder private func cropRow(_ d: BriefDigest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if d.cropsWithheld > 0 {
                HStack(spacing: 8) {
                    Text("!")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DeikoStyle.needsYou)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(DeikoStyle.needsYou, lineWidth: 1.5))
                    (
                        Text(Self.withheldSentence(d))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DeikoStyle.needsYou)
                        + Text("\(d.cropsReleased) \(d.cropsReleased == 1 ? "is" : "are") going.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DeikoStyle.ink2)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DeikoStyle.needsYou.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Label(
                    d.cropsReleased == 1 ? "1 screenshot going" : "\(d.cropsReleased) screenshots going",
                    systemImage: "photo.on.rectangle"
                )
                .font(.system(size: 13))
                .foregroundStyle(DeikoStyle.ink2)
            }

            if !d.cropPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(d.cropPaths, id: \.self) { path in
                            thumbnail(path)
                        }
                    }
                    // Room for the × to sit proud of the top-right corner
                    // without the scroll view clipping it.
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .frame(height: 78)
            }

            // What the developer took out themselves. Counted rather than
            // silent: a brief that ships fewer screenshots than the session
            // captured should say so, even when the removal was deliberate —
            // it is the same courtesy the withheld line pays.
            if let removed = d.summary.cropsRemoved, removed > 0 {
                Text(removed == 1
                    ? "1 screenshot left out by you"
                    : "\(removed) screenshots left out by you")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
            }

            // Labels lost to a correction. Placed HERE, beside the screenshots
            // it is about, rather than in the footer: the footer tracks live
            // edit state and this number comes from the last render, so the two
            // would contradict each other while somebody is still typing.
            if let dropped = d.summary.labelsDropped, dropped > 0 {
                Text(dropped == 1
                    ? "1 screenshot lost its caption — the sentence it quoted changed."
                    : "\(dropped) screenshots lost their captions — the sentences they quoted changed.")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    /// One crop, at a size you can recognise a window in without it dominating
    /// the card. `contentMode: .fit` so a wide lasso and a tall one are both
    /// shown whole — cropping the preview would hide exactly the mistake this
    /// exists to catch.
    ///
    /// Read from `model.cropThumbnails`, not the disk — see that cache's own
    /// comment for why.
    @ViewBuilder private func thumbnail(_ path: String) -> some View {
        if let image = model.cropThumbnails[path] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailWidth(image.size), height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DeikoStyle.accent.opacity(0.25), lineWidth: 1)
                )
                // LEAVE THIS ONE OUT.
                //
                // These thumbnails exist to catch a crop that grabbed the wrong
                // thing — and until now spotting one had no remedy short of
                // abandoning the session. Redaction only knows credential
                // SHAPES, so a customer's name, an open DM or an unrelated
                // window all sail through it; this is the control for
                // everything the automatic rule cannot be expected to judge.
                //
                // On hover rather than always: five permanent × badges over
                // five thumbnails reads as a row of errors.
                .overlay(alignment: .topTrailing) {
                    if hoveredCrop == path {
                        Button { model.excludeCrop(path) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DeikoStyle.needsYou)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Leave this screenshot out of the brief")
                    }
                }
                .onHover { inside in hoveredCrop = inside ? path : nil }
                .disabled(!isApprovable)
        } else {
            // The session directory belongs to the user, not to Deiko — it can
            // be moved or deleted between capture and reopening this card. A
            // path `cropPaths` promised and can no longer deliver must not just
            // vanish from the row: the header line still says how many are
            // going, and a row one thumbnail short of that count reads as "the
            // rest loaded fine" rather than "one is unaccounted for."
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DeikoStyle.accent.opacity(0.25), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.6))
                )
                .frame(width: 68, height: 68)
        }
    }

    /// A crop is a screenshot of whatever the lasso enclosed, so its aspect
    /// ratio is whatever the developer drew: one line of code is wide and
    /// short, a sidebar is tall and narrow. `.fit` against a bare
    /// `height: 68` follows that ratio all the way down — a narrow-enough
    /// crop would render at a handful of points wide, a sliver with no
    /// visible border. Flooring the width keeps every thumbnail a legible box
    /// even when the image inside it is thin; wide crops are left uncapped,
    /// since the row already scrolls horizontally for them.
    private func thumbnailWidth(_ size: NSSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 68 }
        return max(68 * size.width / size.height, 36)
    }

    @ViewBuilder private func repoRow(_ d: BriefDigest) -> some View {
        if let repo = d.summary.repoHints.first {
            HStack(spacing: 8) {
                Text("Targets \(repo)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(DeikoStyle.accent.opacity(0.12), in: Capsule())
                Text("from the windows you pointed at")
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            .padding(.top, 3)
        } else {
            // Worth its own colour and outline: a brief with no repo signal is
            // the one most likely to land in the wrong project.
            Text("No repo named — confirm where this belongs")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DeikoStyle.needsYou)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(DeikoStyle.needsYou.opacity(0.6), lineWidth: 1.5))
                .padding(.top, 3)
        }
    }

    private var narrationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("What you said")
                Spacer()
                if model.narrationEdited {
                    Text("edited")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DeikoStyle.ink2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            TextEditor(text: $model.narration)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
            Text("This is the task, in your words — the one thing here you can edit. Fix anything it misheard.")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var footer: some View {
        HStack {
            switch model.phase {
            case .working(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.system(size: 12)).foregroundStyle(DeikoStyle.ink2)
            case .sent:
                Label(model.handedTo.map { "Handed to \($0)" } ?? "Handed over", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.sentGreen)
            case .failed(let problem):
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.needsYou)
                    .lineLimit(2)
            case .ready:
                // The trust line, and now also the model: the panel corrects,
                // the coin sends. There is no send button on this screen.
                //
                // It used to read "Everything else goes as captured." the
                // moment the narration was touched — which was false: an edit
                // dropped every screenshot caption. The captions now survive
                // unless their own sentence changed, and how many did not is
                // reported beside the thumbnails, so this line can go back to
                // saying the one thing that is always true here.
                Text("Nothing is sent until you throw the coin.")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            Spacer()
            // Furthest from the primary action, because it is the destructive
            // one — and here at all because the review panel is where somebody
            // discovers the session caught something it should not have. The
            // `×` only hides the orb; this is the only way to remove the
            // screenshots.
            Button("Delete session…", role: .destructive) { onDelete() }
                .disabled(!isApprovable)
                .help("Remove this session's brief and screenshots from disk.")
            // Left of the primary action and unstyled, because it is the rarer
            // choice — but it must be reachable from the same place you decide
            // the brief is not complete.
            Button("Point at more") { onExtend() }
                .disabled(!isApprovable)
                .help("Reopen this session and record more — talk and point again, then tap \(SessionKey.selected.name) to stop.")
            Button("Good to go") {
                model.approve()
                onCollapse()
            }
            .keyboardShortcut(.defaultAction)
            .tint(DeikoStyle.accent)
            .disabled(!isApprovable)
            .help("Apply your correction and return to the coin. Nothing is sent until you throw it.")
        }
        .padding(20)
    }

    private var isApprovable: Bool {
        switch model.phase {
        case .ready, .failed: return model.digest != nil
        case .working, .sent: return false
        }
    }
}
