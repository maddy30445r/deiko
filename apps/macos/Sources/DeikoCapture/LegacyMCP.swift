import Foundation
import DeikoHandoff

/// One-time removal of the `fovea` MCP entry that earlier builds registered in coding clients.
///
/// Two invariants. Never delete an entry this app did not write: `fovea` is a name, not a marker, so an
/// entry is removed only if it has the shape of ours. And never trust a removal: Claude Code rewrites
/// `~/.claude.json` wholesale and can resurrect a stale entry seconds later, so the done flag is set only
/// on a pass where every target was already clean. A pass that removed something leaves the flag unset
/// and the next launch checks again. An entry that exists but is not ours also counts as clean, since it
/// can never become ours to remove.
///
/// The edits themselves reuse `ClientConfig.remove` and `TomlConfig.remove`.
enum LegacyMCP {
    private static let doneKey = "legacyMCPCleaned"

    static func cleanUpOnce() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let json: [(URL, String)] = [
            (AgentConfigs.claudeConfig(), "mcpServers"),
            (home.appendingPathComponent(".cursor/mcp.json"), "mcpServers"),
            (home.appendingPathComponent(".gemini/config/mcp_config.json"), "mcpServers"),
        ]

        // The flag is set only if every target was already clean (see the type's doc comment). `&&` rather
        // than an early exit, so a config that needed a removal does not stop the others being checked.
        var allAlreadyClean = true
        for (url, containerKey) in json {
            allAlreadyClean = cleanJSON(url: url, containerKey: containerKey) && allAlreadyClean
        }
        let toml = AgentConfigs.codexHome().appendingPathComponent("config.toml")
        allAlreadyClean = cleanTOML(url: toml) && allAlreadyClean

        if allAlreadyClean {
            UserDefaults.standard.set(true, forKey: doneKey)
        }
    }

    /// Strips a `fovea` entry from one JSON MCP config, only if it looks like ours.
    ///
    /// Returns whether `url` was already clean going in: true when there was nothing of ours to remove
    /// (no entry, or one that is not ours). Removing an entry returns false even when the read-back
    /// confirms it (see the type's doc comment).
    private static func cleanJSON(url: URL, containerKey: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return true  // no file — nothing of ours can be in it
        }
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false  // exists but we can't parse it — can't confirm either way
        }
        let servers = document[containerKey] as? [String: Any]
        let entry = servers?["fovea"]

        // Three outcomes, kept explicit: collapsing "absent" and "present but not ours" into one branch
        // would delete the backup beside a hand-registered `fovea` entry.
        guard entry != nil else {
            // No `fovea` key: already clean, so any backup left beside the file is an orphan.
            removeBackup(beside: url)
            return true
        }
        guard looksLikeFoveaEntry(entry) else {
            // Registered under `fovea` but not ours: touch nothing, neither entry nor backup. Counts as
            // clean, since it can never become ours to remove.
            return true
        }

        guard let stripped = ClientConfig.remove(
                  from: document, serverKey: "fovea", containerKey: containerKey
              ),
              let out = try? JSONSerialization.data(
                  withJSONObject: stripped,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return false }

        do {
            try out.write(to: url, options: .atomic)
        } catch {
            Emit.log("could not remove the old fovea MCP entry from \(url.path): \(error.localizedDescription)")
            return false
        }

        // Read back only to log accurately. It does not gate the return value: this pass found an entry,
        // so it was not already clean.
        let verifyServers = AgentConfigs.readJSON(url)?[containerKey] as? [String: Any]
        if looksLikeFoveaEntry(verifyServers?["fovea"]) {
            Emit.log("wrote \(url.path), but the fovea MCP entry was still there on read-back")
        } else {
            Emit.log("removed the old fovea MCP entry from \(url.path)")
            removeBackup(beside: url)
        }
        return false
    }

    /// The Codex CLI equivalent, over `TomlConfig`'s line-range edits rather than a real parser.
    /// Same contract as `cleanJSON`.
    private static func cleanTOML(url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return true  // no file — nothing of ours can be in it
        }
        let table = TomlConfig.lines(of: "fovea", in: text)

        // Same three outcomes as `cleanJSON`.
        guard let table else {
            // No `[mcp_servers.fovea]` table at all — already clean.
            removeBackup(beside: url)
            return true
        }
        guard looksLikeFoveaTable(table) else {
            // A table exists but is not ours — leave it and its backup alone.
            return true
        }

        guard let stripped = TomlConfig.remove(from: text, serverKey: "fovea") else {
            return false  // `lines(of:)` found a table but `remove` didn't — unexpected; don't guess
        }

        do {
            try Data(stripped.utf8).write(to: url, options: .atomic)
        } catch {
            Emit.log("could not remove the old fovea MCP entry from \(url.path): \(error.localizedDescription)")
            return false
        }

        let verifyText = try? String(contentsOf: url, encoding: .utf8)
        if let verifyText, looksLikeFoveaTable(TomlConfig.lines(of: "fovea", in: verifyText)) {
            Emit.log("wrote \(url.path), but the fovea MCP entry was still there on read-back")
        } else {
            Emit.log("removed the old fovea MCP entry from \(url.path)")
            removeBackup(beside: url)
        }
        return false
    }

    /// Whether a JSON MCP entry has the shape earlier builds wrote: a stdio server whose command is an
    /// absolute path to a `node` binary and whose single argument ends in `apps/bridge/src/server.mjs`.
    /// Anything else under `fovea` belongs to someone else and is not ours to touch.
    private static func looksLikeFoveaEntry(_ raw: Any?) -> Bool {
        guard let entry = raw as? [String: Any],
              entry["type"] as? String == "stdio",
              let command = entry["command"] as? String,
              command.hasPrefix("/"), command.hasSuffix("/node"),
              let args = entry["args"] as? [String], args.count == 1,
              args[0].hasSuffix("apps/bridge/src/server.mjs")
        else { return false }
        return true
    }

    /// The TOML equivalent, over the raw lines of `[mcp_servers.fovea]`: an absolute `node` command and
    /// an `args` value naming the bridge. Text matching rather than parsing, like `TomlConfig`.
    private static func looksLikeFoveaTable(_ lines: [String]?) -> Bool {
        guard let lines else { return false }
        let hasNodeCommand = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command"), let eq = trimmed.firstIndex(of: "=") else { return false }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("\"/") && value.hasSuffix("/node\"")
        }
        let hasBridgeArg = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("args") && trimmed.contains("apps/bridge/src/server.mjs")
        }
        return hasNodeCommand && hasBridgeArg
    }

    /// Removes the one-time backup an earlier connector wrote beside a config, `<filename>.before-fovea`
    /// (for `~/.claude.json` it includes the user's `oauthAccount`).
    ///
    /// Called only once the entry is confirmed gone, never from the "present but not ours" branch. Only
    /// this exact name is touched, and failure is ignored: a backup that will not delete is not worth retrying.
    private static func removeBackup(beside url: URL) {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).before-fovea")
        try? FileManager.default.removeItem(at: backup)
    }

}
