import Foundation
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// GIVING CLAUDE CODE AND CURSOR THE DEIKO MEMORY
//
// One click in Settings writes ONE key — `deiko-memory` under `mcpServers` —
// into ~/.claude.json and ~/.cursor/mcp.json, for the clients that exist on
// this Mac. Everything else in those files is read and written back untouched
// (`ClientConfig.merge`, tested), a one-time backup sits beside each file,
// and the write is verified by reading it back. The entry names the node this
// app resolved and the script by absolute path, because the client spawns it
// with its own environment. `LegacyMCP` only ever removes `fovea`, never this.
// ─────────────────────────────────────────────────────────────────────────────

enum MemoryHelper {
    static let serverKey = "deiko-memory"

    enum Failure: Error, LocalizedError {
        case noRuntime
        case unreadable(String)
        case notVerified(String)
        var errorDescription: String? {
            switch self {
            case .noRuntime: return "Deiko could not find its Node runtime."
            case .unreadable(let path): return "Couldn't read \(path), so nothing was changed there."
            case .notVerified(let path): return "Couldn't confirm the change to \(path)."
            }
        }
    }

    /// The clients that exist on this Mac: a config file, or a config folder.
    static func targets() -> [(name: String, url: URL)] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [(String, URL)] = []
        let claude = AgentConfigs.claudeConfig()
        if FileManager.default.fileExists(atPath: claude.path) { found.append(("Claude Code", claude)) }
        let cursorDir = home.appendingPathComponent(".cursor")
        if FileManager.default.fileExists(atPath: cursorDir.path) {
            found.append(("Cursor", cursorDir.appendingPathComponent("mcp.json")))
        }
        return found
    }

    static func entry() -> [String: Any]? {
        guard let node = NodeRuntime.resolve() else { return nil }
        let script: URL
        switch Layout.resolve() {
        case .development(let repo): script = repo.appendingPathComponent("scripts/memory-mcp.mjs")
        case .bundled(let resources): script = resources.appendingPathComponent("scripts/memory-mcp.mjs")
        case nil: return nil
        }
        return ClientConfig.stdioEntry(command: node.path, arguments: [script.path])
    }

    static func isConnected() -> Bool {
        guard let entry = entry() else { return false }
        return targets().contains { ClientConfig.isRegistered(in: AgentConfigs.readJSON($0.url), serverKey: serverKey, matching: entry) }
    }

    /// Write the entry to every client here. Returns the names written.
    @discardableResult
    static func connect() throws -> [String] {
        guard let entry = entry() else { throw Failure.noRuntime }
        var written: [String] = []
        for target in targets() {
            let existing = AgentConfigs.readJSON(target.url)
            // A file that exists but will not parse is one we do not understand:
            // writing would replace the client's own account and history.
            if existing == nil, FileManager.default.fileExists(atPath: target.url.path) {
                throw Failure.unreadable(target.url.path)
            }
            if ClientConfig.isRegistered(in: existing, serverKey: serverKey, matching: entry) {
                written.append(target.name)
                continue
            }
            let merged = try ClientConfig.merge(into: existing, serverKey: serverKey, entry: entry)
            try backupOnce(target.url)
            try writeAtomically(merged, to: target.url)
            guard ClientConfig.isRegistered(in: AgentConfigs.readJSON(target.url), serverKey: serverKey, matching: entry) else {
                throw Failure.notVerified(target.url.path)
            }
            written.append(target.name)
        }
        return written
    }

    static func disconnect() throws {
        for target in targets() {
            guard let stripped = ClientConfig.remove(from: AgentConfigs.readJSON(target.url), serverKey: serverKey) else { continue }
            try writeAtomically(stripped, to: target.url)
        }
    }

    /// One copy of the file from before Deiko first wrote to it.
    private static func backupOnce(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).before-deiko-memory")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Temp file, then rename over: a reader sees the whole old file or the
    /// whole new one, never half.
    private static func writeAtomically(_ document: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".deiko-\(UUID().uuidString).json")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
