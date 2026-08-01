import Foundation
import Testing
@testable import FoveaHandoff

// These tests are about ONE property: Fovea edits a file it does not own, and
// everything it was not asked to change must survive. The realistic fixture
// below is shaped like a real `~/.claude.json` — the keys that would hurt to
// lose are named explicitly so a regression names them too.

private func claudeConfig() -> [String: Any] {
    [
        "oauthAccount": ["accountUuid": "abc-123", "emailAddress": "dev@example.com"],
        "machineID": "machine-xyz",
        "userID": "user-1",
        "projects": [
            "/Users/dev/work": ["history": ["one", "two"], "allowedTools": ["Bash"]]
        ],
        "cachedGrowthBookFeatures": ["flagA": true],
        "mcpServers": [
            "playwright": ["type": "stdio", "command": "npx", "args": ["@playwright/mcp"]]
        ],
    ]
}

private let nodePath = "/Applications/Fovea.app/Contents/Resources/node"

/// A function, not a global `let`: `[String: Any]` is not Sendable, and a
/// shared mutable global is exactly what strict concurrency is there to stop.
private func foveaEntry() -> [String: Any] {
    ClientConfig.stdioEntry(
        command: nodePath,
        arguments: ["/Applications/Fovea.app/Contents/Resources/apps/bridge/src/server.mjs"]
    )
}

// ── The property that matters ───────────────────────────────────────────────

@Test("everything Fovea was not asked to change survives the merge")
func mergePreservesEverythingElse() throws {
    let before = claudeConfig()
    let after = try ClientConfig.merge(into: before, serverKey: "fovea", entry: foveaEntry())

    for key in ["oauthAccount", "machineID", "userID", "projects", "cachedGrowthBookFeatures"] {
        #expect(
            NSDictionary(dictionary: [key: after[key] ?? "MISSING"])
                .isEqual(to: [key: before[key] ?? "ALSO MISSING"]),
            "\(key) must survive untouched"
        )
    }
}

@Test("another client's MCP server is not disturbed")
func mergeLeavesOtherServersAlone() throws {
    let after = try ClientConfig.merge(into: claudeConfig(), serverKey: "fovea", entry: foveaEntry())
    let servers = try #require(after["mcpServers"] as? [String: Any])

    #expect(servers.count == 2)
    let playwright = try #require(servers["playwright"] as? [String: Any])
    #expect(playwright["command"] as? String == "npx")
}

@Test("connecting twice changes nothing the second time")
func mergeIsIdempotent() throws {
    let once = try ClientConfig.merge(into: claudeConfig(), serverKey: "fovea", entry: foveaEntry())
    let twice = try ClientConfig.merge(into: once, serverKey: "fovea", entry: foveaEntry())
    #expect(NSDictionary(dictionary: once).isEqual(to: twice))
}

@Test("reconnecting replaces a stale entry rather than adding a second")
func mergeReplacesStaleEntry() throws {
    let stale = ClientConfig.stdioEntry(command: "/old/path/node", arguments: ["/old/server.mjs"])
    let first = try ClientConfig.merge(into: claudeConfig(), serverKey: "fovea", entry: stale)
    let second = try ClientConfig.merge(into: first, serverKey: "fovea", entry: foveaEntry())

    let servers = try #require(second["mcpServers"] as? [String: Any])
    #expect(servers.count == 2, "fovea replaced, playwright kept")
    let fovea = try #require(servers["fovea"] as? [String: Any])
    #expect(fovea["command"] as? String == "/Applications/Fovea.app/Contents/Resources/node")
}

// ── Starting from nothing ───────────────────────────────────────────────────

@Test("a machine with no config yet gets a valid one")
func mergeIntoNothing() throws {
    let after = try ClientConfig.merge(into: nil, serverKey: "fovea", entry: foveaEntry())
    let servers = try #require(after["mcpServers"] as? [String: Any])
    #expect(servers["fovea"] != nil)
    #expect(after.count == 1, "nothing invented beyond what was asked for")
}

@Test("a config with no mcpServers key yet")
func mergeIntoConfigWithoutServers() throws {
    let after = try ClientConfig.merge(into: ["machineID": "m"], serverKey: "fovea", entry: foveaEntry())
    #expect(after["machineID"] as? String == "m")
    #expect((after["mcpServers"] as? [String: Any])?["fovea"] != nil)
}

// ── Refusing to guess ───────────────────────────────────────────────────────

@Test("an mcpServers of the wrong shape is refused, not overwritten")
func mergeRefusesWrongShape() {
    // Something else wrote a value here. Replacing it would destroy whatever
    // that was, and we cannot know what it meant.
    #expect(throws: ClientConfig.MergeError.mcpServersNotAnObject) {
        try ClientConfig.merge(into: ["mcpServers": "not an object"], serverKey: "fovea", entry: foveaEntry())
    }
}

// ── Knowing whether we are connected ────────────────────────────────────────

@Test("registration is judged by value, so a stale path reads as disconnected")
func staleEntryIsNotRegistered() throws {
    let stale = ClientConfig.stdioEntry(command: "/moved/node", arguments: ["/moved/server.mjs"])
    let config = try ClientConfig.merge(into: claudeConfig(), serverKey: "fovea", entry: stale)

    // Present, but pointing somewhere that no longer exists. Reporting this as
    // connected would leave the client failing to spawn a server forever, with
    // the error surfacing inside Claude Code rather than in Fovea.
    #expect(!ClientConfig.isRegistered(in: config, serverKey: "fovea", matching: foveaEntry()))
    #expect(ClientConfig.isRegistered(in: config, serverKey: "fovea", matching: stale))
}

@Test("absent and empty configs read as disconnected")
func absentReadsAsDisconnected() {
    #expect(!ClientConfig.isRegistered(in: nil, serverKey: "fovea", matching: foveaEntry()))
    #expect(!ClientConfig.isRegistered(in: [:], serverKey: "fovea", matching: foveaEntry()))
    #expect(!ClientConfig.isRegistered(in: ["mcpServers": [:]], serverKey: "fovea", matching: foveaEntry()))
}

// ── Disconnecting ───────────────────────────────────────────────────────────

@Test("removing Fovea leaves the rest of the config exactly as it was")
func removeTouchesOnlyOurKey() throws {
    let before = claudeConfig()
    let connected = try ClientConfig.merge(into: before, serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: connected, serverKey: "fovea"))

    // Back to the original, key for key — disconnecting must be as if we had
    // never written.
    #expect(NSDictionary(dictionary: after).isEqual(to: before))
}

@Test("another client's server survives the removal")
func removeLeavesOtherServers() throws {
    let connected = try ClientConfig.merge(into: claudeConfig(), serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: connected, serverKey: "fovea"))
    let servers = try #require(after["mcpServers"] as? [String: Any])

    #expect(servers["playwright"] != nil)
    #expect(servers["fovea"] == nil)
}

@Test("removing what is not there reports nothing to do")
func removeWhenAbsentIsNil() {
    // nil, not an unchanged copy: the caller skips the write entirely rather
    // than rewriting a file it did not change.
    #expect(ClientConfig.remove(from: claudeConfig(), serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: nil, serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: [:], serverKey: "fovea") == nil)
}

@Test("an emptied mcpServers stays present rather than being deleted")
func removeKeepsTheContainer() throws {
    let only = try ClientConfig.merge(into: [:], serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: only, serverKey: "fovea"))

    // Present and empty, not absent. Those mean different things to whoever
    // wrote the file, and we do not get to decide which they meant.
    let servers = try #require(after["mcpServers"] as? [String: Any])
    #expect(servers.isEmpty)
}

// ── The container key is a parameter, not a constant ────────────────────────

@Test("VS Code's own MCP config uses `servers`, not `mcpServers`")
func containerKeyIsConfigurable() throws {
    let after = try ClientConfig.merge(
        into: ["servers": ["playwright": ["command": "npx"]]],
        serverKey: "fovea",
        entry: foveaEntry(),
        containerKey: "servers"
    )
    let servers = try #require(after["servers"] as? [String: Any])
    #expect(servers.count == 2)
    #expect(after["mcpServers"] == nil, "must not invent the other spelling")
}
