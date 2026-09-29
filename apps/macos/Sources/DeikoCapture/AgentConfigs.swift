import Foundation
import DeikoHandoff

// Reads the MCP configs of the agents on this Mac (Claude Code, Cursor, Gemini,
// Codex) to see which trackers are already connected. Read-only: Deiko never
// writes another application's config.
//
// Home-level configs only: a per-repo config needs a checkout path, and a
// session only knows a repo name.
//
// The result is cached because `write(_:)` needs it on the brief-rendering
// path, and `~/.claude.json` can be megabytes.

enum AgentConfigs {

    /// Claude Code honours `CLAUDE_CONFIG_DIR`.
    static func claudeConfig() -> URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return dir.appendingPathComponent(".claude.json")
    }

    static func codexHome() -> URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Which agents name which trackers. A missing or unreadable file means
    /// nothing is connected there, never an error: these files belong to other
    /// applications and may be mid-edit.
    ///
    /// Synchronous file reads; call it off the main actor.
    static func scan() -> [Tracker: Set<AgentClient>] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [Tracker: Set<AgentClient>] = [:]

        func note(_ trackers: Set<Tracker>, _ client: AgentClient) {
            for t in trackers { found[t, default: []].insert(client) }
        }

        note(Integrations.trackers(inClaudeConfig: readJSON(claudeConfig())), .claudeCode)
        note(Integrations.trackers(
            inServers: readJSON(home.appendingPathComponent(".cursor/mcp.json"))?["mcpServers"]
        ), .cursor)
        note(Integrations.trackers(
            inServers: readJSON(home.appendingPathComponent(".gemini/settings.json"))?["mcpServers"]
        ), .gemini)
        note(Integrations.trackers(
            inCodexTOML: try? String(
                contentsOf: codexHome().appendingPathComponent("config.toml"), encoding: .utf8
            )
        ), .codex)

        return found
    }

    private static let lock = NSLock()
    /// Guarded by `lock` on every path. Not an actor, so the brief path never
    /// has to `await`.
    nonisolated(unsafe) private static var cache: [Tracker: Set<AgentClient>] = [:]

    /// The last answer, for callers that cannot wait (the brief path).
    ///
    /// Empty until the first scan lands. Empty is the safe default: it renders
    /// "file it if you have the tools", which is true either way.
    static var connected: [Tracker: Set<AgentClient>] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    static var connectedTrackers: Set<Tracker> { Set(connected.keys) }

    /// Reads the configs and updates the cache. Call off the main thread.
    @discardableResult
    static func refresh() -> [Tracker: Set<AgentClient>] {
        let fresh = scan()
        lock.lock()
        cache = fresh
        lock.unlock()
        return fresh
    }

    /// Call at launch so the first brief already knows.
    static func warm() {
        Task.detached(priority: .utility) { _ = refresh() }
    }
}
