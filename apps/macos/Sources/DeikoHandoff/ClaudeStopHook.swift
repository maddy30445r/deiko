import Foundation

/// Deiko's Stop hook in Claude Code's `settings.json`: before the agent finishes
/// a Deiko brief, the hook asks it to save its report (`claude-stop-hook.mjs`).
/// Only our entry is ever added, replaced or removed; it is recognised by the
/// script's file name, so a moved app replaces its old entry instead of adding
/// a second one.
public enum ClaudeStopHook {
    public static let scriptName = "claude-stop-hook.mjs"

    /// `settings.json` beside the Claude Code config this Mac uses.
    public static func settingsURL(home: URL, environment: [String: String]) -> URL {
        let dir = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return dir.appendingPathComponent("settings.json").resolvingSymlinksInPath()
    }

    public static func isRegistered(in settings: [String: Any]?, command: String) -> Bool {
        stopGroups(settings).contains { commands(in: $0) == [command] }
    }

    /// `settings` with exactly one Deiko Stop entry, running `command`.
    public static func merge(into settings: [String: Any]?, command: String) -> [String: Any] {
        var doc = remove(from: settings) ?? settings ?? [:]
        var hooks = doc["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [Any] ?? []
        stop.append(["hooks": [["type": "command", "command": command]]])
        hooks["Stop"] = stop
        doc["hooks"] = hooks
        return doc
    }

    /// `settings` without Deiko's Stop entry, or nil when it had none.
    public static func remove(from settings: [String: Any]?) -> [String: Any]? {
        guard var doc = settings, var hooks = doc["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [Any] else { return nil }
        let kept = stop.filter { group in
            !((group as? [String: Any]).map { commands(in: $0).contains(where: isOurs) } ?? false)
        }
        guard kept.count != stop.count else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = kept }
        if hooks.isEmpty { doc.removeValue(forKey: "hooks") } else { doc["hooks"] = hooks }
        return doc
    }

    private static func isOurs(_ command: String) -> Bool { command.contains(scriptName) }

    private static func stopGroups(_ settings: [String: Any]?) -> [[String: Any]] {
        ((settings?["hooks"] as? [String: Any])?["Stop"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func commands(in group: [String: Any]) -> [String] {
        (group["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
    }
}

extension ClaudeStopHook {
    static func isInstalled(at url: URL, command: String) -> Bool {
        guard case .parsed(let doc) = AgentSetup.readJSON(url) else { return false }
        return isRegistered(in: doc, command: command)
    }

    /// Writes our entry into `url`, leaving a file that will not parse untouched.
    static func install(at url: URL, command: String) throws {
        let doc: [String: Any]?
        switch AgentSetup.readJSON(url) {
        case .missing: doc = nil
        case .parsed(let parsed): doc = parsed
        case .unreadable: throw AgentSetup.Refusal("Couldn't read \(url.path), so the report-back hook wasn't added.")
        }
        guard !isRegistered(in: doc, command: command) else { return }
        try AgentSetup.backupOnce(url)
        try AgentSetup.writeAtomically(AgentSetup.encode(merge(into: doc, command: command)), to: url)
        guard isInstalled(at: url, command: command) else {
            throw AgentSetup.Refusal("Couldn't confirm the change to \(url.path).")
        }
    }

    static func uninstall(at url: URL) throws {
        guard case .parsed(let doc) = AgentSetup.readJSON(url), let stripped = remove(from: doc) else { return }
        try AgentSetup.writeAtomically(AgentSetup.encode(stripped), to: url)
    }
}
