import Foundation
import Testing
@testable import DeikoHandoff

private let command = "/opt/node '/Applications/Deiko.app/Contents/Resources/scripts/claude-stop-hook.mjs'"

private func settings() -> [String: Any] {
    [
        "model": "opus",
        "permissions": ["allow": ["Bash(npm test)"]],
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "afplay done.aiff"]]]],
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]],
        ],
    ]
}

private func stopCommands(_ doc: [String: Any]) -> [String] {
    ((doc["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? [])
        .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Test("adding the hook keeps every other setting and hook")
func stopHookMergeKeepsTheRest() {
    let doc = ClaudeStopHook.merge(into: settings(), command: command)
    #expect(doc["model"] as? String == "opus")
    #expect((doc["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(npm test)"])
    #expect(((doc["hooks"] as? [String: Any])?["PreToolUse"] as? [Any])?.count == 1)
    #expect(stopCommands(doc) == ["afplay done.aiff", command])
    #expect(ClaudeStopHook.isRegistered(in: doc, command: command))
}

@Test("adding it twice, or from a moved app, leaves exactly one entry")
func stopHookMergeIsIdempotent() {
    let moved = "/usr/local/bin/node '/Users/dev/Applications/Deiko.app/Contents/Resources/scripts/claude-stop-hook.mjs'"
    let once = ClaudeStopHook.merge(into: settings(), command: moved)
    let twice = ClaudeStopHook.merge(into: ClaudeStopHook.merge(into: once, command: command), command: command)
    #expect(stopCommands(twice) == ["afplay done.aiff", command])
    #expect(!ClaudeStopHook.isRegistered(in: once, command: command))
}

@Test("a missing settings file gets just the hook")
func stopHookMergeIntoNothing() {
    let doc = ClaudeStopHook.merge(into: nil, command: command)
    #expect(stopCommands(doc) == [command])
    #expect(doc.keys.sorted() == ["hooks"])
}

@Test("removing the hook takes only ours, and empty containers with it")
func stopHookRemoveTakesOnlyOurs() throws {
    let withOurs = ClaudeStopHook.merge(into: settings(), command: command)
    let stripped = try #require(ClaudeStopHook.remove(from: withOurs))
    #expect(stopCommands(stripped) == ["afplay done.aiff"])
    #expect(ClaudeStopHook.remove(from: settings()) == nil, "nothing of ours: nothing to write")

    let alone = try #require(ClaudeStopHook.remove(from: ClaudeStopHook.merge(into: ["model": "opus"], command: command)))
    #expect(alone.keys.sorted() == ["model"])
}

@Test("the settings file follows CLAUDE_CONFIG_DIR")
func stopHookSettingsLocation() {
    let home = URL(fileURLWithPath: "/Users/dev")
    #expect(ClaudeStopHook.settingsURL(home: home, environment: [:]).path == "/Users/dev/.claude/settings.json")
    #expect(ClaudeStopHook.settingsURL(home: home, environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-x"]).path
        == "/tmp/claude-x/settings.json")
}
