import Foundation
import Testing
@testable import DeikoHandoff

// Reading other applications' config files, which are hand-maintained and
// spelled four different ways. Fixtures put unrelated servers beside the ones
// we look for, because the point is to leave everything else alone and never
// trap on a file somebody is midway through editing.

@Test("a hosted server is recognised by the host the vendor mints")
func hostedServersMatch() {
    let servers: [String: Any] = [
        "atlassian": ["type": "http", "url": "https://mcp.atlassian.com/v2/mcp"],
        "playwright": ["command": "npx", "args": ["@playwright/mcp"]],
    ]
    let found = Integrations.trackers(inServers: servers)
    #expect(found.contains(.jira))
    #expect(!found.contains(.linear))
}

@Test("one Atlassian connector reaches both Jira and Confluence")
func atlassianCoversBoth() {
    // One server, and a persona may file to either, so connecting it once must
    // light up both destinations.
    let found = Integrations.trackers(inServers: [
        "atlassian": ["url": "https://mcp.atlassian.com/v2/mcp"],
    ])
    #expect(found.contains(.jira))
    #expect(found.contains(.confluence))
}

@Test("each vendor's own host is matched")
func everyHost() {
    let cases: [(String, Tracker)] = [
        ("https://mcp.linear.app/mcp", .linear),
        ("https://mcp.linear.app/mcp/readonly", .linear),
        ("https://api.githubcopilot.com/mcp/", .github),
        ("https://mcp.notion.com/mcp", .notion),
    ]
    for (url, expected) in cases {
        #expect(Integrations.trackers(inServers: ["x": ["url": url]]).contains(expected),
                "\(url) should read as \(expected)")
    }
}

@Test("Claude Code's per-project servers count too")
func claudeProjectScope() {
    // A tracker configured for one repo is still one this Mac can reach, and
    // the root block is where `claude mcp add --scope user` puts things.
    let doc: [String: Any] = [
        "oauthAccount": ["emailAddress": "dev@example.com"],
        "mcpServers": ["notion": ["url": "https://mcp.notion.com/mcp"]],
        "projects": [
            "/Users/dev/work": [
                "history": ["one", "two"],
                "mcpServers": ["linear-server": ["type": "http", "url": "https://mcp.linear.app/mcp"]],
            ],
        ],
    ]
    let found = Integrations.trackers(inClaudeConfig: doc)
    #expect(found == [.notion, .linear])
}

@Test("a config with no servers at all is simply empty")
func claudeEmpty() {
    #expect(Integrations.trackers(inClaudeConfig: ["oauthAccount": ["x": 1]]).isEmpty)
    #expect(Integrations.trackers(inClaudeConfig: nil).isEmpty)
}

@Test("Gemini's httpUrl is a url by another name")
func geminiHttpUrl() {
    let found = Integrations.trackers(inServers: [
        "atlassian": ["httpUrl": "https://mcp.atlassian.com/v2/mcp"],
    ])
    #expect(found.contains(.jira))
}

@Test("a stdio server is recognised by its package")
func stdioPackages() {
    let cases: [([String: Any], Tracker)] = [
        (["command": "npx", "args": ["-y", "@tacticlaunch/mcp-linear"]], .linear),
        (["command": "/usr/local/bin/github-mcp-server"], .github),
        (["command": "uvx", "args": ["mcp-atlassian"]], .jira),
        (["command": "npx", "args": ["-y", "notion-mcp-server"]], .notion),
    ]
    for (entry, expected) in cases {
        #expect(Integrations.trackers(inServers: ["srv": entry]).contains(expected))
    }
}

@Test("what somebody called it is the last resort, and it is allowed to be greedy")
func nameFallback() {
    // A server called `my-jira-thing` is almost certainly Jira, and the cost of
    // being wrong is one line of UI copy — the prompt is conditional anyway.
    #expect(Integrations.trackers(inServers: ["my-jira-thing": ["command": "./run.sh"]]).contains(.jira))
    #expect(Integrations.trackers(inServers: ["playwright": ["command": "npx"]]).isEmpty)
}

@Test("a codex table is read, and the next table ends it")
func codexTOML() {
    let toml = """
    model = "gpt-5"

    [mcp_servers.atlassian]
    url = "https://mcp.atlassian.com/v2/mcp"

    [mcp_servers.playwright]
    command = "npx"
    args = ["@playwright/mcp"]

    [profiles.review]
    url = "https://example.com/not-a-server"
    """
    let found = Integrations.trackers(inCodexTOML: toml)
    #expect(found.contains(.jira))
    #expect(found.count == 2)   // jira + confluence, one Atlassian server
}

@Test("a codex file with no servers, or none at all")
func codexEmpty() {
    #expect(Integrations.trackers(inCodexTOML: "model = \"gpt-5\"\n").isEmpty)
    #expect(Integrations.trackers(inCodexTOML: nil).isEmpty)
}

@Test("a malformed config yields nothing rather than trapping")
func malformedShapes() {
    // These are files other applications own, edited by hand. A half-written
    // one is somebody mid-edit, not a reason to crash Deiko.
    #expect(Integrations.trackers(inServers: "not an object").isEmpty)
    #expect(Integrations.trackers(inServers: nil).isEmpty)
    #expect(Integrations.trackers(inServers: ["srv": 42]).isEmpty)
    #expect(Integrations.trackers(inClaudeConfig: ["projects": "nope"]).isEmpty)
    #expect(Integrations.trackers(inServers: ["srv": ["url": 7]]).isEmpty)
}

@Test("only sensible destinations are offered for each kind of persona")
func allowedDestinations() {
    #expect(Tracker.allowed(for: .qaTicket) == [.jira, .linear, .github, .notion])
    // An analysis belongs on a page, not a board.
    #expect(Tracker.allowed(for: .analysis) == [.confluence, .notion])
    // A code change is made, not filed.
    #expect(Tracker.allowed(for: .codeChange).isEmpty)
}
