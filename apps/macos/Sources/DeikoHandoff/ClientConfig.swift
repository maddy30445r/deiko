import Foundation

/// Merging Deiko's entry into a coding client's MCP config, as pure logic.
///
/// **This edits a file another program owns.** `~/.claude.json` holds Claude
/// Code's OAuth account, machine id, per-project history and several caches
/// alongside `mcpServers`. There is no documented API for a third-party app to
/// register a server — the supported routes all assumed a human at a CLI — so
/// the write has to be conservative enough to be obviously harmless: read,
/// change exactly one key, put everything else back byte-for-byte.
///
/// Deiko writes exactly one key again — its own `deiko-memory` entry, under
/// `MemoryHelper`, on the user's click — and still never touches anything
/// else. (Between 0.2.1 and this, it wrote nothing at all; `LegacyMCP` is the
/// one-time cleanup for the entry an even older build left behind, under the
/// unrelated name `fovea`.)
///
/// Kept here, away from `FileManager`, so the merge and the removal can be
/// tested without a real config on disk. The file I/O around them (atomic
/// rename, backup, verify) lives in `MemoryHelper` and `LegacyMCP`, is a
/// handful of lines, and holds no decisions.
public enum ClientConfig {

    public enum MergeError: Error, Equatable {
        case notAnObject
        case mcpServersNotAnObject
    }

    /// Add or update one server entry inside an existing config document.
    ///
    /// - Parameters:
    ///   - existing: the parsed config, or nil when the file does not exist yet.
    ///   - serverKey: the name the server is registered under (`"deiko-memory"`).
    ///   - entry: the server definition to write.
    ///   - containerKey: which top-level key holds the servers. Claude Code and
    ///     most clients use `mcpServers`; VS Code's own MCP support uses
    ///     `servers`. A parameter rather than a constant because the difference
    ///     is one word and hard-coding it is how the second connector becomes a
    ///     copy of the first.
    ///
    /// Returns the merged document. Every key the caller did not ask about is
    /// carried across untouched — that is the property this function exists to
    /// guarantee, and the one the tests are about.
    public static func merge(
        into existing: [String: Any]?,
        serverKey: String,
        entry: [String: Any],
        containerKey: String = "mcpServers"
    ) throws -> [String: Any] {
        var document = existing ?? [:]

        // A missing container is normal — a config with no MCP servers yet.
        // A container of the WRONG SHAPE is not: something else wrote there, and
        // replacing it would destroy whatever that was.
        var servers: [String: Any]
        switch document[containerKey] {
        case nil:
            servers = [:]
        case let existing as [String: Any]:
            servers = existing
        default:
            throw MergeError.mcpServersNotAnObject
        }

        servers[serverKey] = entry
        document[containerKey] = servers
        return document
    }

    /// Remove one server entry, leaving everything else exactly as it was.
    ///
    /// The mirror of `merge`, and it has the same job: touch one key. A client
    /// the user disconnects must be left as though Deiko had never written —
    /// including the `mcpServers` object itself, which stays (possibly empty)
    /// rather than being deleted, because its absence and its emptiness are not
    /// the same thing to whoever wrote the file.
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

    /// Whether a config already registers this server with exactly this entry.
    ///
    /// Drives both "is it connected?" in the UI and the self-heal at launch.
    /// Compared by VALUE, not by presence: an entry pointing at a runtime or a
    /// server path that no longer exists — an app moved, a Node upgraded — is
    /// worse than no entry at all, because the client keeps trying to spawn it
    /// and the failure surfaces inside Claude Code rather than here.
    public static func isRegistered(
        in existing: [String: Any]?,
        serverKey: String,
        matching entry: [String: Any],
        containerKey: String = "mcpServers"
    ) -> Bool {
        guard let servers = existing?[containerKey] as? [String: Any],
              let found = servers[serverKey] as? [String: Any]
        else { return false }
        return NSDictionary(dictionary: found).isEqual(to: entry)
    }

    /// The stdio server entry Deiko registers.
    ///
    /// `command` is an absolute path to the runtime the APP resolved, never the
    /// bare word `node`. The client spawns this itself, with its own
    /// environment — on a Mac where Node lives under nvm, that process has no
    /// PATH that can find it, which is exactly how the helper would fail for
    /// someone who never opens a terminal.
    public static func stdioEntry(command: String, arguments: [String]) -> [String: Any] {
        ["type": "stdio", "command": command, "args": arguments, "env": [String: String]()]
    }
}
