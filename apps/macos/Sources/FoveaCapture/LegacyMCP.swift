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
// SECONDS after we remove it, from an in-memory copy it already had open — and
// reading our own write back only proves the write landed, not that it stuck.
// That race is exactly what the deleted `Connectors.selfHeal()` ran on every
// launch to survive; this only runs once, so it has to be more careful about
// what "once" means.
//
// So the flag is only set on a pass where every target was ALREADY clean —
// nothing found to remove. A pass that found and removed something leaves the
// flag unset regardless of how the write and its read-back went: the next
// launch checks again, and either finds it genuinely clean by then (and sets
// the flag) or removes an entry that got resurrected. That converges, and it
// costs one extra check, on one extra launch, only for someone who had
// something to clean up.
//
// "Clean" here does NOT mean "no `fovea` key exists anywhere" — it means
// nothing Fovea would ever touch remains. A `fovea` entry present but not
// ours (someone's own server, hand-registered under the same name) counts as
// clean too, deliberately: it can never become ours to remove, so waiting for
// it to change would wait forever, and re-parsing it on every launch buys
// nothing. The per-function comments below spell this out as the third of
// three outcomes; a reader who stops at this header would otherwise come away
// with the narrower, wrong reading.
//
// Every check is by CONTENT, not by key name — reuses `ClientConfig.remove` /
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

        // Every target has to have been ALREADY clean for the flag to be set
        // — see the header comment. `&&` rather than early-exit: a config
        // that had something to remove must not stop us checking the others.
        var allAlreadyClean = true
        for (url, containerKey) in json {
            allAlreadyClean = cleanJSON(url: url, containerKey: containerKey) && allAlreadyClean
        }
        let toml = codexHome().appendingPathComponent("config.toml")
        allAlreadyClean = cleanTOML(url: toml) && allAlreadyClean

        if allAlreadyClean {
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
    /// Returns whether `url` was ALREADY clean going into this call — true
    /// only when there was nothing of ours to remove (no entry, or one that
    /// is not ours). Finding and removing an entry returns false even when
    /// the write is confirmed by reading it back: see the header comment for
    /// why a same-call read-back is not enough to trust it stays removed.
    private static func cleanJSON(url: URL, containerKey: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return true  // no file — nothing of ours can be in it
        }
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false  // exists but we can't parse it — can't confirm either way
        }
        let servers = document[containerKey] as? [String: Any]
        let entry = servers?["fovea"]

        // THREE OUTCOMES, spelled out rather than left to fall out of one
        // guard's else — collapsing "absent" and "present but not ours" into
        // one branch once already shipped a bug: it deleted the backup beside
        // a hand-registered `fovea` entry this app never touched.
        guard entry != nil else {
            // No `fovea` key at all — already clean. Any backup we left
            // beside this file is now an orphan: this could mean the user
            // pressed Disconnect back when 0.2.x still offered it, or that a
            // previous launch already did this removal. Either way the
            // backup goes; neither is held up by the flag rule above, which
            // is about the ENTRY, not about tidying a file that carries no
            // risk either way.
            removeBackup(beside: url)
            return true
        }
        guard looksLikeFoveaEntry(entry) else {
            // Something IS registered under `fovea`, but it does not look
            // like ours. Touch NOTHING — not the entry, not the backup beside
            // it, no log line. Counted as clean for flag purposes: there is
            // nothing here Fovea will ever remove, so waiting for it to
            // change would wait forever and cost a parse every launch.
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

        // Read it back — purely to log accurately. It does NOT gate the
        // return value: this pass found an entry, so it is not "already
        // clean" either way, and the flag stays unset regardless until a
        // later pass confirms it stuck.
        let verifyServers = readJSON(url)?[containerKey] as? [String: Any]
        if looksLikeFoveaEntry(verifyServers?["fovea"]) {
            Emit.log("wrote \(url.path), but the fovea MCP entry was still there on read-back")
        } else {
            Emit.log("removed the old fovea MCP entry from \(url.path)")
            removeBackup(beside: url)
        }
        return false
    }

    /// The Codex CLI equivalent, over `TomlConfig`'s line-range surgery rather
    /// than a real parser — same contract as `cleanJSON`.
    private static func cleanTOML(url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return true  // no file — nothing of ours can be in it
        }
        let table = TomlConfig.lines(of: "fovea", in: text)

        // Same three outcomes as `cleanJSON`, kept explicit for the same
        // reason — see the comment there.
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
    /// includes the user's `oauthAccount`). Only ever called once the entry
    /// is confirmed gone: right after a removal this call just made, or from
    /// the "no `fovea` key at all" branch, which covers both "user pressed
    /// Disconnect years ago" and "a previous launch already did this."
    /// NEVER called from the "present but not ours" branch — a hand-
    /// registered `fovea` entry means this backup is not ours to judge
    /// either. Only this exact name — never anything else found beside the
    /// config — and `try?`: a backup that fails to delete is not worth
    /// retrying for, unlike the entry itself.
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
