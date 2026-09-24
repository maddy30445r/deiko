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
