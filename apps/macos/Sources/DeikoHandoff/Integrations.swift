import Foundation

/// A place a brief can be filed. The persona picks a destination; whether
/// anything can reach it is a separate question.
public enum Tracker: String, CaseIterable, Codable, Sendable {
    case jira, confluence, linear, github, notion

    public var displayName: String {
        switch self {
        case .jira: return "Jira"
        case .confluence: return "Confluence"
        case .linear: return "Linear"
        case .github: return "GitHub"
        case .notion: return "Notion"
        }
    }

    /// What the thing filed there is called, in the sentence the prompt writes.
    public var artefact: String {
        switch self {
        case .jira: return "Jira issue"
        case .confluence: return "Confluence page"
        case .linear: return "Linear issue"
        case .github: return "GitHub issue"
        case .notion: return "Notion page"
        }
    }

    /// The official remote endpoint, for the setup line the app offers.
    public var url: String {
        switch self {
        case .jira, .confluence: return "https://mcp.atlassian.com/v2/mcp"
        case .linear: return "https://mcp.linear.app/mcp"
        case .github: return "https://api.githubcopilot.com/mcp/"
        case .notion: return "https://mcp.notion.com/mcp"
        }
    }

    /// What the connector is called where somebody would look for it. Atlassian
    /// has one connector covering Jira and Confluence, so the name a user
    /// recognises is not always the tracker's own.
    public var connectorName: String {
        switch self {
        case .jira, .confluence: return "Atlassian"
        case .linear: return "Linear"
        case .github: return "GitHub"
        case .notion: return "Notion"
        }
    }

    /// How to connect it, per agent. Shown in Deiko's own window — never in the
    /// prompt, which stays quiet about setup.
    public var setup: [(agent: String, how: String)] {
        let key = connectorName.lowercased()
        switch self {
        case .github:
            return [
                ("Claude Code", "claude mcp add --transport http github \(url) --header \"Authorization: Bearer <your GitHub token>\""),
                ("Codex", "codex mcp add github --url \(url)"),
                ("Cursor", "Add \(url) in Settings → MCP, with an Authorization header"),
                ("Claude.ai / ChatGPT", "Turn on the GitHub connector"),
            ]
        default:
            return [
                ("Claude Code", "claude mcp add --transport http \(key) \(url)"),
                ("Codex", "codex mcp add \(key) --url \(url)"),
                ("Cursor", "Add \(url) in Settings → MCP"),
                ("Claude.ai / ChatGPT", "Turn on the \(connectorName) connector"),
            ]
        }
    }

    /// Which destinations a given kind of persona may file to.
    ///
    /// A code change is not filed anywhere — it is made — so it has none, and
    /// an analysis belongs on a page rather than a board.
    public static func allowed(for base: Persona.Base) -> [Tracker] {
        switch base {
        case .qaTicket: return [.jira, .linear, .github, .notion]
        case .analysis: return [.confluence, .notion]
        case .codeChange: return []
        }
    }

    /// Hosts the vendor mints. Jira and Confluence share one server, so either
    /// destination is reachable the moment Atlassian is connected.
    var hostMarkers: [String] {
        switch self {
        case .jira, .confluence: return ["mcp.atlassian.com"]
        case .linear: return ["mcp.linear.app"]
        case .github: return ["api.githubcopilot.com"]
        case .notion: return ["mcp.notion.com"]
        }
    }

    /// Package names for the stdio servers people ran before the hosted ones.
    var packageMarkers: [String] {
        switch self {
        case .jira, .confluence: return ["mcp-atlassian", "atlassian-mcp"]
        case .linear: return ["mcp-linear", "linear-mcp"]
        case .github: return ["github-mcp-server", "server-github"]
        case .notion: return ["notion-mcp-server", "mcp-notion"]
        }
    }

    /// Last resort: what somebody called the server in their own config.
    var nameMarkers: [String] {
        switch self {
        case .jira, .confluence: return ["jira", "atlassian", "confluence"]
        case .linear: return ["linear"]
        case .github: return ["github"]
        case .notion: return ["notion"]
        }
    }
}

/// Which agent's config named it. Only ever shown to the user, so that a
/// sentence can say "connected in Claude Code" rather than just "connected".
public enum AgentClient: String, CaseIterable, Sendable {
    case claudeCode, cursor, codex, gemini

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }
}

/// Which trackers an agent on this Mac can already reach. Pure: it takes an
/// already parsed config, and reading the files is `AgentConfigs` in the app
/// target, since only the decision can be tested.
///
/// Matching is three attempts, most reliable first: a remote server's URL (an
/// exact host the vendor mints), then a stdio server's command and arguments (a
/// package name), then the server's own key. The last is greedy on purpose (a
/// server called `github-docs` reads as GitHub) because a wrong guess costs one
/// line of UI copy.
public enum Integrations {

    /// One server entry, by the three signals in order of how much they prove.
    static func match(key: String, url: String?, command: String?) -> Set<Tracker> {
        let url = (url ?? "").lowercased()
        if !url.isEmpty {
            let hit = Tracker.allCases.filter { t in t.hostMarkers.contains { url.contains($0) } }
            if !hit.isEmpty { return Set(hit) }
        }
        let command = (command ?? "").lowercased()
        if !command.isEmpty {
            let hit = Tracker.allCases.filter { t in t.packageMarkers.contains { command.contains($0) } }
            if !hit.isEmpty { return Set(hit) }
        }
        let key = key.lowercased()
        return Set(Tracker.allCases.filter { t in t.nameMarkers.contains { key.contains($0) } })
    }

    /// An `mcpServers` object, as Claude Code, Cursor and Gemini all spell it.
    ///
    /// Anything that is not the expected shape is skipped rather than trapped:
    /// these are other applications' hand-maintained files, and a malformed one
    /// may be mid-edit.
    public static func trackers(inServers servers: Any?) -> Set<Tracker> {
        guard let servers = servers as? [String: Any] else { return [] }
        var found: Set<Tracker> = []
        for (key, raw) in servers {
            guard let entry = raw as? [String: Any] else {
                // A bare string is still a name we can read.
                found.formUnion(match(key: key, url: raw as? String, command: nil))
                continue
            }
            // `httpUrl` is Gemini CLI's spelling of a streamable-HTTP server.
            let url = (entry["url"] as? String) ?? (entry["httpUrl"] as? String)
            var command = entry["command"] as? String ?? ""
            if let args = entry["args"] as? [String] {
                command += " " + args.joined(separator: " ")
            }
            found.formUnion(match(key: key, url: url, command: command))
        }
        return found
    }

    /// `~/.claude.json`, which keeps servers in two places: the root, for
    /// servers available everywhere, and one block per project. Both count —
    /// a tracker configured for one repo is still a tracker this Mac can reach.
    public static func trackers(inClaudeConfig doc: [String: Any]?) -> Set<Tracker> {
        guard let doc else { return [] }
        var found = trackers(inServers: doc["mcpServers"])
        if let projects = doc["projects"] as? [String: Any] {
            for (_, raw) in projects {
                guard let project = raw as? [String: Any] else { continue }
                found.formUnion(trackers(inServers: project["mcpServers"]))
            }
        }
        return found
    }

    /// Codex's `config.toml`, walked rather than parsed, for the reason
    /// `TomlConfig` gives: it is hand-written and often commented, and only
    /// three keys of one kind of table are read.
    public static func trackers(inCodexTOML text: String?) -> Set<Tracker> {
        guard let text else { return [] }
        var found: Set<Tracker> = []
        var key: String?
        var url: String?
        var command = ""

        func flush() {
            guard let key else { return }
            found.formUnion(match(key: key, url: url, command: command))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                key = nil; url = nil; command = ""
                // `[mcp_servers.linear]` opens one; any other table closes it.
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if header.hasPrefix("mcp_servers.") {
                    key = String(header.dropFirst("mcp_servers.".count))
                }
                continue
            }
            guard key != nil, let eq = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch name {
            case "url": url = value
            case "command": command += " " + value
            case "args": command += " " + value
            default: break
            }
        }
        flush()
        return found
    }
}
