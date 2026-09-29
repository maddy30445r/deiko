import Foundation
import Testing
@testable import DeikoHandoff

// The whole connect / disconnect path, against a throwaway HOME: every path
// below lives under a fresh temp directory, never a real config.

private let node = "/opt/deiko/node"
private let script = "/Users/dev/personal /Deiko/packages/core/src/memory-mcp.mjs"

private struct Home {
    let root: URL
    let apps: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deiko-home-\(UUID().uuidString)")
        apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url(path), atomically: false, encoding: .utf8)
    }
    func read(_ path: String) -> String { (try? String(contentsOf: url(path), encoding: .utf8)) ?? "MISSING" }
    func json(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url(path)))) as? [String: Any] ?? [:]
    }
    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url(path).path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    func targets() -> [AgentTarget] { AgentSetup.detect(home: root, environment: [:], applications: apps) }
}

/// A Mac with every supported agent on it, each config holding something that
/// must survive.
private func everyAgent() throws -> Home {
    let home = try Home()
    try home.write(".claude.json", #"{"oauthAccount":{"id":"a"},"mcpServers":{"playwright":{"command":"npx"}}}"#)
    try home.write(".codex/config.toml", "# mine\nmodel = \"o3\"\n\n[mcp_servers.playwright]\ncommand = \"npx\"\n")
    try FileManager.default.createDirectory(at: home.url(".cursor"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.apps.appendingPathComponent("Antigravity.app"), withIntermediateDirectories: true)
    try home.write(".gemini/settings.json", #"{"security":{"auth":{"selectedType":"oauth"}}}"#)
    try home.write("Library/Application Support/Code/User/mcp.json", #"{"inputs":[],"servers":{"gh":{"type":"http","url":"https://x"}}}"#)
    return home
}

@Test("nothing installed, nothing found")
func detectsNothing() throws {
    let home = try Home()
    // A leftover `~/.gemini/config` does not mean Antigravity is installed.
    try home.write(".gemini/config/mcp_config.json", #"{"mcpServers":{}}"#)
    #expect(home.targets().isEmpty)
}

@Test("each agent is found by its own folder, file or app")
func detectsEachAgent() throws {
    let names = try everyAgent().targets().map(\.name)
    #expect(names == ["Claude Code", "Codex", "Cursor", "Antigravity", "Gemini CLI", "VS Code"])
}

@Test("one click sets up every agent, each in its own format, and keeps what was there")
func connectsEveryFormat() throws {
    let home = try everyAgent()
    let outcome = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    #expect(outcome.failed.isEmpty)
    #expect(outcome.done.count == 6)

    let claude = home.json(".claude.json")
    #expect((claude["oauthAccount"] as? [String: Any])?["id"] as? String == "a")
    let claudeServers = claude["mcpServers"] as? [String: Any] ?? [:]
    #expect(claudeServers["playwright"] != nil)
    #expect((claudeServers["deiko-memory"] as? [String: Any])?["type"] as? String == "stdio")

    let codex = home.read(".codex/config.toml")
    #expect(codex.hasPrefix("# mine\nmodel = \"o3\"\n\n[mcp_servers.playwright]\ncommand = \"npx\"\n"))
    #expect(codex.contains("[mcp_servers.deiko-memory]\ncommand = \"/opt/deiko/node\"\nargs = [\"\(script)\"]"))

    let cursor = home.json(".cursor/mcp.json")["mcpServers"] as? [String: Any]
    #expect(cursor?["deiko-memory"] != nil)

    let antigravity = (home.json(".gemini/config/mcp_config.json")["mcpServers"] as? [String: Any])?["deiko-memory"] as? [String: Any]
    #expect(antigravity?["type"] == nil, "Antigravity documents no `type` key")
    #expect(antigravity?["args"] as? [String] == [script])

    let gemini = home.json(".gemini/settings.json")
    #expect(gemini["security"] != nil)
    #expect((gemini["mcpServers"] as? [String: Any])?["deiko-memory"] != nil)

    let vscode = home.json("Library/Application Support/Code/User/mcp.json")
    let servers = vscode["servers"] as? [String: Any] ?? [:]
    #expect(servers["gh"] != nil)
    #expect((servers["deiko-memory"] as? [String: Any])?["type"] as? String == "stdio", "VS Code requires `type`")
    #expect(vscode["mcpServers"] == nil, "must not invent the other spelling")

    #expect(home.targets().allSatisfy { AgentSetup.isRegistered($0, command: node, arguments: [script]) })
}

@Test("a second click writes nothing")
func connectTwiceIsQuiet() throws {
    let home = try everyAgent()
    _ = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    let before = home.read(".codex/config.toml") + home.read(".claude.json")
    let outcome = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    #expect(outcome.done.count == 6)
    #expect(home.read(".codex/config.toml") + home.read(".claude.json") == before)
}

@Test("a file that will not parse is left byte-for-byte, and the others still get set up")
func refusesUnparseable() throws {
    let home = try everyAgent()
    let commented = "{\n  // my servers\n  \"servers\": {}\n}\n"
    try home.write("Library/Application Support/Code/User/mcp.json", commented)
    let outcome = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    #expect(outcome.failed.map(\.agent) == ["VS Code"])
    #expect(outcome.done.count == 5)
    #expect(home.read("Library/Application Support/Code/User/mcp.json") == commented)
}

@Test("a symlinked config is written through to the real file, and stays a link")
func followsSymlinks() throws {
    let home = try everyAgent()
    try home.write("dotfiles/claude.json", #"{"userID":"u"}"#)
    try FileManager.default.removeItem(at: home.url(".claude.json"))
    try FileManager.default.createSymbolicLink(at: home.url(".claude.json"), withDestinationURL: home.url("dotfiles/claude.json"))

    _ = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.url(".claude.json").path)
    #expect(link == home.url("dotfiles/claude.json").path)
    #expect(home.json("dotfiles/claude.json")["userID"] as? String == "u")
    #expect((home.json("dotfiles/claude.json")["mcpServers"] as? [String: Any])?["deiko-memory"] != nil)
}

@Test("an existing file keeps its permissions; a new one is private")
func keepsPermissions() throws {
    let home = try everyAgent()
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.url(".codex/config.toml").path)
    _ = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    #expect(home.mode(".codex/config.toml") == 0o644)
    #expect(home.mode(".cursor/mcp.json") == 0o600)
}

@Test("removing it takes out only our entry, everywhere")
func disconnectRestoresEveryAgent() throws {
    let home = try everyAgent()
    let codexBefore = home.read(".codex/config.toml")
    _ = AgentSetup.connect(home.targets(), command: node, arguments: [script])
    let outcome = AgentSetup.disconnect(home.targets())
    #expect(outcome.failed.isEmpty)
    #expect(home.read(".codex/config.toml").trimmingCharacters(in: .newlines) == codexBefore.trimmingCharacters(in: .newlines))
    #expect((home.json(".claude.json")["mcpServers"] as? [String: Any])?.keys.sorted() == ["playwright"])
    #expect(!home.targets().contains { AgentSetup.isRegistered($0, command: node, arguments: [script]) })
}

@Test("Copy setup carries a pasteable command line and valid JSON")
func copySetupText() throws {
    let text = AgentSetup.setupText(command: node, arguments: [script])
    #expect(text.contains("/opt/deiko/node '/Users/dev/personal /Deiko/packages/core/src/memory-mcp.mjs'"))
    let json = try #require(text.range(of: "{").map { String(text[$0.lowerBound...]) })
    let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let entry = (doc["mcpServers"] as? [String: Any])?["deiko-memory"] as? [String: Any]
    #expect(entry?["command"] as? String == node)
    #expect(entry?["args"] as? [String] == [script])
}
