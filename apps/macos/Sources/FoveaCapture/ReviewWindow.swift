import AppKit
import FoveaHandoff
import SwiftUI

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
// steps, because Fovea deliberately stopped generating them, so that spec
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

    /// Who the brief was handed to, once it was — the sent pill names the app
    /// ("Handed to Claude Code") rather than claiming a vague success.
    @Published var handedTo: String?

    /// Fovea's reading of the session, for this screen only — never sent.
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
    /// message — `HandoffError`, `ConnectorError` — and passes through.
    private func describe(_ error: Error) -> PipelineFailure {
        if case BriefPipelineError.commandFailed(let stage, let output) = error {
            return PipelineFailure.classify(stage: stage, output: output)
        }
        return PipelineFailure(
            kind: .unknown,
            message: error.localizedDescription,
            opensSettings: false,
            raw: ""
        )
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

    /// Save the edit, re-render, then send. In that order, and only that order:
    /// sending a brief whose narration section predates the correction would
    /// hand over the text the developer just rejected.
    ///
    /// `then` runs after the brief is in the outbox, and **the phase does not
    /// read `.sent` until it returns.** The orb hangs the handoff keystroke
    /// there, and the first version of this set `.sent` before running it — so
    /// the orb said "Handed over" while nothing had reached the editor, and the
    /// checkmark was evidence only of a file copy. A success state must not
    /// outrun the work it claims.
    ///
    /// The copy still happens first, deliberately: if the handoff half fails,
    /// the brief is already pending and typing the command by hand still works.
    func approve(handingTo appName: String? = nil, then after: (@MainActor () async throws -> Void)? = nil) {
        guard let sessionDir else { return }
        task?.cancel()
        task = Task {
            do {
                if narrationEdited {
                    phase = .working("Applying your correction…")
                    try BriefPipeline.writeNarrationOverride(narration, sessionDir: sessionDir)
                    let rerendered = try await BriefPipeline.rerender(sessionDir: sessionDir)
                    guard stillCurrent(sessionDir) else { return }
                    self.digest = rerendered
                }
                phase = .working("Sending…")
                try await BriefPipeline.send(sessionDir: sessionDir)
                guard stillCurrent(sessionDir) else { return }
                if let after {
                    phase = .working("Handing to \(appName ?? "your editor")…")
                    try await after()
                    guard stillCurrent(sessionDir) else { return }
                }
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
        phase = .working("Recording — tap Right Option to stop")
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
    }
}

// ── View ────────────────────────────────────────────────────────────────────

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    /// Reopening the session is the orb controller's job — it owns the window
    /// that has to get out of the way, and the recorder handoff.
    let onExtend: () -> Void

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
    }

    // ── States ──────────────────────────────────────────────────────────────

    private func progress(_ what: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(what).foregroundStyle(.secondary)
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

    private var brief: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryCard
            Divider()
            narrationEditor
            Divider()
            footer
        }
    }

    /// Fovea's reading of the session — the only interpreted text anywhere in
    /// the product, and it stops at this window.
    ///
    /// Read-only on purpose: it is never sent, so an editable box would invite
    /// corrections that go nowhere. The narration below is the field that
    /// travels, and the one worth correcting.
    ///
    /// Absent entirely when there is no summary. A card reading "no summary
    /// available" would take up the same room as the summary while telling the
    /// developer less than silence does.
    @ViewBuilder private var summaryCard: some View {
        if model.summaryPending || model.summary != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text("Fovea's reading — for you, not sent")
                    if model.summaryPending {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let summary = model.summary {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = model.digest {
                Text(headline(d)).font(.headline)
                Text(bindingLine(d)).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle")
                    Text(cropLine(d))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let repo = d.summary.repoHints.first {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                        Text("Targets \(repo)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    // Worth its own line and its own colour: a brief with no repo
                    // signal is the one most likely to land in the wrong project.
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                        Text("No repo named — confirm where this belongs")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var narrationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What you said").font(.headline)
                Spacer()
                if model.narrationEdited {
                    Text("edited").font(.caption).foregroundStyle(.orange)
                }
            }
            Text("This is the task, in your words. Fix anything it misheard.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.narration)
                .font(.system(.body, design: .default))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            switch model.phase {
            case .working(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.caption).foregroundStyle(.secondary)
            case .sent:
                Label("Sent — run /fovea:brief in your repo", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let problem):
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .ready:
                Text("Nothing has been sent yet.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Left of the primary action and unstyled, because it is the rarer
            // choice — but it must be reachable from the same place you decide
            // the brief is not complete.
            Button("Point at more") { onExtend() }
                .disabled(!isApprovable)
                .help("Reopen this session and record more — talk and point again, then tap Right Option to stop.")
            Button("Good to go") { model.approve() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isApprovable)
        }
        .padding(20)
    }

    private var isApprovable: Bool {
        switch model.phase {
        case .ready, .failed: return model.digest != nil
        case .working, .sent: return false
        }
    }

    // ── Wording ─────────────────────────────────────────────────────────────

    private func headline(_ d: BriefDigest) -> String {
        let seconds = Int((d.summary.durationMs / 1000).rounded())
        let apps = d.summary.apps.isEmpty ? "no app" : d.summary.apps.joined(separator: ", ")
        return "\(seconds)s · \(d.summary.referentCount) things pointed at · \(apps)"
    }

    private func bindingLine(_ d: BriefDigest) -> String {
        var line = "\(d.summary.boundCount) of \(d.summary.referentCount) bound to what you said"
        // Surfaced because it is the one number that says "check this" — the
        // aligner had two equally plausible referents and picked one.
        if d.summary.needsReviewCount > 0 {
            line += " · \(d.summary.needsReviewCount) worth checking"
        }
        return line
    }

    private func cropLine(_ d: BriefDigest) -> String {
        d.cropsWithheld > 0
            ? "\(d.cropsReleased) screenshots going, \(d.cropsWithheld) withheld (a credential was visible)"
            : "\(d.cropsReleased) screenshots going"
    }
}
