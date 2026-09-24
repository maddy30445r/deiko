import Foundation
import Testing
@testable import DeikoHandoff

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

// ─────────────────────────────────────────────────────────────────────────────
// RESTORED FROM GIT HISTORY (git show 1fcd01e^) — `merge`, `isRegistered` and
// `stdioEntry` were deleted when Fovea's bridge went away; Task 12 brings them
// back so `MemoryHelper` can register `deiko-memory` the same tested way. Only
// Fovea → Deiko in prose, the `@testable import` and the `Fovea.app` fixture
// path changed; the tests are otherwise as they were. Where a name here would
// collide with one already above, the restored one below is the one renamed
// (the fixture and tests above are unchanged) so both keep running.
// ─────────────────────────────────────────────────────────────────────────────

/// A second realistic fixture, for the merge tests: no `fovea` entry yet,
/// unlike `claudeConfig()` above (which models a stale one already there to
/// remove).
private func mergeFixtureConfig() -> [String: Any] {
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

private let nodePath = "/Applications/Deiko.app/Contents/Resources/node"

/// A function, not a global `let`: `[String: Any]` is not Sendable, and a
/// shared mutable global is exactly what strict concurrency is there to stop.
private func foveaEntry() -> [String: Any] {
    ClientConfig.stdioEntry(
        command: nodePath,
        arguments: ["/Applications/Deiko.app/Contents/Resources/apps/bridge/src/server.mjs"]
    )
}

// ── The property that matters ───────────────────────────────────────────────

@Test("everything Deiko was not asked to change survives the merge")
func mergePreservesEverythingElse() throws {
    let before = mergeFixtureConfig()
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
    let after = try ClientConfig.merge(into: mergeFixtureConfig(), serverKey: "fovea", entry: foveaEntry())
    let servers = try #require(after["mcpServers"] as? [String: Any])

    #expect(servers.count == 2)
    let playwright = try #require(servers["playwright"] as? [String: Any])
    #expect(playwright["command"] as? String == "npx")
}

@Test("connecting twice changes nothing the second time")
func mergeIsIdempotent() throws {
    let once = try ClientConfig.merge(into: mergeFixtureConfig(), serverKey: "fovea", entry: foveaEntry())
    let twice = try ClientConfig.merge(into: once, serverKey: "fovea", entry: foveaEntry())
    #expect(NSDictionary(dictionary: once).isEqual(to: twice))
}

@Test("reconnecting replaces a stale entry rather than adding a second")
func mergeReplacesStaleEntry() throws {
    let stale = ClientConfig.stdioEntry(command: "/old/path/node", arguments: ["/old/server.mjs"])
    let first = try ClientConfig.merge(into: mergeFixtureConfig(), serverKey: "fovea", entry: stale)
    let second = try ClientConfig.merge(into: first, serverKey: "fovea", entry: foveaEntry())

    let servers = try #require(second["mcpServers"] as? [String: Any])
    #expect(servers.count == 2, "fovea replaced, playwright kept")
    let fovea = try #require(servers["fovea"] as? [String: Any])
    #expect(fovea["command"] as? String == "/Applications/Deiko.app/Contents/Resources/node")
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
    let config = try ClientConfig.merge(into: mergeFixtureConfig(), serverKey: "fovea", entry: stale)

    // Present, but pointing somewhere that no longer exists. Reporting this as
    // connected would leave the client failing to spawn a server forever, with
    // the error surfacing inside Claude Code rather than in Deiko.
    #expect(!ClientConfig.isRegistered(in: config, serverKey: "fovea", matching: foveaEntry()))
    #expect(ClientConfig.isRegistered(in: config, serverKey: "fovea", matching: stale))
}

@Test("absent and empty configs read as disconnected")
func absentReadsAsDisconnected() {
    #expect(!ClientConfig.isRegistered(in: nil, serverKey: "fovea", matching: foveaEntry()))
    #expect(!ClientConfig.isRegistered(in: [:], serverKey: "fovea", matching: foveaEntry()))
    #expect(!ClientConfig.isRegistered(in: ["mcpServers": [:]], serverKey: "fovea", matching: foveaEntry()))
}

// ── Disconnecting, after a merge (renamed: the file above already covers
//    disconnecting from a config where the entry was placed by hand) ────────

@Test("removing Deiko leaves the rest of the config exactly as it was")
func removeAfterMergeTouchesOnlyOurKey() throws {
    let before = mergeFixtureConfig()
    let connected = try ClientConfig.merge(into: before, serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: connected, serverKey: "fovea"))

    // Back to the original, key for key — disconnecting must be as if we had
    // never written.
    #expect(NSDictionary(dictionary: after).isEqual(to: before))
}

@Test("another client's server survives the removal, after a merge")
func removeAfterMergeLeavesOtherServers() throws {
    let connected = try ClientConfig.merge(into: mergeFixtureConfig(), serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: connected, serverKey: "fovea"))
    let servers = try #require(after["mcpServers"] as? [String: Any])

    #expect(servers["playwright"] != nil)
    #expect(servers["fovea"] == nil)
}

@Test("removing what was never merged in reports nothing to do")
func removeWhenNeverMergedIsNil() {
    // nil, not an unchanged copy: the caller skips the write entirely rather
    // than rewriting a file it did not change.
    #expect(ClientConfig.remove(from: mergeFixtureConfig(), serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: nil, serverKey: "fovea") == nil)
    #expect(ClientConfig.remove(from: [:], serverKey: "fovea") == nil)
}

@Test("an emptied mcpServers stays present rather than being deleted, after a merge")
func removeAfterMergeKeepsTheContainer() throws {
    let only = try ClientConfig.merge(into: [:], serverKey: "fovea", entry: foveaEntry())
    let after = try #require(ClientConfig.remove(from: only, serverKey: "fovea"))

    // Present and empty, not absent. Those mean different things to whoever
    // wrote the file, and we do not get to decide which they meant.
    let servers = try #require(after["mcpServers"] as? [String: Any])
    #expect(servers.isEmpty)
}

// ── The container key is a parameter, not a constant (merge side) ──────────

@Test("VS Code's own MCP config uses `servers`, not `mcpServers`, on merge too")
func mergeContainerKeyIsConfigurable() throws {
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
