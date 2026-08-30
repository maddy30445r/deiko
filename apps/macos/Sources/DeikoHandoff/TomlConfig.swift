import Foundation

/// Removing Deiko's entry from Codex CLI's TOML MCP config, as pure logic.
///
/// Codex CLI is the odd one out: every other client here keeps its MCP servers
/// in JSON, and Codex keeps them in `~/.codex/config.toml` under
/// `[mcp_servers.<name>]`. The rule does not change — **read, change exactly
/// one thing, put everything else back** — but the mechanics do, because that
/// file also holds the user's model choice, approval policy, sandbox settings
/// and profiles, all of it hand-written and often commented.
///
/// So this is deliberately NOT a TOML parser. Parsing and re-emitting would
/// reformat a file somebody maintains by hand and throw away every comment in
/// it. Instead it finds our one table, replaces it through to the next
/// top-level table header, or appends it — and never looks at another byte.
///
/// Kept here, away from `FileManager`, so the edit can be tested against
/// fixtures without a real config on disk — the same arrangement as
/// `ClientConfig`.
public enum TomlConfig {

    /// Strip `[mcp_servers.<serverKey>]` out again. Returns nil when it was not
    /// there, so the caller can skip a pointless write.
    public static func remove(from existing: String?, serverKey: String) -> String? {
        guard let existing, let range = tableRange(in: existing, serverKey: serverKey) else {
            return nil
        }
        var lines = existing.components(separatedBy: "\n")
        lines.removeSubrange(range)
        // A trailing blank line left where the table was is untidy but
        // harmless; a run of them is not, and disconnect/connect cycles would
        // accumulate them.
        while lines.count > 1, lines.last == "", lines[lines.count - 2] == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The raw lines of `[mcp_servers.<serverKey>]`, if it exists — for a
    /// caller that needs to look at what is actually IN the table before
    /// deciding whether to touch it, without this becoming a TOML parser.
    /// `LegacyMCP` uses this to check the table looks like one Deiko itself
    /// wrote before removing it; nobody else needs to see inside a table this
    /// file itself never interprets.
    public static func lines(of serverKey: String, in existing: String) -> [String]? {
        guard let range = tableRange(in: existing, serverKey: serverKey) else { return nil }
        return Array(existing.components(separatedBy: "\n")[range])
    }

    // ── Mechanics ───────────────────────────────────────────────────────────

    /// The line range our table occupies: its header, through to the line
    /// before the next top-level `[` — which is how TOML delimits tables.
    private static func tableRange(in text: String, serverKey: String) -> Range<Int>? {
        let lines = text.components(separatedBy: "\n")
        let header = "[mcp_servers.\(serverKey)]"
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else { return nil }

        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            // Any new table header ends ours — including
            // `[mcp_servers.fovea.env]`, which belongs to us but which we never
            // write, so leaving it behind would leave a fragment of a table
            // whose parent is gone.
            if trimmed.hasPrefix("["), !trimmed.hasPrefix("[mcp_servers.\(serverKey).") { break }
            if trimmed.hasPrefix("[mcp_servers.\(serverKey).") { end += 1; continue }
            end += 1
        }
        // Trailing blank lines belong to the separation between tables, not to
        // ours — except the one immediately after, which we wrote.
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return start..<end
    }
}
