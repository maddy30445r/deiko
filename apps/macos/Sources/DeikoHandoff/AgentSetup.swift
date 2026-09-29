import Foundation

public struct AgentTarget: Sendable {
    public enum Format: Sendable, Equatable {
        /// Servers under `container`. `typed` adds `"type": "stdio"`, which VS
        /// Code requires; `env` adds an empty `env`, the shape already written
        /// for Claude Code and Cursor (changing it would read as "not set up"
        /// for existing installs).
        case json(container: String, typed: Bool, env: Bool)
        /// Codex's `[mcp_servers.<name>]`.
        case toml
    }
    public let name: String
    /// Symlinks already resolved.
    public let config: URL
    public let format: Format
    /// Claude Code's `settings.json`, where the report-back Stop hook goes; nil for other agents.
    public var stopHookSettings: URL? = nil
}

/// Sets up `deiko-memory` in the user-level MCP config of every agent found on
/// this Mac. Each agent spells its file its own way (`mcpServers`, `servers`, a
/// TOML table), and `detect` records where each keeps it. Left to "Copy setup":
/// Windsurf (its docs name three different paths), Zed (`settings.json` is
/// JSONC, so a round trip would drop comments), Cline (its settings location is
/// moving) and Roo Code (archived).
///
/// The same rules apply to every file, because each belongs to another app:
/// - a file that exists but will not parse is left alone, never replaced;
/// - only our entry changes (`ClientConfig.merge`, `TomlConfig.merge`);
/// - symlinks are followed, so a dotfiles setup is written through to the real
///   file;
/// - temp file then rename, keeping the original permissions, with a one-time
///   backup beside it;
/// - the write is read back before it counts.
///
/// One agent failing does not stop the others. `home` and the environment are
/// parameters so tests run against a temp directory.
public enum AgentSetup {
    public static let serverKey = "deiko-memory"

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
        func add(_ name: String, if present: Bool, _ config: URL, _ format: AgentTarget.Format, stopHook: URL? = nil) {
            guard present else { return }
            found.append(AgentTarget(name: name, config: config.resolvingSymlinksInPath(), format: format, stopHookSettings: stopHook))
        }

        let claude = (environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home)
            .appendingPathComponent(".claude.json")
        add("Claude Code", if: exists(claude), claude, .json(container: "mcpServers", typed: true, env: true),
            stopHook: ClaudeStopHook.settingsURL(home: home, environment: environment))

        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? at(".codex")
        add("Codex", if: exists(codex), codex.appendingPathComponent("config.toml"), .toml)

        add("Cursor", if: exists(at(".cursor")), at(".cursor/mcp.json"),
            .json(container: "mcpServers", typed: true, env: true))
        // Detected by the app rather than the folder: `~/.gemini/config` can
        // exist on Macs that never had Antigravity.
        add("Antigravity", if: exists(applications.appendingPathComponent("Antigravity.app"))
                || exists(at("Applications/Antigravity.app")),
            at(".gemini/config/mcp_config.json"),
            .json(container: "mcpServers", typed: false, env: false))
        add("Gemini CLI", if: exists(at(".gemini/settings.json")), at(".gemini/settings.json"),
            .json(container: "mcpServers", typed: false, env: false))
        add("VS Code", if: exists(vsUser), vsUser.appendingPathComponent("mcp.json"),
            .json(container: "servers", typed: true, env: false))
        return found
    }

    /// The memory server is in the agent's config, and for Claude Code the Stop hook is in its settings.
    public static func isRegistered(_ target: AgentTarget, command: String, arguments: [String]) -> Bool {
        guard serverRegistered(target, command: command, arguments: arguments) else { return false }
        guard let settings = target.stopHookSettings, let hook = stopHookCommand(command: command, arguments: arguments)
        else { return true }
        // A settings file that won't parse is left alone, so it can't hold the hook; don't let it
        // keep the agent looking unconnected forever.
        if case .unreadable = readJSON(settings) { return true }
        return ClaudeStopHook.isInstalled(at: settings, command: hook)
    }

    /// The Stop hook's command line: the same node, running the script beside the memory server.
    static func stopHookCommand(command: String, arguments: [String]) -> String? {
        guard let server = arguments.first else { return nil }
        let hook = URL(fileURLWithPath: server).deletingLastPathComponent().appendingPathComponent(ClaudeStopHook.scriptName)
        return [command, hook.path].map(shellQuoted).joined(separator: " ")
    }

    private static func serverRegistered(_ target: AgentTarget, command: String, arguments: [String]) -> Bool {
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

    public struct Outcome: Sendable {
        /// Agents set up (or cleared), including ones that already were.
        public var done: [String] = []
        /// Agents left alone, with a sentence saying why.
        public var failed: [(agent: String, reason: String)] = []
    }

    public static func connect(_ targets: [AgentTarget], command: String, arguments: [String]) -> Outcome {
        var outcome = Outcome()
        for target in targets {
            do {
                if !serverRegistered(target, command: command, arguments: arguments) {
                    let data = try merged(target, command: command, arguments: arguments)
                    try backupOnce(target.config)
                    try writeAtomically(data, to: target.config)
                    guard serverRegistered(target, command: command, arguments: arguments) else {
                        throw Refusal("Couldn't confirm the change to \(target.config.path).")
                    }
                }
                if let settings = target.stopHookSettings, let hook = stopHookCommand(command: command, arguments: arguments) {
                    try ClaudeStopHook.install(at: settings, command: hook)
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
                if let settings = target.stopHookSettings { try ClaudeStopHook.uninstall(at: settings) }
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

    static func encode(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func shellQuoted(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// One copy of the file from before Deiko first wrote to it.
    static func backupOnce(_ url: URL) throws {
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
