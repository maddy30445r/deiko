import Foundation

/// Adding and removing Deiko's entry in Codex's TOML MCP config, as pure logic.
///
/// Codex keeps its servers in `~/.codex/config.toml` under
/// `[mcp_servers.<name>]`, in a file that also holds hand-written, commented
/// settings. So this is deliberately not a TOML parser: re-emitting the file
/// would reformat it and drop its comments. It finds our one table, replaces it
/// through to the next top-level header, or appends it, and never looks at
/// another byte.
///
/// Kept away from `FileManager` so the edit is testable against fixtures; the
/// same arrangement as `ClientConfig`.
public enum TomlConfig {

    /// Add or update `[mcp_servers.<serverKey>]`. Every line outside our
    /// table survives byte-for-byte, comments included.
    ///
    /// Returns nil for a file whose shape an appended table would break:
    /// `mcp_servers = { … }` (an inline table cannot be extended by a header
    /// later on) or our key already written in quotes (`[mcp_servers."x"]`,
    /// which we would not find and would then define twice). Both are rare,
    /// and both would stop Codex starting, so the caller leaves the file alone.
    public static func merge(
        into existing: String?,
        serverKey: String,
        command: String,
        arguments: [String]
    ) -> String? {
        let table = render(serverKey: serverKey, command: command, arguments: arguments)
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return table }

        for raw in existing.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("mcp_servers"),
               line.dropFirst("mcp_servers".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") { return nil }
            if line.contains("mcp_servers.\"\(serverKey)\"") || line.contains("mcp_servers.'\(serverKey)'") { return nil }
        }

        guard let range = tableRange(in: existing, serverKey: serverKey) else {
            // Exactly one blank line before it, so repeated runs do not grow
            // the gap.
            var trimmed = existing
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            return trimmed + "\n\n" + table
        }
        var lines = existing.components(separatedBy: "\n")
        lines.replaceSubrange(range, with: table.components(separatedBy: "\n").dropLast())
        return lines.joined(separator: "\n")
    }

    /// Whether the file already registers exactly this command and these
    /// arguments — by value, like `ClientConfig.isRegistered`, because an
    /// entry naming a runtime that moved is worse than none.
    public static func isRegistered(
        in existing: String?,
        serverKey: String,
        command: String,
        arguments: [String]
    ) -> Bool {
        guard let existing, let found = lines(of: serverKey, in: existing) else { return false }
        func meaningful(_ lines: [String]) -> [String] {
            lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let wanted = render(serverKey: serverKey, command: command, arguments: arguments)
        return meaningful(found) == meaningful(wanted.components(separatedBy: "\n"))
    }

    /// The table, with a trailing newline.
    static func render(serverKey: String, command: String, arguments: [String]) -> String {
        """
        [mcp_servers.\(serverKey)]
        command = \(quote(command))
        args = [\(arguments.map(quote).joined(separator: ", "))]

        """
    }

    /// TOML basic strings escape the same two characters JSON does; a macOS
    /// path can legally contain either.
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Strip `[mcp_servers.<serverKey>]` out again. Returns nil when it was not
    /// there, so the caller can skip a pointless write.
    public static func remove(from existing: String?, serverKey: String) -> String? {
        guard let existing, let range = tableRange(in: existing, serverKey: serverKey) else {
            return nil
        }
        var lines = existing.components(separatedBy: "\n")
        lines.removeSubrange(range)
        // A single leftover blank line is harmless, but a run of them would
        // accumulate over connect/disconnect cycles.
        while lines.count > 1, lines.last == "", lines[lines.count - 2] == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The raw lines of `[mcp_servers.<serverKey>]`, if it exists, for a caller
    /// that needs to inspect the table without this becoming a TOML parser.
    /// `LegacyMCP` uses it to check a table looks like one Deiko wrote before
    /// removing it.
    public static func lines(of serverKey: String, in existing: String) -> [String]? {
        guard let range = tableRange(in: existing, serverKey: serverKey) else { return nil }
        return Array(existing.components(separatedBy: "\n")[range])
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
            // Any new table header ends ours, except a sub-table such as
            // `[mcp_servers.<serverKey>.env]`: leaving one behind would orphan
            // it.
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
