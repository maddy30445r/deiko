import Foundation

/// Merging Fovea into a coding client's TOML MCP config, as pure logic.
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

    /// Add or update `[mcp_servers.<serverKey>]` in an existing document.
    ///
    /// - Parameters:
    ///   - existing: the file's text, or nil when it does not exist yet.
    ///   - serverKey: the name the server is registered under (`"fovea"`).
    ///   - command: absolute path to the runtime.
    ///   - arguments: the server's arguments.
    ///
    /// Every line outside our table survives byte-for-byte, comments included.
    public static func merge(
        into existing: String?,
        serverKey: String,
        command: String,
        arguments: [String]
    ) -> String {
        let table = render(serverKey: serverKey, command: command, arguments: arguments)
        guard let existing, !existing.isEmpty else { return table }

        guard let range = tableRange(in: existing, serverKey: serverKey) else {
            // Appended, with exactly one blank line before it — enough to
            // separate our table from whatever precedes it, not enough to keep
            // growing the gap every time this runs.
            let trimmed = existing.hasSuffix("\n") ? String(existing.dropLast()) : existing
            return trimmed + "\n\n" + table
        }

        var lines = existing.components(separatedBy: "\n")
        lines.replaceSubrange(range, with: table.components(separatedBy: "\n").dropLast())
        return lines.joined(separator: "\n")
    }

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

    /// Whether the config already registers this server with exactly this
    /// command and arguments.
    ///
    /// Compared by value like `ClientConfig.isRegistered`, and for the same
    /// reason: an entry pointing at a runtime that no longer exists is worse
    /// than no entry, because the client keeps trying to spawn it and the
    /// failure surfaces inside Codex rather than here.
    public static func isRegistered(
        in existing: String?,
        serverKey: String,
        command: String,
        arguments: [String]
    ) -> Bool {
        guard let existing, let range = tableRange(in: existing, serverKey: serverKey) else {
            return false
        }
        let found = existing.components(separatedBy: "\n")[range]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let wanted = render(serverKey: serverKey, command: command, arguments: arguments)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return found == wanted
    }

    // ── Mechanics ───────────────────────────────────────────────────────────

    /// The table, with a trailing newline.
    static func render(serverKey: String, command: String, arguments: [String]) -> String {
        let args = arguments.map(quote).joined(separator: ", ")
        return """
            [mcp_servers.\(serverKey)]
            command = \(quote(command))
            args = [\(args)]

            """
    }

    /// TOML basic strings escape the same two characters JSON does; a macOS
    /// path can legally contain either.
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

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
