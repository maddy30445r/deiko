import Foundation
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// REMOVING WHAT WE USED TO WRITE
//
// Fovea up to 0.2.1 registered an MCP server in the user's coding client, with
// an absolute path into its own bundle. That bridge is gone, so anyone who ever
// pressed Connect now has a client spawning a missing file on every start —
// a failure they would attribute to their editor, not to us.
//
// TWO THINGS THIS MUST NEVER DO. First, delete an entry it did not write:
// `fovea` is a name, not a marker, and somebody may have registered their own
// server under it. Second, believe a removal happened when it did not: Claude
// Code rewrites `~/.claude.json` wholesale and can resurrect a stale entry
// after we remove it, so a flag set on the strength of a write call — rather
// than a write CONFIRMED by reading the file back — would let that entry keep
// spawning a missing bridge forever, silently, with the one mechanism built to
// catch it disarmed.
//
// So every check here is by CONTENT, not by key name, and the flag is only
// set once every target has been positively confirmed clean this pass —
// "nothing of ours was ever there" counts as clean; "wrote, but could not
// verify it stuck" does not. It reuses `ClientConfig.remove` /
// `TomlConfig.remove` for the actual edit rather than reimplementing them:
// those are the tested ones, and this is not the place to have a second
// opinion about how to touch one key and leave the rest of the file alone.
// ─────────────────────────────────────────────────────────────────────────────

enum LegacyMCP {
    private static let doneKey = "legacyMCPCleaned"

    static func cleanUpOnce() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let json: [(URL, String)] = [
            (configPathForClaude(), "mcpServers"),
            (home.appendingPathComponent(".cursor/mcp.json"), "mcpServers"),
            (home.appendingPathComponent(".gemini/config/mcp_config.json"), "mcpServers"),
        ]

        // Every target has to come back clean before the flag is set — see the
        // header comment. `&=` rather than early-exit: a config we can't clear
        // must not stop us checking the others.
        var confirmedClean = true
        for (url, containerKey) in json {
            confirmedClean = cleanJSON(url: url, containerKey: containerKey) && confirmedClean
        }
        let toml = codexHome().appendingPathComponent("config.toml")
        confirmedClean = cleanTOML(url: toml) && confirmedClean

        if confirmedClean {
            UserDefaults.standard.set(true, forKey: doneKey)
        }
        // Left unset otherwise. The cost of that is one more parse of these
        // files at next launch — the same files LegacyMCP itself already reads
        // whenever it has anything left to check; it is not an every-launch
        // cost for someone whose configs came back clean.
    }

    /// Strip a Fovea entry from one JSON MCP config, if — and only if — the
    /// entry under `fovea` actually looks like ours.
    ///
    /// Returns whether `url` is confirmed to hold no Fovea entry once this
    /// call returns: true covers both "there never was one" and "there was
    /// one and the read-back proves it's gone"; false means the file could
    /// not be read, parsed, written, or verified, and the caller should try
    /// again next launch.
    private static func cleanJSON(url: URL, containerKey: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return true  // no file — nothing of ours can be in it
        }
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false  // exists but we can't parse it — can't confirm either way
        }
        let servers = document[containerKey] as? [String: Any]
        guard looksLikeFoveaEntry(servers?["fovea"]) else {
            // Nothing under that key, or something under it that is not ours —
            // either way we do not touch it, and either way this config is
            // clean from OUR side.
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

        // Read it back — an atomic write that reported success but left our
        // entry readable (something else won a race to rewrite the file right
        // after) is exactly the failure this pass exists to catch, and it is
        // one read to rule out.
        let verifyServers = readJSON(url)?[containerKey] as? [String: Any]
        guard !looksLikeFoveaEntry(verifyServers?["fovea"]) else {
            Emit.log("wrote \(url.path), but the fovea MCP entry was still there on read-back")
            return false
        }

        Emit.log("removed the old fovea MCP entry from \(url.path)")
        removeBackup(beside: url)
        return true
    }

    /// The Codex CLI equivalent, over `TomlConfig`'s line-range surgery rather
    /// than a real parser — same contract as `cleanJSON`.
    private static func cleanTOML(url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return true  // no file — nothing of ours can be in it
        }
        guard looksLikeFoveaTable(TomlConfig.lines(of: "fovea", in: text)) else {
            return true  // no table, or one that isn't ours
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
        guard let verifyText, !looksLikeFoveaTable(TomlConfig.lines(of: "fovea", in: verifyText)) else {
            Emit.log("wrote \(url.path), but the fovea MCP entry was still there on read-back")
            return false
        }

        Emit.log("removed the old fovea MCP entry from \(url.path)")
        removeBackup(beside: url)
        return true
    }

    // ── Recognising OUR entry, by shape rather than by the name it sits under ──

    /// Whether a JSON MCP entry is one Fovea itself would have written: a
    /// stdio server whose command is an absolute path to a `node` binary and
    /// whose single argument ends in `apps/bridge/src/server.mjs` — the exact
    /// shape `ClientConfig.stdioEntry` used to produce. Anything else under
    /// the `fovea` key — someone's own server, hand-registered under the same
    /// name — is not ours to touch.
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

    /// The TOML equivalent, over the raw lines of `[mcp_servers.fovea]`: a
    /// `command` value that is an absolute `node` path, and an `args` value
    /// naming the bridge. Deliberately text matching, not parsing — the same
    /// register `TomlConfig` itself stays in.
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

    // ── Fovea's own leftovers ───────────────────────────────────────────────

    /// The one-time backup Fovea's old connector wrote beside a config the
    /// first time it ever touched it — `<filename>.before-fovea`, a full
    /// snapshot of whatever was there before (for `~/.claude.json`, that
    /// includes the user's `oauthAccount`). Removed only from here, only after
    /// the entry itself was confirmed gone, and only this exact name — never
    /// anything else found beside the config.
    private static func removeBackup(beside url: URL) {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).before-fovea")
        try? FileManager.default.removeItem(at: backup)
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Claude Code honours `CLAUDE_CONFIG_DIR`, and so did the entry we wrote —
    /// so the cleanup has to look where the write went, not where it usually
    /// goes.
    private static func configPathForClaude() -> URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return dir.appendingPathComponent(".claude.json")
    }

    private static func codexHome() -> URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }
}
