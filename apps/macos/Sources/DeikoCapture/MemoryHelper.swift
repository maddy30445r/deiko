import AppKit
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// GIVING YOUR AGENT THE DEIKO MEMORY
//
// The app's half of `AgentSetup`: it knows where THIS install's node and
// memory script live, and hands them over. Which agents exist, where each keeps
// its MCP config and how that file is edited safely is all `AgentSetup`, tested
// against a temp HOME. The entry names the node this app resolved and the
// script by absolute path, because the agent spawns it with its own
// environment. `LegacyMCP` only ever removes `fovea`, never this.
// ─────────────────────────────────────────────────────────────────────────────

enum MemoryHelper {

    enum Failure: Error, LocalizedError {
        case noRuntime
        var errorDescription: String? { "Deiko could not find its Node runtime." }
    }

    /// What Settings shows: the agents found here, and which of them already
    /// have the helper.
    struct Status: Equatable {
        var found: [String] = []
        var connected: [String] = []
        var allSet: Bool { !found.isEmpty && connected.count == found.count }
    }

    /// The node this app resolved, and the script beside it.
    static func command() -> (command: String, arguments: [String])? {
        guard let node = NodeRuntime.resolve() else { return nil }
        let script: URL
        switch Layout.resolve() {
        case .development(let repo): script = repo.appendingPathComponent("scripts/memory-mcp.mjs")
        case .bundled(let resources): script = resources.appendingPathComponent("scripts/memory-mcp.mjs")
        case nil: return nil
        }
        return (node.path, [script.path])
    }

    static func targets() -> [AgentTarget] {
        AgentSetup.detect(
            home: URL(fileURLWithPath: NSHomeDirectory()),
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Synchronous file reads — call it off the main actor.
    static func status() -> Status {
        let targets = targets()
        guard let run = command() else { return Status(found: targets.map(\.name)) }
        return Status(
            found: targets.map(\.name),
            connected: targets.filter { AgentSetup.isRegistered($0, command: run.command, arguments: run.arguments) }.map(\.name)
        )
    }

    static func connect() throws -> AgentSetup.Outcome {
        guard let run = command() else { throw Failure.noRuntime }
        return AgentSetup.connect(targets(), command: run.command, arguments: run.arguments)
    }

    static func disconnect() -> AgentSetup.Outcome {
        AgentSetup.disconnect(targets())
    }

    /// For an agent Deiko can't set up itself. Returns false when there is
    /// nothing to copy.
    @MainActor
    static func copySetup() -> Bool {
        guard let run = command() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentSetup.setupText(command: run.command, arguments: run.arguments), forType: .string)
        return true
    }
}
