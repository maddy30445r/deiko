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
// Once, guarded by a flag, and then this file can go. It reuses the two removal
// functions from the connector layer rather than reimplementing them: those are
// the tested ones, and this is not the place to have a second opinion about
// what an entry looks like.
// ─────────────────────────────────────────────────────────────────────────────

enum LegacyMCP {
    private static let doneKey = "legacyMCPCleaned"

    static func cleanUpOnce() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        // Set FIRST. A cleanup that throws halfway must not retry on every
        // launch forever — the entry it could not remove will not become
        // removable, and the user does not need the log line every time.
        UserDefaults.standard.set(true, forKey: doneKey)

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let json: [(URL, String)] = [
            (configPathForClaude(), "mcpServers"),
            (home.appendingPathComponent(".cursor/mcp.json"), "mcpServers"),
            (home.appendingPathComponent(".gemini/config/mcp_config.json"), "mcpServers"),
        ]
        for (url, containerKey) in json {
            guard let data = try? Data(contentsOf: url),
                  let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let stripped = ClientConfig.remove(
                      from: document, serverKey: "fovea", containerKey: containerKey
                  ),
                  let out = try? JSONSerialization.data(
                      withJSONObject: stripped,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  )
            else { continue }
            try? out.write(to: url, options: .atomic)
            Emit.log("removed the old fovea MCP entry from \(url.path)")
        }

        let toml = codexHome().appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: toml, encoding: .utf8),
           let stripped = TomlConfig.remove(from: text, serverKey: "fovea") {
            try? Data(stripped.utf8).write(to: toml, options: .atomic)
            Emit.log("removed the old fovea MCP entry from \(toml.path)")
        }
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
