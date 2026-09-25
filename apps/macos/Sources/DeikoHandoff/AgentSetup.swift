import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// GIVING WHATEVER AGENT IS ON THIS MAC THE DEIKO MEMORY
//
// One click in Settings writes ONE entry — `deiko-memory` — into the user-level
// MCP config of every agent found here. Each agent spells the file its own way
// (`mcpServers`, `servers`, a TOML table), so the list below says where each
// one keeps it and in what shape; the paths are the ones each vendor's own
// docs name (checked Sept 2026). Left out on purpose, so "Copy setup" covers
// them: Windsurf (now Devin Desktop — its docs name three different paths),
// Zed (settings.json is JSONC; a round trip would drop the owner's comments),
// Cline (its settings file is moving from VS Code's storage to ~/.cline) and
// Roo Code (archived).
//
// The same rules for every file, because every one belongs to another app:
//   - a file that exists but will not parse is left alone, never replaced;
//   - only our entry changes, everything else is carried across
//     (`ClientConfig.merge` / `TomlConfig.merge`, both tested);
//   - symlinks are followed, so a dotfiles setup is written through to the
//     real file rather than replaced at the link;
//   - temp file then rename, with the original file's permissions, and a
//     one-time backup beside it;
//   - the write is read back before it counts.
// One agent failing does not stop the others.
//
// Takes `home` and the environment as parameters so the tests run the whole
// thing against a temp directory, never the owner's real configs.
// ─────────────────────────────────────────────────────────────────────────────

public struct AgentTarget: Sendable {
    public enum Format: Sendable, Equatable {
        /// Servers under `container`. `typed` adds `"type": "stdio"`, which VS
        /// Code requires; `env` adds an empty `env`, the shape Deiko has always
        /// written for Claude Code and Cursor (changing it would read as "not
        /// set up" for everyone who already is).
        case json(container: String, typed: Bool, env: Bool)
        /// Codex's `[mcp_servers.<name>]`.
        case toml
    }
    public let name: String
    /// Symlinks already resolved.
    public let config: URL
    public let format: Format
}

public enum AgentSetup {
    public static let serverKey = "deiko-memory"

    // ── Which agents are here ──────────────────────────────────────────────

    /// Every agent whose config folder (or file) exists. An agent that is
    /// installed but has never been opened has no folder yet; it gets set up
    /// on the next click after its first run.
    public static func detect(
        home: URL,
        environment: [String: String],
        applications: URL = URL(fileURLWithPath: "/Applications")
    ) -> [AgentTarget] {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func at(_ path: String) -> URL { home.appendingPathComponent(path) }
        let vsUser = at("Library/Application Support/Code/User")

        var found: [AgentTarget] = []
        func add(_ name: String, if present: Bool, _ config: URL, _ format: AgentTarget.Format) {
            guard present else { return }
            found.append(AgentTarget(name: name, config: config.resolvingSymlinksInPath(), format: format))
        }

        let claude = (environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home)
            .appendingPathComponent(".claude.json")
        add("Claude Code", if: exists(claude), claude, .json(container: "mcpServers", typed: true, env: true))

        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? at(".codex")
        add("Codex", if: exists(codex), codex.appendingPathComponent("config.toml"), .toml)

        add("Cursor", if: exists(at(".cursor")), at(".cursor/mcp.json"),
            .json(container: "mcpServers", typed: true, env: true))
        // Antigravity's folder may not exist until its first MCP server, so
        // the app itself also counts.
        let antigravity = at(".gemini/config")
        add("Antigravity", if: exists(antigravity) || exists(applications.appendingPathComponent("Antigravity.app")),
            antigravity.appendingPathComponent("mcp_config.json"),
            .json(container: "mcpServers", typed: false, env: false))
        add("Gemini CLI", if: exists(at(".gemini/settings.json")), at(".gemini/settings.json"),
            .json(container: "mcpServers", typed: false, env: false))
        add("VS Code", if: exists(vsUser), vsUser.appendingPathComponent("mcp.json"),
            .json(container: "servers", typed: true, env: false))
        return found
    }

    // ── Is it set up ────────────────────────────────────────────────────────

    public static func isRegistered(_ target: AgentTarget, command: String, arguments: [String]) -> Bool {
        switch target.format {
        case .toml:
            let text = try? String(contentsOf: target.config, encoding: .utf8)
            return TomlConfig.isRegistered(in: text, serverKey: serverKey, command: command, arguments: arguments)
        case .json(let container, _, _):
            guard case .parsed(let doc) = readJSON(target.config) else { return false }
            return ClientConfig.isRegistered(
                in: doc, serverKey: serverKey,
                matching: entry(target.format, command: command, arguments: arguments),
                containerKey: container)
        }
    }

    // ── Setting it up, and taking it out ────────────────────────────────────

    public struct Outcome: Sendable {
        /// Agents set up (or cleared), including ones that already were.
        public var done: [String] = []
        /// Agents left alone, with a sentence saying why.
        public var failed: [(agent: String, reason: String)] = []
    }

    public static func connect(_ targets: [AgentTarget], command: String, arguments: [String]) -> Outcome {
        var outcome = Outcome()
        for target in targets {
            if isRegistered(target, command: command, arguments: arguments) {
                outcome.done.append(target.name)
                continue
            }
            do {
                let data = try merged(target, command: command, arguments: arguments)
                try backupOnce(target.config)
                try writeAtomically(data, to: target.config)
                guard isRegistered(target, command: command, arguments: arguments) else {
                    throw Refusal("Couldn't confirm the change to \(target.config.path).")
                }
                outcome.done.append(target.name)
            } catch {
                outcome.failed.append((target.name, (error as? Refusal)?.reason ?? error.localizedDescription))
            }
        }
        return outcome
    }

    public static func disconnect(_ targets: [AgentTarget]) -> Outcome {
        var outcome = Outcome()
        for target in targets {
            do {
                let data: Data?
                switch target.format {
                case .toml:
                    let text = try? String(contentsOf: target.config, encoding: .utf8)
                    data = TomlConfig.remove(from: text, serverKey: serverKey).map { Data($0.utf8) }
                case .json(let container, _, _):
                    guard case .parsed(let doc) = readJSON(target.config),
                          let stripped = ClientConfig.remove(from: doc, serverKey: serverKey, containerKey: container)
                    else { data = nil; break }
                    data = try encode(stripped)
                }
                guard let data else { continue }  // nothing of ours there
                try writeAtomically(data, to: target.config)
                outcome.done.append(target.name)
            } catch {
                outcome.failed.append((target.name, error.localizedDescription))
            }
        }
        return outcome
    }

    // ── For any other agent ─────────────────────────────────────────────────

    /// What "Copy setup" puts on the clipboard: the command line, for an agent
    /// that asks for one, and the JSON most config files take.
    public static func setupText(command: String, arguments: [String]) -> String {
        let line = ([command] + arguments).map(shellQuoted).joined(separator: " ")
        let json = (try? encode(["mcpServers": [serverKey: ["command": command, "args": arguments]]]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
            Deiko memory, a local MCP server. Name it \(serverKey).

            Command:
            \(line)

            Or as JSON, for an agent with an mcpServers config file:
            \(json)
            """
    }

    // ── Mechanics ───────────────────────────────────────────────────────────

    struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

    static func entry(_ format: AgentTarget.Format, command: String, arguments: [String]) -> [String: Any] {
        var entry: [String: Any] = ["command": command, "args": arguments]
        if case .json(_, let typed, let env) = format {
            if typed { entry["type"] = "stdio" }
            if env { entry["env"] = [String: String]() }
        }
        return entry
    }

    enum Read { case missing, parsed([String: Any]?), unreadable }

    /// A missing or empty file is a config with nothing in it yet; one that
    /// exists and will not parse (comments, a half-finished edit) is one we do
    /// not understand, and replacing it would lose whatever it holds.
    static func readJSON(_ url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .parsed(nil)
        }
        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        return .parsed(doc)
    }

    private static func merged(_ target: AgentTarget, command: String, arguments: [String]) throws -> Data {
        let leftAlone = Refusal("Couldn't read \(target.config.path), so nothing was changed there.")
        switch target.format {
        case .toml:
            var text: String?
            if FileManager.default.fileExists(atPath: target.config.path) {
                guard let read = try? String(contentsOf: target.config, encoding: .utf8) else { throw leftAlone }
                text = read
            }
            guard let out = TomlConfig.merge(into: text, serverKey: serverKey, command: command, arguments: arguments)
            else { throw leftAlone }
            return Data(out.utf8)
        case .json(let container, _, _):
            let doc: [String: Any]?
            switch readJSON(target.config) {
            case .missing: doc = nil
            case .parsed(let parsed): doc = parsed
            case .unreadable: throw leftAlone
            }
            guard let out = try? ClientConfig.merge(
                into: doc, serverKey: serverKey,
                entry: entry(target.format, command: command, arguments: arguments),
                containerKey: container)
            else { throw leftAlone }
            return try encode(out)
        }
    }

    private static func encode(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// One copy of the file from before Deiko first wrote to it.
    private static func backupOnce(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).before-deiko-memory")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Temp file, then rename over: a reader sees the whole old file or the
    /// whole new one, never half. The temp file takes the original's
    /// permissions (0600 for a new file — these hold accounts and tokens).
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        let temp = directory.appendingPathComponent(".deiko-\(UUID().uuidString).tmp")
        // No `.atomic`: `temp` IS the scratch file the rename below makes atomic.
        try data.write(to: temp)
        do {
            try fm.setAttributes([.posixPermissions: mode ?? NSNumber(value: 0o600)], ofItemAtPath: temp.path)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            // Nothing landed at `url`; don't leave a full copy of the config behind.
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
