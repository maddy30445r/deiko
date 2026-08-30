import Foundation

/// Removing Deiko's entry from a coding client's MCP config, as pure logic.
///
/// **This edits a file another program owns.** `~/.claude.json` holds Claude
/// Code's OAuth account, machine id, per-project history and several caches
/// alongside `mcpServers`. There is no documented API for a third-party app to
/// register a server — the supported routes all assumed a human at a CLI — so
/// the write has to be conservative enough to be obviously harmless: read,
/// change exactly one key, put everything else back byte-for-byte.
///
/// Kept here, away from `FileManager`, so the removal can be tested without a
/// real config on disk. The file I/O around it lives in `LegacyMCP`, is a
/// handful of lines, and holds no decisions.
public enum ClientConfig {

    /// Remove one server entry, leaving everything else exactly as it was.
    ///
    /// The only surviving operation from when Deiko also wrote this key — see
    /// `LegacyMCP`. A client that had it removed must be left as though Deiko
    /// had never written — including the `mcpServers` object itself, which
    /// stays (possibly empty) rather than being deleted, because its absence
    /// and its emptiness are not the same thing to whoever wrote the file.
    ///
    /// Returns nil when there was nothing to remove, so the caller can skip the
    /// write entirely rather than rewriting a file it did not change.
    public static func remove(
        from existing: [String: Any]?,
        serverKey: String,
        containerKey: String = "mcpServers"
    ) -> [String: Any]? {
        guard var document = existing,
              var servers = document[containerKey] as? [String: Any],
              servers[serverKey] != nil
        else { return nil }

        servers.removeValue(forKey: serverKey)
        document[containerKey] = servers
        return document
    }
}
