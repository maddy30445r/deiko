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
            "fovea": ["type": "stdio", "command": "/old/node", "args": ["/old/server.mjs"]],
            "playwright": ["type": "stdio", "command": "npx", "args": ["@playwright/mcp"]],
        ],
    ]
}

// ── Disconnecting ───────────────────────────────────────────────────────────

@Test("removing Fovea leaves the rest of the config exactly as it was")
func removeTouchesOnlyOurKey() throws {
    let before = claudeConfig()
    let after = try #require(ClientConfig.remove(from: before, serverKey: "fovea"))

    var expected = before
    var servers = try #require(expected["mcpServers"] as? [String: Any])
    servers.removeValue(forKey: "fovea")
    expected["mcpServers"] = servers

    #expect(NSDictionary(dictionary: after).isEqual(to: expected))
}

@Test("another client's server survives the removal")
func removeLeavesOtherServers() throws {
    let after = try #require(ClientConfig.remove(from: claudeConfig(), serverKey: "fovea"))
    let servers = try #require(after["mcpServers"] as? [String: Any])

    #expect(servers["playwright"] != nil)
    #expect(servers["fovea"] == nil)
}

@Test("removing what is not there reports nothing to do")
func removeWhenAbsentIsNil() {
    // nil, not an unchanged copy: the caller skips the write entirely rather
    // than rewriting a file it did not change.
    #expect(ClientConfig.remove(from: ["mcpServers": ["playwright": ["command": "npx"]]], serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: nil, serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: [:], serverKey: "fovea") == nil)
}

@Test("an emptied mcpServers stays present rather than being deleted")
func removeKeepsTheContainer() throws {
    let only: [String: Any] = ["mcpServers": ["fovea": ["command": "npx"]]]
    let after = try #require(ClientConfig.remove(from: only, serverKey: "fovea"))

    // Present and empty, not absent. Those mean different things to whoever
    // wrote the file, and we do not get to decide which they meant.
    let servers = try #require(after["mcpServers"] as? [String: Any])
    #expect(servers.isEmpty)
}

@Test("an mcpServers of the wrong shape is left alone, not crashed on or coerced")
func removeRefusesWrongShape() {
    // Something else wrote a string here instead of an object. `LegacyMCP`
    // depends on this reading as "nothing to remove" rather than trapping —
    // it runs against configs it has never seen the shape of.
    #expect(ClientConfig.remove(from: ["mcpServers": "not an object"], serverKey: "fovea") == nil)
}

// ── The container key is a parameter, not a constant ────────────────────────

@Test("VS Code's own MCP config uses `servers`, not `mcpServers`")
func containerKeyIsConfigurable() throws {
    let before: [String: Any] = ["servers": ["fovea": ["command": "npx"], "playwright": ["command": "npx"]]]
    let after = try #require(
        ClientConfig.remove(from: before, serverKey: "fovea", containerKey: "servers")
    )
    let servers = try #require(after["servers"] as? [String: Any])
    #expect(servers.count == 1)
    #expect(servers["fovea"] == nil)
    #expect(after["mcpServers"] == nil, "must not invent the other spelling")
}
