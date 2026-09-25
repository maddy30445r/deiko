import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE MEANING MODEL, FETCHED ONCE
//
// Filing blends word matching with an on-device embedding model (see
// scripts/lib/meaning.mjs). The model is ~226 MB, so the installer does not
// carry it: the app asks `scripts/meaning.mjs` to download it once, from
// Deiko's own storage, every file checked against a pinned SHA-256. Until it
// is ready, or if it never is, filing uses words alone — nothing waits on it.
// After the first download, old briefs get their vectors once (`backfill`).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class MeaningModel: ObservableObject {
    static let shared = MeaningModel()

    enum State: Equatable {
        case checking
        case downloading(done: Int64, total: Int64)
        case ready
        case failed(String)
        case off
    }

    @Published private(set) var state: State = .checking
    private var running = false
    /// The board this launch is recording to — `recorder.sessionRoot`, not
    /// necessarily `Sessions.defaultRoot` (`--out` can point elsewhere). Set
    /// by the first `start(root:)` call and reused afterwards, including by
    /// Settings' "Try again", which has no recorder of its own to ask.
    private var root: String?
    /// One retry per launch after a failed download — see `retryAfterFailure`.
    private var retriedAfterFailure = false

    func start(root: String? = nil) {
        if let root { self.root = root }
        guard !running else { return }
        running = true
        state = .checking
        Task { await run() }
    }

    private func run() async {
        defer { running = false }
        let status = await Self.lines(["status"]).last ?? ""
        if status == "off" { state = .off; return }
        var key = status.hasPrefix("ready ") ? String(status.dropFirst(6)) : nil
        if key == nil {
            state = .downloading(done: 0, total: 0)
            let last = await Self.lines(["download"]) { [weak self] line in
                let parts = line.split(separator: " ")
                if parts.first == "progress", parts.count == 3, let done = Int64(parts[1]), let total = Int64(parts[2]) {
                    Task { @MainActor in self?.state = .downloading(done: done, total: total) }
                }
            }.last ?? "failed no answer"
            guard last.hasPrefix("ready ") else {
                state = .failed(last.hasPrefix("failed ") ? String(last.dropFirst(7)) : "no answer")
                retryAfterFailure()
                return
            }
            key = String(last.dropFirst(6))
        }
        state = .ready
        // OLD BRIEFS, ONCE PER MODEL. Writes <session>/meaning.f32 beside each,
        // under the root THIS launch is actually recording to — never the
        // default one, which may not be where `--out` put this session.
        let flag = "meaningBackfilled.\(key ?? "")"
        if !UserDefaults.standard.bool(forKey: flag) {
            let done = await Self.lines(["backfill", root ?? Sessions.defaultRoot]).last ?? ""
            if done.hasPrefix("backfilled ") { UserDefaults.standard.set(true, forKey: flag) }
        }
    }

    /// Launch at Login can start Deiko before Wi-Fi is up, and that shouldn't
    /// need a trip to Settings to fix itself. One retry, about ten minutes
    /// later — `retriedAfterFailure` stops a second failure from stacking a
    /// second one on top.
    private func retryAfterFailure() {
        guard !retriedAfterFailure else { return }
        retriedAfterFailure = true
        Task {
            try? await Task.sleep(for: .seconds(600))
            start()
        }
    }

    /// Run `node scripts/meaning.mjs <args>` and collect its stdout lines,
    /// handing each to `each` as it arrives. Never throws: no Node, no script
    /// or a crash is an empty list, which reads as "failed".
    ///
    /// `nonisolated`, off the main actor: reading the process to EOF and then
    /// `waitUntilExit()` (which blocks the thread it runs on) must not run on
    /// the UI's. Sequential reading with `bytes.lines` also fixes the race the
    /// old readabilityHandler/terminationHandler pair had — the handoff
    /// between them could drop the final "ready" line.
    nonisolated private static func lines(_ args: [String], each: (@Sendable (String) -> Void)? = nil) async -> [String] {
        guard let node = NodeRuntime.resolve(), let script = scriptURL() else { return [] }
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        var collected: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                collected.append(line)
                each?(line)
            }
        } catch {
            // A read error ends the stream early; whatever came through still
            // stands, same as a crash mid-output did before this.
        }
        process.waitUntilExit()
        return collected
    }

    nonisolated private static func scriptURL() -> URL? {
        switch Layout.resolve() {
        case .development(let repo): return repo.appendingPathComponent("scripts/meaning.mjs")
        case .bundled(let resources): return resources.appendingPathComponent("scripts/meaning.mjs")
        case nil: return nil
        }
    }

    /// Where the licence files live: inside the bundle, or beside the checkout.
    static func licencesFolder() -> URL? {
        let url: URL
        switch Layout.resolve() {
        case .development(let repo): url = repo.appendingPathComponent("apps/capture/licenses")
        case .bundled(let resources): url = resources.appendingPathComponent("licenses")
        case nil: return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
