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

    func start() {
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
                return
            }
            key = String(last.dropFirst(6))
        }
        state = .ready
        // OLD BRIEFS, ONCE PER MODEL. Writes <session>/meaning.f32 beside each.
        let flag = "meaningBackfilled.\(key ?? "")"
        if !UserDefaults.standard.bool(forKey: flag) {
            let done = await Self.lines(["backfill", Sessions.defaultRoot]).last ?? ""
            if done.hasPrefix("backfilled ") { UserDefaults.standard.set(true, forKey: flag) }
        }
    }

    /// Run `node scripts/meaning.mjs <args>` and collect its stdout lines,
    /// handing each to `each` as it arrives. Never throws: no Node, no script
    /// or a crash is an empty list, which reads as "failed".
    private static func lines(_ args: [String], each: (@Sendable (String) -> Void)? = nil) async -> [String] {
        guard let node = NodeRuntime.resolve(), let script = scriptURL() else { return [] }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = node
            process.arguments = [script.path] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let collected = LineCollector(each: each)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collected.finish())
            }
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }

    private static func scriptURL() -> URL? {
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

/// Splits a byte stream into lines, thread-safely, as the pipe delivers it.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private let each: (@Sendable (String) -> Void)?

    init(each: (@Sendable (String) -> Void)?) { self.each = each }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var ready: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line); ready.append(line) }
        }
        lock.unlock()
        ready.forEach { each?($0) }
    }

    func finish() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let tail = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lines.append(tail) }
        return lines
    }
}
