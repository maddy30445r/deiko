import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// THE REVIEW WINDOW — the brief in short, before it goes anywhere
//
// What is on screen is deliberately small: the counts, the repo it targets, how
// many screenshots are going and how many were withheld, and the narration.
// The brief itself runs to a thousand lines of evidence; none of that is here,
// because none of it is a decision.
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
// Nothing leaves the machine until Good to go is pressed. That property is the
// reason the tool is trustworthy and it is not negotiable — a brief that
// injected itself into your editor the moment you stopped talking is a brief you
// would stop trusting.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model = ReviewModel()

    /// Open for a session that has just closed, and run the pipeline behind it.
    func present(sessionDir: String) {
        show()
        model.load(sessionDir: sessionDir)
    }

    private func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ReviewView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fovea — review"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 640))
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // A menu-bar app is an accessory: without this the window opens behind
        // whatever the developer was looking at, which for a window that appears
        // by itself is indistinguishable from not opening at all.
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelPendingWork()
    }
}

// ── State ───────────────────────────────────────────────────────────────────

@MainActor
final class ReviewModel: ObservableObject {

    enum Phase: Equatable {
        case working(String)
        case ready
        case sent
        case failed(String)
    }

    @Published var phase: Phase = .working("Starting…")
    @Published var digest: BriefDigest?
    @Published var narration: String = ""

    /// Fovea's reading of the session, for this screen only — never sent.
    /// Nil while it is still arriving AND when it never arrives; `summaryPending`
    /// tells those apart, because a spinner that never resolves is worse than no
    /// spinner at all.
    @Published var summary: String?
    @Published var summaryPending = false

    private var sessionDir: String?
    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    /// The narration as recognised, so "did the developer change it" is a
    /// comparison rather than a flag that has to be maintained.
    private var originalNarration = ""

    var narrationEdited: Bool {
        narration.trimmingCharacters(in: .whitespacesAndNewlines)
            != originalNarration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load(sessionDir: String) {
        self.sessionDir = sessionDir
        phase = .working("Transcribing…")
        task = Task {
            do {
                let digest = try await BriefPipeline.run(sessionDir: sessionDir)
                guard !Task.isCancelled else { return }
                self.digest = digest
                self.narration = digest.summary.narration
                self.originalNarration = digest.summary.narration
                self.phase = .ready
                self.fetchSummary(sessionDir: sessionDir)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Save the edit, re-render, then send. In that order, and only that order:
    /// sending a brief whose narration section predates the correction would
    /// hand over the text the developer just rejected.
    func approve() {
        guard let sessionDir else { return }
        task = Task {
            do {
                if narrationEdited {
                    phase = .working("Applying your correction…")
                    try BriefPipeline.writeNarrationOverride(narration, sessionDir: sessionDir)
                    self.digest = try await BriefPipeline.rerender(sessionDir: sessionDir)
                }
                phase = .working("Sending…")
                try await BriefPipeline.send(sessionDir: sessionDir)
                guard !Task.isCancelled else { return }
                phase = .sent
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs alongside the visible brief, never in front of it. Its own task, so
    /// cancelling the window does not have to wait on a network call, and so a
    /// slow round trip cannot delay Good to go.
    private func fetchSummary(sessionDir: String) {
        summaryPending = true
        summaryTask = Task {
            let text = await BriefPipeline.summary(sessionDir: sessionDir)
            guard !Task.isCancelled else { return }
            self.summary = text
            self.summaryPending = false
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

private struct ReviewView: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .working(let what) where model.digest == nil:
                progress(what)
            case .failed(let message) where model.digest == nil:
                failure(message)
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

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Could not prepare the brief", systemImage: "exclamationmark.triangle")
                .font(.headline)
            // The whole output, scrollable and selectable. A truncated shell
            // error is a bug report nobody can act on.
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Try again") { model.retry() }
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
                Label("Sent — run /mcp__fovea__brief in your repo", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .ready:
                Text("Nothing has been sent yet.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
