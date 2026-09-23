import Foundation
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// WHAT THE AGENTS ON THIS MAC ARE CONNECTED TO
//
// Four files, read and never written. Deiko used to write one of them and does
// not any more (`LegacyMCP`'s header explains at length why touching another
// application's config is a debt); reading is a different promise, and the only
// thing it is used for is telling somebody, in Deiko's own window, that Jira is
// already set up in Claude Code — and choosing between two wordings in a
// persona file.
//
// Home-level configs only. Claude Code also keeps a block per project inside
// `~/.claude.json`, and those DO count — a tracker configured for one repo is
// still one this Mac can reach — but a repo's own `.mcp.json` / `.cursor` /
// `.codex` needs a checkout path, and a session only knows a repo NAME, read
// off a window title.
// ponytail: per-repo configs when a session can resolve its checkout path
//
// CACHED, because `write(_:)` needs the answer and sits on the path that
// renders a brief. `~/.claude.json` carries per-project history and can be
// megabytes; parsing it while somebody waits for their coin would be absurd.
// ─────────────────────────────────────────────────────────────────────────────

enum AgentConfigs {

    // ── Where each client keeps its list ────────────────────────────────────

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

    // ── The answer ──────────────────────────────────────────────────────────

    /// Which agents name which trackers. A missing or unreadable file means
    /// "nothing connected there", never an error: these belong to other
    /// applications and a half-written one is somebody mid-edit.
    ///
    /// Synchronous file reads — call it off the main actor.
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

    // ── The cache ───────────────────────────────────────────────────────────

    private static let lock = NSLock()
    /// Guarded by `lock` on every path — the compiler cannot see that, hence
    /// the annotation rather than an actor: an actor here would make every
    /// read `await`, including the one on the brief path that must not wait.
    nonisolated(unsafe) private static var cache: [Tracker: Set<AgentClient>] = [:]

    /// The last answer, for anyone who cannot wait — the brief path.
    ///
    /// Empty until the first scan lands, and empty is the SAFE direction: it
    /// renders "file it if you have the tools", which is true whether or not
    /// anything is connected. The opposite default would tell an agent it has
    /// a tool it does not.
    static var connected: [Tracker: Set<AgentClient>] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    static var connectedTrackers: Set<Tracker> { Set(connected.keys) }

    /// Read the configs and update the cache. Off the main thread, please.
    @discardableResult
    static func refresh() -> [Tracker: Set<AgentClient>] {
        let fresh = scan()
        lock.lock()
        cache = fresh
        lock.unlock()
        return fresh
    }

    /// At launch, so the first brief of the session already knows.
    static func warm() {
        Task.detached(priority: .utility) { _ = refresh() }
    }
}
