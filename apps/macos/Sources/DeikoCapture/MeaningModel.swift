import Foundation

/// Downloads the on-device embedding model once and backfills vectors for existing briefs.
///
/// Filing blends word matching with the model (see packages/core/src/lib/meaning.mjs). The model is
/// large, so the installer does not carry it; every downloaded file is checked against a pinned
/// SHA-256. Until the model is ready, or if it never is, filing uses words alone.
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
    /// The board this launch records to (`recorder.sessionRoot`), which `--out` can move away from
    /// `Sessions.defaultRoot`. Set by the first `start(root:)` and reused, including by Settings' "Try again".
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
        // Writes <session>/meaning.f32 beside each brief, under the root this launch records to.
        let flag = "meaningBackfilled.\(key ?? "")"
        if !UserDefaults.standard.bool(forKey: flag) {
            let done = await Self.lines(["backfill", root ?? Sessions.defaultRoot]).last ?? ""
            if done.hasPrefix("backfilled ") { UserDefaults.standard.set(true, forKey: flag) }
        }
    }

    /// One retry about ten minutes later, since Launch at Login can start Deiko before Wi-Fi is up.
    /// `retriedAfterFailure` stops a second failure from stacking another.
    private func retryAfterFailure() {
        guard !retriedAfterFailure else { return }
        retriedAfterFailure = true
        Task {
            try? await Task.sleep(for: .seconds(600))
            start()
        }
    }

    /// Run `node packages/core/src/meaning.mjs <args>` and collect its stdout lines, handing each to
    /// `each` as it arrives. Never throws: no Node, no script or a crash is an empty list, which reads as "failed".
    ///
    /// `nonisolated` so the blocking `waitUntilExit()` stays off the main actor. Lines are read
    /// sequentially so the final "ready" line cannot be dropped.
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
            // A read error ends the stream early; keep whatever came through.
        }
        process.waitUntilExit()
        return collected
    }

    nonisolated private static func scriptURL() -> URL? {
        switch Layout.resolve() {
        case .development(let repo): return repo.appendingPathComponent("packages/core/src/meaning.mjs")
        case .bundled(let resources): return resources.appendingPathComponent("scripts/meaning.mjs")
        case nil: return nil
        }
    }

    /// Where the licence files live: inside the bundle, or beside the checkout.
    static func licencesFolder() -> URL? {
        let url: URL
        switch Layout.resolve() {
        case .development(let repo): url = repo.appendingPathComponent("apps/macos/licenses")
        case .bundled(let resources): url = resources.appendingPathComponent("licenses")
        case nil: return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
