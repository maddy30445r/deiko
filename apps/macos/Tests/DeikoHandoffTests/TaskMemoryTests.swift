import Foundation
import Testing
@testable import DeikoHandoff

/// A session folder holding `files`, each stamped `seconds` after a fixed time.
private func session(_ files: [String: TimeInterval]) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("task-memory-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, seconds) in files {
        let path = (dir as NSString).appendingPathComponent(name)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + seconds)], ofItemAtPath: path)
    }
    return dir
}

@Test("a mate that wrote back after this brief rendered makes it stale")
func mateWroteBackSince() throws {
    let brief = try session(["prompt.txt": 0])
    let quiet = try session(["prompt.txt": -600])
    let done = try session(["prompt.txt": -900, "outcome.md": 900])
    #expect(TaskMemory.isStale(sessionDir: brief, mates: [quiet, done]))
}

@Test("a write-back the prompt already carries changes nothing")
func writeBackAlreadyCarried() throws {
    let brief = try session(["prompt.txt": 0])
    let done = try session(["outcome.md": -60])
    #expect(!TaskMemory.isStale(sessionDir: brief, mates: [done]))
    #expect(!TaskMemory.isStale(sessionDir: brief, mates: []))
}

@Test("its own write-back is not a mate's, and a brief with no prompt is never stale")
func ownOutcomeAndNoPrompt() throws {
    let brief = try session(["prompt.txt": 0, "outcome.md": 60])
    #expect(!TaskMemory.isStale(sessionDir: brief, mates: []))
    let unrendered = try session([:])
    let done = try session(["outcome.md": 60])
    #expect(!TaskMemory.isStale(sessionDir: unrendered, mates: [done]))
}

// ── the sorting switch ──────────────────────────────────────────────────────

@Test("sorting off gives the classifier no relay, not even the transcription one")
func sortingOffHasNoClassifyVars() {
    let base = ["PATH": "/usr/bin", "DEIKO_RELAY_URL": "https://relay.example",
                "DEIKO_CLASSIFY_URL": "https://inherited.example", "DEIKO_CLASSIFY_TOKEN": "inherited"]
    let off = Sorting.environment(base, relay: "https://relay.example", on: false) { "dev_1" }
    #expect(off["DEIKO_CLASSIFY_URL"] == nil)
    #expect(off["DEIKO_CLASSIFY_TOKEN"] == nil)
    #expect(off["DEIKO_SORT_BRIEFS"] == "0")
    // Transcription's relay is not this switch's to take.
    #expect(off["DEIKO_RELAY_URL"] == "https://relay.example")
    #expect(off["PATH"] == "/usr/bin")
}

@Test("sorting on files through the relay, and only when there is one")
func sortingOnFilesThroughTheRelay() {
    let on = Sorting.environment(["DEIKO_SORT_BRIEFS": "0"], relay: "https://relay.example", on: true) { "dev_1" }
    #expect(on["DEIKO_CLASSIFY_URL"] == "https://relay.example")
    #expect(on["DEIKO_CLASSIFY_TOKEN"] == "dev_1")
    #expect(on["DEIKO_SORT_BRIEFS"] == nil)
    let none = Sorting.environment([:], relay: nil, on: true) { "dev_1" }
    #expect(none["DEIKO_CLASSIFY_URL"] == nil)
    #expect(none["DEIKO_CLASSIFY_TOKEN"] == nil)
}

@Test("somebody on their own key is told about filing once, and only while it happens")
func sortingNoticeOnce() throws {
    let name = "deiko-notice-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(!Sorting.noticeDue(ownKey: false, files: true, defaults: defaults))
    #expect(!Sorting.noticeDue(ownKey: true, files: false, defaults: defaults))
    #expect(Sorting.noticeDue(ownKey: true, files: true, defaults: defaults))
    #expect(!Sorting.noticeDue(ownKey: true, files: true, defaults: defaults))
}
