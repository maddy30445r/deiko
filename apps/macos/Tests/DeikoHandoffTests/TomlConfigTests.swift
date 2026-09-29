import Testing
@testable import DeikoHandoff

// `~/.codex/config.toml` is written by hand and holds the user's model,
// approval policy, sandbox settings and profiles, often with comments. Every
// test is the same assertion from a different angle: removing our one table
// touches nothing else.

/// A config in the shape a real one takes: comments, blank lines, other
/// tables, and a table after ours so the range logic has something to stop at.
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

/// `realistic()` with our table appended, as an earlier build wrote it.
private func withFoveaRegistered() -> String {
    realistic() + "\n\n" + """
    [mcp_servers.fovea]
    command = "/opt/node"
    args = ["/a.mjs"]

    """
}

@Test("disconnect returns the file to what it was")
func disconnectRestores() {
    let before = realistic()
    let after = TomlConfig.remove(from: withFoveaRegistered(), serverKey: "fovea")

    #expect(after != nil)
    #expect(!(after ?? "").contains("mcp_servers.fovea"))
    // Not merely "our lines are gone" — the file is the one it started with.
    #expect(after?.trimmingCharacters(in: .whitespacesAndNewlines)
        == before.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test("removing something that was never there writes nothing")
func removeAbsent() {
    #expect(TomlConfig.remove(from: realistic(), serverKey: "fovea") == nil)
    #expect(TomlConfig.remove(from: nil, serverKey: "fovea") == nil)
}

@Test("a sub-table of ours is swept up with it, not orphaned")
func subTableGoesToo() {
    // Codex allows `[mcp_servers.fovea.env]`. We never write one, but a user
    // might have added it by hand, and leaving it behind would strand a table
    // whose parent no longer exists, which Codex reads as a server with no
    // command.
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

private let key = "deiko-memory"

private func merged(_ text: String?, _ command: String = "/opt/node", _ args: [String] = ["/a.mjs"]) -> String {
    TomlConfig.merge(into: text, serverKey: key, command: command, arguments: args) ?? "REFUSED"
}

@Test("a fresh Codex config gets just our table")
func tomlMergeFromNothing() {
    let out = merged(nil)
    #expect(out == "[mcp_servers.deiko-memory]\ncommand = \"/opt/node\"\nargs = [\"/a.mjs\"]\n")
    #expect(merged("") == out)
}

@Test("every other line survives byte-for-byte, comments included")
func tomlMergePreservesEverythingElse() {
    let before = realistic()
    let after = merged(before)
    #expect(after.hasPrefix(before), "the owner's text must come back untouched, ahead of our table")
    #expect(after.components(separatedBy: "[mcp_servers.deiko-memory]").count == 2)
}

@Test("connecting twice changes nothing the second time")
func tomlMergeIdempotent() {
    let once = merged(realistic())
    #expect(merged(once) == once)
}

@Test("a moved app rewrites our table in place, and the table after it survives")
func mergeRewritesInPlace() {
    let ours = "[mcp_servers.deiko-memory]\ncommand = \"/old/node\"\nargs = [\"/old.mjs\"]\n\n"
    let before = "model = \"o3\"\n\n" + ours + "[profiles.review]\nmodel = \"o3\"\n"
    let after = merged(before, "/new/node", ["/new.mjs"])
    #expect(!after.contains("/old/node"))
    #expect(after.contains("[profiles.review]\nmodel = \"o3\""))
    #expect(after.hasPrefix("model = \"o3\"\n\n[mcp_servers.deiko-memory]\ncommand = \"/new/node\""))
}

@Test("connect then disconnect returns the file to what it was")
func mergeThenRemove() {
    let before = realistic()
    let after = TomlConfig.remove(from: merged(before), serverKey: key)
    #expect(after?.trimmingCharacters(in: .whitespacesAndNewlines)
        == before.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test("registration is compared by value, so a stale path reads as not set up")
func tomlRegisteredByValue() {
    let text = merged(realistic())
    #expect(TomlConfig.isRegistered(in: text, serverKey: key, command: "/opt/node", arguments: ["/a.mjs"]))
    #expect(!TomlConfig.isRegistered(in: text, serverKey: key, command: "/opt/node", arguments: ["/moved.mjs"]))
    #expect(!TomlConfig.isRegistered(in: realistic(), serverKey: key, command: "/opt/node", arguments: ["/a.mjs"]))
}

@Test("a path with a space, a quote or a backslash round-trips")
func tomlQuoting() {
    let nasty = #"/Users/a "b"/per sonal/no\de"#
    let text = merged(nil, nasty)
    #expect(text.contains(#"command = "/Users/a \"b\"/per sonal/no\\de""#))
    #expect(TomlConfig.isRegistered(in: text, serverKey: key, command: nasty, arguments: ["/a.mjs"]))
}

@Test("a file an appended table would break is refused, not edited")
func mergeRefusesShapesItWouldBreak() {
    // An inline `mcp_servers = { … }` cannot be extended by a later header.
    #expect(TomlConfig.merge(into: "mcp_servers = { x = { command = \"y\" } }\n", serverKey: key, command: "/n", arguments: []) == nil)
    // Our key in quotes: we would not find it, and would define it twice.
    #expect(TomlConfig.merge(into: "[mcp_servers.\"deiko-memory\"]\ncommand = \"y\"\n", serverKey: key, command: "/n", arguments: []) == nil)
    // A dotted-key `[mcp_servers]` table is fine to add a sub-table to.
    #expect(TomlConfig.merge(into: "[mcp_servers]\nx.command = \"y\"\n", serverKey: key, command: "/n", arguments: []) != nil)
}
