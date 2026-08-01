import Foundation
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// CONNECTING FOVEA TO A CODING CLIENT
//
// The bridge only reaches an agent if that agent knows the bridge exists, and
// every client keeps that knowledge somewhere different. There is no documented
// way for a third-party app to register an MCP server — the supported routes all
// assume a human at a CLI — so this writes the client's config file, which is
// what JetBrains Rider's "Auto-Configure" does for the same set of clients.
//
// The merge itself lives in `FoveaHandoff.ClientConfig`, tested without a
// filesystem. What is left here is I/O: read, merge, write atomically, verify.
//
// ADDING A CLIENT is a new conformance, and the protocol is deliberately shaped
// so the next one is not forced into this one's assumptions. Codex keeps its
// servers in TOML (`~/.codex/config.toml`, `[mcp_servers.fovea]`) — hence
// `connect()` rather than a shared JSON writer, and hence `commandForm` rather
// than a lookup table someone has to remember to extend.
// ─────────────────────────────────────────────────────────────────────────────

/// `Sendable` because the registry below is a global. Every conformance is a
/// stateless struct that derives everything it knows from the filesystem, so
/// there is nothing to share — the constraint documents that rather than
/// restricting anything.
protocol Connector: Sendable {
    /// What the Settings row calls it.
    var name: String { get }

    /// Whether this client appears to be on the machine at all. A row for
    /// something nobody has installed is noise.
    var isInstalled: Bool { get }

    /// Whether Fovea is registered, pointing at THIS app's runtime and bridge.
    var isConnected: Bool { get }

    /// Register Fovea. Idempotent — connecting an already-connected client is a
    /// no-op, which is what makes the launch-time self-heal safe to run always.
    func connect() throws

    /// Unregister Fovea, leaving the client's config as if we had never
    /// written. Also idempotent.
    func disconnect() throws

    /// How this client spells a slash command for an MCP prompt.
    ///
    /// Owning this here is the point of the whole abstraction. `Handoff` used to
    /// GUESS the form from the target window's bundle id against a list of
    /// terminal bundle ids — and a wrong guess is silent, because Claude Code
    /// will not submit an unresolved slash command, so the text just sits in the
    /// input looking like a broken keystroke. A client the user has explicitly
    /// connected can be asked instead of guessed at.
    var commandForm: String { get }

    /// Bundle ids of the apps that host this client, so a fling landing on one
    /// of them can be matched back to a connector.
    var hostBundleIDs: Set<String> { get }
}

enum ConnectorError: LocalizedError {
    case nodeNotFound
    case bridgeNotFound
    case configUnreadable(String)
    case configWrongShape(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            return "Could not find Node on this Mac, so there is no runtime to point the client at."
        case .bridgeNotFound:
            return "Could not find Fovea's bridge server inside the app bundle."
        case .configUnreadable(let path):
            return "\(path) exists but could not be read as JSON. Fovea will not overwrite a file it cannot parse."
        case .configWrongShape(let path):
            return "\(path) has an mcpServers entry of an unexpected shape. Fovea left it alone."
        case .verificationFailed(let path):
            return "Wrote \(path), but reading it back did not show Fovea registered."
        }
    }
}

// ── One implementation for every JSON client ────────────────────────────────

/// Registers Fovea in a client whose MCP config is a JSON document.
///
/// Claude Code, Cursor and Antigravity differ in four things — where the file
/// is, what the container key is called, how you tell the client is installed,
/// and how it spells a command — and in nothing else. The careful part (read,
/// merge one key, back up once, write atomically, read it back) is identical,
/// and identical code copied three times is three places for the next fix to
/// be applied twice.
struct JSONMCPConnector: Connector {
    let name: String
    let commandForm: String
    let hostBundleIDs: Set<String>

    /// Which top-level key holds the servers. `mcpServers` for almost
    /// everything; VS Code's own MCP support uses `servers`.
    let containerKey: String

    /// A closure, not a URL: Claude Code honours `CLAUDE_CONFIG_DIR`, so the
    /// answer depends on the environment at the moment it is asked.
    let configURL: @Sendable () -> URL

    /// Any filesystem sign the client is on this Mac. Only ever DIMS a row —
    /// it must never block connecting, because being wrong should not stop
    /// somebody who knows better than we do.
    let isInstalled: Bool

    private var serverKey: String { "fovea" }

    var isConnected: Bool {
        guard let entry = try? desiredEntry() else { return false }
        return ClientConfig.isRegistered(
            in: read(), serverKey: serverKey, matching: entry, containerKey: containerKey
        )
    }

    func connect() throws {
        let url = configURL()
        let entry = try desiredEntry()
        let existing = read()
        if ClientConfig.isRegistered(
            in: existing, serverKey: serverKey, matching: entry, containerKey: containerKey
        ) { return }

        // A file that exists but will not parse is a file we do not understand.
        // Overwriting it would replace the client's own account, project
        // history and caches with a document containing only our one key.
        if existing == nil, FileManager.default.fileExists(atPath: url.path) {
            throw ConnectorError.configUnreadable(url.path)
        }

        let merged: [String: Any]
        do {
            merged = try ClientConfig.merge(
                into: existing, serverKey: serverKey, entry: entry, containerKey: containerKey
            )
        } catch {
            throw ConnectorError.configWrongShape(url.path)
        }

        try backupOnce(existing: existing)
        try writeAtomically(merged)

        // Read it back. An atomic rename that reported success but produced a
        // file the client cannot use is exactly the failure this whole feature
        // exists to avoid, and it costs one read to rule out.
        guard ClientConfig.isRegistered(
            in: read(), serverKey: serverKey, matching: entry, containerKey: containerKey
        ) else {
            throw ConnectorError.verificationFailed(url.path)
        }
    }

    func disconnect() throws {
        guard let stripped = ClientConfig.remove(
            from: read(), serverKey: serverKey, containerKey: containerKey
        ) else {
            return  // nothing registered; nothing to write
        }
        try writeAtomically(stripped)
    }

    // ── I/O ─────────────────────────────────────────────────────────────────

    private func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL()) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One backup, the first time Fovea ever writes. Not per-write: the point is
    /// to preserve the state from before this app touched the file, and a
    /// backup refreshed on every connect would eventually be a copy of our own
    /// last write.
    private func backupOnce(existing: [String: Any]?) throws {
        guard existing != nil else { return }
        let url = configURL()
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).before-fovea")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Write to a temporary file, then rename over the original.
    ///
    /// `rename` is atomic, so a reader either sees the whole old file or the
    /// whole new one — never a half-written config. These clients rewrite their
    /// own files on their own schedule and nothing here can lock against that;
    /// what atomicity buys is that a collision costs our ENTRY, not their FILE.
    /// A lost entry is repaired at next launch by `Connectors.selfHeal()`.
    private func writeAtomically(_ document: [String: Any]) throws {
        // `withoutEscapingSlashes` because this file gets read by humans when
        // something is wrong, and `\/Users\/...` in every path is noise in the
        // one moment somebody is trying to see what happened. `sortedKeys` so
        // repeated connects produce a byte-identical file rather than a
        // spurious diff.
        //
        // Key ORDER changes regardless — round-tripping through
        // JSONSerialization reorders, since JSON objects are unordered and
        // `NSDictionary` has no insertion order to preserve. Verified against a
        // copy of a real `~/.claude.json` that only the content of `mcpServers`
        // differs after a write; `oauthAccount`, `projects`, `machineID` and
        // every cache survive intact.
        let url = configURL()
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let directory = url.deletingLastPathComponent()
        // Cursor and Antigravity may have a config directory that does not
        // exist yet — Claude Code's is always `~`, so this never came up.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temp = directory.appendingPathComponent(".fovea-\(UUID().uuidString).json")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            // `replaceItemAt` keeps the original's permissions and ownership
            // rather than giving the client's config whatever the temp file
            // happened to have.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    // ── The entry ───────────────────────────────────────────────────────────

    private func desiredEntry() throws -> [String: Any] {
        ClientConfig.stdioEntry(command: try MCPEntry.node(), arguments: [try MCPEntry.bridge()])
    }
}

/// Absolute paths to THIS app's runtime and bridge — the same answer for every
/// client, so it is worked out once.
///
/// Absolute, and never the bare word `node`: the client spawns this itself with
/// its own environment, and on a Mac where Node lives under nvm that process
/// has no PATH that finds it. Pointing at the app's own copy also means moving
/// Fovea to the Bin invalidates the entry rather than leaving the client
/// spawning something that is no longer there.
enum MCPEntry {
    static func node() throws -> String {
        guard let node = NodeRuntime.resolve() else { throw ConnectorError.nodeNotFound }
        return node.path
    }

    /// The bridge inside the bundle, or — in a checkout — the one in the repo,
    /// mirroring how `Layout` resolves the pipeline.
    static func bridge() throws -> String {
        let fm = FileManager.default
        let root: URL
        switch Layout.resolve() {
        case .bundled(let resources): root = resources
        case .development(let repo): root = repo
        case nil: throw ConnectorError.bridgeNotFound
        }
        let path = root.appendingPathComponent("apps/bridge/src/server.mjs").path
        guard fm.fileExists(atPath: path) else { throw ConnectorError.bridgeNotFound }
        return path
    }

    /// What to type at a client that does NOT expose MCP prompts as slash
    /// commands.
    ///
    /// Getting this wrong is silent: an unresolved slash command is not
    /// submitted, so the text just sits in the input looking like a broken
    /// keystroke — which has already cost this project one debugging session.
    /// Claude Code is the only client here known to turn MCP prompts into
    /// commands. The rest are tool-first, so they are asked in words, which
    /// works whether or not they ever add prompt support.
    static let toolSentence = "Fetch the latest Fovea brief with the fovea get_brief tool"
}

// ── The clients ─────────────────────────────────────────────────────────────

extension JSONMCPConnector {

    /// `~/.claude.json` is where **both** the CLI and the VS Code extension
    /// read user-scoped MCP servers from. (VS Code's own `mcp.json` is a
    /// different, unrelated feature; Claude Code neither reads nor writes it.)
    static var claudeCode: JSONMCPConnector {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fm = FileManager.default
        // Three signals rather than one, because each alone has a false
        // negative: the config file does not exist until Claude Code first
        // writes it, `~/.claude` belongs to the CLI, and someone may only ever
        // have used the VS Code extension.
        let installed =
            fm.fileExists(atPath: configPathForClaude().path)
            || fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
            || ((try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".vscode/extensions").path)) ?? [])
                .contains { $0.hasPrefix("anthropic.claude-code") }

        return JSONMCPConnector(
            name: "Claude Code",
            commandForm: "/fovea:brief",
            hostBundleIDs: [
                "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
                "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                "dev.warp.Warp-Stable", "io.alacritty", "net.kovidgoyal.kitty",
            ],
            containerKey: "mcpServers",
            configURL: { configPathForClaude() },
            isInstalled: installed
        )
    }

    /// Claude Code honours `CLAUDE_CONFIG_DIR`; respecting it costs one line and
    /// is the difference between working and silently writing to a file nobody
    /// reads.
    private static func configPathForClaude() -> URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return dir.appendingPathComponent(".claude.json")
    }

    static var cursor: JSONMCPConnector {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fm = FileManager.default
        return JSONMCPConnector(
            name: "Cursor",
            commandForm: MCPEntry.toolSentence,
            hostBundleIDs: ["com.todesktop.230313mzl4w4u92"],
            containerKey: "mcpServers",
            configURL: { home.appendingPathComponent(".cursor/mcp.json") },
            isInstalled: fm.fileExists(atPath: home.appendingPathComponent(".cursor").path)
                || fm.fileExists(atPath: "/Applications/Cursor.app")
        )
    }

    /// Antigravity, Antigravity CLI and the IDE share
    /// `~/.gemini/config/mcp_config.json` (per Google's own MCP docs).
    static var antigravity: JSONMCPConnector {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fm = FileManager.default
        return JSONMCPConnector(
            name: "Antigravity",
            commandForm: MCPEntry.toolSentence,
            // Unverified: Antigravity is not installed on the machine this was
            // written on, so a fling landing on it will fall back to the
            // generic command form rather than being matched here.
            hostBundleIDs: ["com.google.antigravity"],
            containerKey: "mcpServers",
            configURL: { home.appendingPathComponent(".gemini/config/mcp_config.json") },
            isInstalled: fm.fileExists(atPath: home.appendingPathComponent(".gemini").path)
                || fm.fileExists(atPath: "/Applications/Antigravity.app")
        )
    }
}

// ── Codex CLI: the same job, in TOML ────────────────────────────────────────

/// Registers Fovea in `~/.codex/config.toml`.
///
/// Its own type rather than a `JSONMCPConnector` instance because the file is
/// not JSON: Codex keeps MCP servers under `[mcp_servers.<name>]` in a TOML
/// document that also holds the user's model, approval policy and profiles,
/// hand-written and commented. `TomlConfig` does the surgical edit; everything
/// here is the file I/O around it.
struct CodexConnector: Connector {
    let name = "Codex CLI"
    let commandForm = MCPEntry.toolSentence

    /// Empty, deliberately. Codex runs inside a terminal, and every terminal
    /// bundle id is already claimed by Claude Code — `Connectors.matching`
    /// returns the first match, so listing them here would make which client a
    /// fling resolves to depend on array order. A terminal stays Claude Code's
    /// by default; a Codex user types the sentence themselves.
    let hostBundleIDs: Set<String> = []

    private let serverKey = "fovea"

    private var configURL: URL {
        // `CODEX_HOME` moves the whole directory, and Codex honours it.
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return dir.appendingPathComponent("config.toml")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }

    var isConnected: Bool {
        guard let node = try? MCPEntry.node(), let bridge = try? MCPEntry.bridge() else {
            return false
        }
        return TomlConfig.isRegistered(
            in: read(), serverKey: serverKey, command: node, arguments: [bridge]
        )
    }

    func connect() throws {
        let node = try MCPEntry.node()
        let bridge = try MCPEntry.bridge()
        let existing = read()
        if TomlConfig.isRegistered(
            in: existing, serverKey: serverKey, command: node, arguments: [bridge]
        ) { return }

        let merged = TomlConfig.merge(
            into: existing, serverKey: serverKey, command: node, arguments: [bridge]
        )
        try backupOnce(existing: existing)
        try writeAtomically(merged)

        guard TomlConfig.isRegistered(
            in: read(), serverKey: serverKey, command: node, arguments: [bridge]
        ) else {
            throw ConnectorError.verificationFailed(configURL.path)
        }
    }

    func disconnect() throws {
        guard let stripped = TomlConfig.remove(from: read(), serverKey: serverKey) else { return }
        try writeAtomically(stripped)
    }

    // ── I/O ─────────────────────────────────────────────────────────────────

    private func read() -> String? {
        try? String(contentsOf: configURL, encoding: .utf8)
    }

    private func backupOnce(existing: String?) throws {
        guard existing != nil else { return }
        let backup = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.before-fovea")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: configURL, to: backup)
    }

    private func writeAtomically(_ text: String) throws {
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temp = directory.appendingPathComponent(".fovea-\(UUID().uuidString).toml")
        try Data(text.utf8).write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: configURL)
        }
    }
}
// ── The registry ────────────────────────────────────────────────────────────

enum Connectors {
    /// Order matters in one place: `matching(bundleID:)` returns the first
    /// connector claiming a bundle id, and Claude Code claims the terminals.
    static let all: [Connector] = [
        JSONMCPConnector.claudeCode,
        JSONMCPConnector.cursor,
        JSONMCPConnector.antigravity,
        CodexConnector(),
    ]

    /// Which clients the user has asked Fovea to connect.
    ///
    /// An explicit record, because the alternative — inferring consent from the
    /// backup file — is wrong for anyone whose config did not exist yet:
    /// `backupOnce` has nothing to copy, leaves no marker, and their connection
    /// would never be repaired.
    private static let optedInKey = "connectedClients"

    private static var optedIn: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: optedInKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: optedInKey) }
    }

    /// Connect, and remember that the user wanted it.
    static func connect(_ connector: Connector) throws {
        try connector.connect()
        optedIn.insert(connector.name)
    }

    /// Unregister, and stop putting it back.
    ///
    /// Forgetting FIRST, so a disconnect that throws halfway still leaves
    /// self-heal disarmed. The other order would let the next launch quietly
    /// reconnect a client the user had just asked to be rid of — the one
    /// outcome a disconnect button must never produce.
    static func disconnect(_ connector: Connector) throws {
        optedIn.remove(connector.name)
        try connector.disconnect()
    }

    /// Re-register anything the user connected that is no longer registered.
    ///
    /// Claude Code owns `~/.claude.json` and rewrites it wholesale; a rewrite
    /// landing between our read and our rename drops the entry. Rather than
    /// fight for a lock we do not have, notice at launch and put it back.
    ///
    /// Also repairs the ordinary case of the app being MOVED: the entry points
    /// at absolute paths inside the bundle, so dragging Fovea to /Applications
    /// leaves the client spawning a bridge that is not there. `isConnected`
    /// compares by value, so that reads as disconnected and is fixed here.
    ///
    /// Only clients the user opted into — this never adds Fovea to a client
    /// they never asked about.
    static func selfHeal() {
        let wanted = optedIn
        for connector in all
        where wanted.contains(connector.name) && connector.isInstalled && !connector.isConnected {
            try? connector.connect()
        }
    }

    /// The connector whose host apps include this bundle id, if any.
    static func matching(bundleID: String?) -> Connector? {
        guard let bundleID else { return nil }
        return all.first { $0.hostBundleIDs.contains(bundleID) }
    }
}
