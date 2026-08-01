import Testing
@testable import FoveaHandoff

// `~/.codex/config.toml` is a file its owner writes BY HAND. It holds their
// model, approval policy, sandbox settings and profiles, usually with comments
// explaining why. Every test here is really the same assertion from a different
// angle: we add or remove one table and touch nothing else.

/// A config in the shape a real one takes — comments, blank lines, other
/// tables, and a table AFTER ours so the range logic has something to stop at.
private func realistic() -> String {
    """
    # my codex setup
    model = "gpt-5-codex"
    approval_policy = "on-request"

    [sandbox_workspace_write]
    network_access = true

    [mcp_servers.playwright]
    command = "npx"
    args = ["@playwright/mcp@latest"]

    [profiles.review]
    model = "o3"
    """
}

@Test("a fresh install gets just our table")
func fromNothing() {
    let out = TomlConfig.merge(
        into: nil, serverKey: "fovea", command: "/opt/node", arguments: ["/app/server.mjs"]
    )
    #expect(out.contains("[mcp_servers.fovea]"))
    #expect(out.contains(#"command = "/opt/node""#))
    #expect(out.contains(#"args = ["/app/server.mjs"]"#))
}

@Test("every other line survives byte-for-byte, comments included")
func preservesEverythingElse() {
    let before = realistic()
    let after = TomlConfig.merge(
        into: before, serverKey: "fovea", command: "/opt/node", arguments: ["/app/server.mjs"]
    )

    // The point of the whole file: a hand-maintained config comes back intact.
    for line in before.components(separatedBy: "\n") where !line.isEmpty {
        #expect(after.contains(line), "lost: \(line)")
    }
    #expect(after.contains("# my codex setup"), "a comment was dropped")
    #expect(after.contains("[mcp_servers.playwright]"), "another MCP server was dropped")
    #expect(after.contains("[profiles.review]"))
}

@Test("connecting twice does not add a second table")
func idempotent() {
    let once = TomlConfig.merge(
        into: realistic(), serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    )
    let twice = TomlConfig.merge(
        into: once, serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    )
    #expect(once == twice)
    #expect(twice.components(separatedBy: "[mcp_servers.fovea]").count == 2, "table duplicated")
}

@Test("a moved app rewrites our table in place, without disturbing the next one")
func rewritesInPlace() {
    let old = TomlConfig.merge(
        into: realistic(), serverKey: "fovea", command: "/old/node", arguments: ["/old/server.mjs"]
    )
    let new = TomlConfig.merge(
        into: old, serverKey: "fovea", command: "/new/node", arguments: ["/new/server.mjs"]
    )
    #expect(!new.contains("/old/node"))
    #expect(new.contains(#"command = "/new/node""#))
    #expect(new.contains("[profiles.review]"))
    #expect(new.components(separatedBy: "[mcp_servers.fovea]").count == 2)
}

@Test("disconnect returns the file to what it was")
func disconnectRestores() {
    let before = realistic()
    let connected = TomlConfig.merge(
        into: before, serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    )
    let after = TomlConfig.remove(from: connected, serverKey: "fovea")

    #expect(after != nil)
    #expect(!(after ?? "").contains("mcp_servers.fovea"))
    // Not merely "our lines are gone" — the file is the one they started with.
    #expect(after?.trimmingCharacters(in: .whitespacesAndNewlines)
        == before.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test("removing something that was never there writes nothing")
func removeAbsent() {
    #expect(TomlConfig.remove(from: realistic(), serverKey: "fovea") == nil)
    #expect(TomlConfig.remove(from: nil, serverKey: "fovea") == nil)
}

@Test("registration is compared by value, so a stale path reads as disconnected")
func registeredByValue() {
    let text = TomlConfig.merge(
        into: realistic(), serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    )
    #expect(TomlConfig.isRegistered(
        in: text, serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    ))
    // The app was moved: the entry is present but points somewhere that is not
    // there any more, which is worse than no entry — Codex would keep trying
    // to spawn it and fail inside Codex, where we cannot explain it.
    #expect(!TomlConfig.isRegistered(
        in: text, serverKey: "fovea", command: "/opt/node", arguments: ["/moved.mjs"]
    ))
    #expect(!TomlConfig.isRegistered(
        in: realistic(), serverKey: "fovea", command: "/opt/node", arguments: ["/a.mjs"]
    ))
}

@Test("a path with a quote or a backslash in it does not break the document")
func quoting() {
    let nasty = #"/Users/a "b"/no\de"#
    let text = TomlConfig.merge(
        into: nil, serverKey: "fovea", command: nasty, arguments: ["/a.mjs"]
    )
    #expect(text.contains(#"\""#), "quotes must be escaped")
    #expect(text.contains(#"\\"#), "backslashes must be escaped")
    // And it still round-trips as the same entry.
    #expect(TomlConfig.isRegistered(
        in: text, serverKey: "fovea", command: nasty, arguments: ["/a.mjs"]
    ))
}

@Test("a sub-table of ours is swept up with it, not orphaned")
func subTableGoesToo() {
    // Codex allows `[mcp_servers.fovea.env]`. Fovea never writes one, but a
    // user might have added it by hand — and leaving it behind would strand a
    // table whose parent no longer exists, which Codex reads as a server with
    // no command.
    let withEnv = """
        [mcp_servers.fovea]
        command = "/opt/node"
        args = ["/a.mjs"]

        [mcp_servers.fovea.env]
        DEBUG = "1"

        [profiles.review]
        model = "o3"
        """
    let after = TomlConfig.remove(from: withEnv, serverKey: "fovea")
    #expect(after != nil)
    #expect(!(after ?? "").contains("mcp_servers.fovea"))
    #expect((after ?? "").contains("[profiles.review]"))
}
