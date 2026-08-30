import Testing
@testable import DeikoHandoff

// `~/.codex/config.toml` is a file its owner writes BY HAND. It holds their
// model, approval policy, sandbox settings and profiles, usually with comments
// explaining why. Every test here is really the same assertion from a different
// angle: removing our one table touches nothing else.

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

/// `realistic()` with our table appended, as an earlier Fovea would have left
/// it — mirroring the shape `TomlConfig.merge` used to produce, back when this
/// file also had a `merge`.
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
