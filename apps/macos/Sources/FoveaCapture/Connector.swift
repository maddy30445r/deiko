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

// ── Claude Code ─────────────────────────────────────────────────────────────

/// Registers Fovea in `~/.claude.json`, which is where **both** the CLI and the
/// VS Code extension read user-scoped MCP servers from. (VS Code's own
/// `mcp.json` is a different, unrelated feature; Claude Code neither reads nor
/// writes it.)
struct ClaudeCodeConnector: Connector {

    let name = "Claude Code"
    let commandForm = "/fovea:brief"
    let hostBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "io.alacritty", "net.kovidgoyal.kitty",
    ]

    /// The server key, and the file it goes in.
    private let serverKey = "fovea"
    private var configURL: URL {
        // Claude Code honours CLAUDE_CONFIG_DIR; respecting it costs one line
        // and is the difference between working and silently writing to a file
        // nobody reads.
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return dir.appendingPathComponent(".claude.json")
    }

    /// Any sign of Claude Code on this Mac.
    ///
    /// Three signals rather than one, because each alone has a false negative:
    /// the config file does not exist until Claude Code first writes it, the
    /// `~/.claude` directory belongs to the CLI, and someone may only ever have
    /// used the VS Code extension. Missing all three is a good bet the client
    /// is not here — but this only ever DIMS a row, it does not block
    /// connecting, because being wrong should not stop somebody who knows
    /// better than we do.
    var isInstalled: Bool {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if fm.fileExists(atPath: configURL.path) { return true }
        if fm.fileExists(atPath: home.appendingPathComponent(".claude").path) { return true }
        let extensions = home.appendingPathComponent(".vscode/extensions")
        let installed = (try? fm.contentsOfDirectory(atPath: extensions.path)) ?? []
        return installed.contains { $0.hasPrefix("anthropic.claude-code") }
    }

    var isConnected: Bool {
        guard let entry = try? desiredEntry() else { return false }
        return ClientConfig.isRegistered(in: read(), serverKey: serverKey, matching: entry)
    }

    func connect() throws {
        let entry = try desiredEntry()
        let existing = read()
        if ClientConfig.isRegistered(in: existing, serverKey: serverKey, matching: entry) { return }

        // A file that exists but will not parse is a file we do not understand.
        // Overwriting it would replace Claude Code's account, project history
        // and caches with a document containing only our one key.
        if existing == nil, FileManager.default.fileExists(atPath: configURL.path) {
            throw ConnectorError.configUnreadable(configURL.path)
        }

        let merged: [String: Any]
        do {
            merged = try ClientConfig.merge(into: existing, serverKey: serverKey, entry: entry)
        } catch {
            throw ConnectorError.configWrongShape(configURL.path)
        }

        try backupOnce(existing: existing)
        try writeAtomically(merged)

        // Read it back. An atomic rename that reported success but produced a
        // file the client cannot use is exactly the failure this whole feature
        // exists to avoid, and it costs one read to rule out.
        guard ClientConfig.isRegistered(in: read(), serverKey: serverKey, matching: entry) else {
            throw ConnectorError.verificationFailed(configURL.path)
        }
    }

    func disconnect() throws {
        guard let stripped = ClientConfig.remove(from: read(), serverKey: serverKey) else {
            return  // nothing registered; nothing to write
        }
        try writeAtomically(stripped)
    }

    // ── The entry ───────────────────────────────────────────────────────────

    /// Absolute paths to THIS app's runtime and bridge.
    ///
    /// Absolute, and never the bare word `node`: the client spawns this itself
    /// with its own environment, and on a Mac where Node lives under nvm that
    /// process has no PATH that finds it. Pointing at the app's own copy also
    /// means moving Fovea to the Bin invalidates the entry rather than leaving
    /// the client spawning something that is no longer there.
    private func desiredEntry() throws -> [String: Any] {
        guard let node = NodeRuntime.resolve() else { throw ConnectorError.nodeNotFound }
        guard let bridge = bridgeServerPath() else { throw ConnectorError.bridgeNotFound }
        return ClientConfig.stdioEntry(command: node.path, arguments: [bridge])
    }

    /// The bridge inside the bundle, or — in a checkout — the one in the repo,
    /// mirroring how `Layout` resolves the pipeline.
    private func bridgeServerPath() -> String? {
        let fm = FileManager.default
        switch Layout.resolve() {
        case .bundled(let resources):
            let path = resources.appendingPathComponent("apps/bridge/src/server.mjs").path
            return fm.fileExists(atPath: path) ? path : nil
        case .development(let repo):
            let path = repo.appendingPathComponent("apps/bridge/src/server.mjs").path
            return fm.fileExists(atPath: path) ? path : nil
        case nil:
            return nil
        }
    }

    // ── I/O ─────────────────────────────────────────────────────────────────

    private func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One backup, the first time Fovea ever writes. Not per-write: the point is
    /// to preserve the state from before this app touched the file, and a
    /// backup refreshed on every connect would eventually be a copy of our own
    /// last write.
    private func backupOnce(existing: [String: Any]?) throws {
        guard existing != nil else { return }
        let backup = configURL.deletingLastPathComponent()
            .appendingPathComponent(".claude.json.before-fovea")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: configURL, to: backup)
    }

    /// Write to a temporary file, then rename over the original.
    ///
    /// `rename` is atomic, so a reader either sees the whole old file or the
    /// whole new one — never a half-written config. Claude Code rewrites this
    /// file on its own schedule and nothing here can lock it against that; what
    /// atomicity buys is that a collision costs our ENTRY, not their FILE. A
    /// lost entry is repaired at next launch by `Connectors.selfHeal()`.
    private func writeAtomically(_ document: [String: Any]) throws {
        // `withoutEscapingSlashes` because this file gets read by humans when
        // something is wrong, and `\/Users\/...` in every path is noise in the
        // one moment somebody is trying to see what happened. `sortedKeys` so
        // repeated connects produce a byte-identical file rather than a
        // spurious diff.
        //
        // Key ORDER changes regardless — round-tripping through
        // JSONSerialization reorders, since JSON objects are unordered and
        // `NSDictionary` has no insertion order to preserve. Verified that only
        // the content of `mcpServers` differs after a write; `oauthAccount`,
        // `projects`, `machineID` and every cache survive intact.
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let temp = configURL.deletingLastPathComponent()
            .appendingPathComponent(".claude.json.fovea-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        // `replaceItemAt` keeps the original's permissions and ownership rather
        // than giving Claude Code's config whatever the temp file happened to
        // have.
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temp)
    }
}

// ── The registry ────────────────────────────────────────────────────────────

enum Connectors {
    static let all: [Connector] = [ClaudeCodeConnector()]

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
