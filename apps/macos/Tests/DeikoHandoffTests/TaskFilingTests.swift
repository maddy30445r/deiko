import Foundation
import Testing
@testable import DeikoHandoff

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_790_000_000)

@Test("a task's age is said only when its newest brief is over a day old")
func agePhrase() {
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-0.5 * day), to: now) == nil)
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-1 * day), to: now) == nil)
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-1.5 * day), to: now) == "yesterday")
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-3 * day), to: now) == "3 days ago")
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-10 * day), to: now) == "last week")
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-21 * day), to: now) == "3 weeks ago")
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-45 * day), to: now) == "last month")
    #expect(TaskFiling.agePhrase(from: now.addingTimeInterval(-90 * day), to: now) == "3 months ago")
}

@Test("a correction notes where the chosen task sat on the shortlist")
func correctedRank() {
    let shortlist = ["t-20260918-100000", "t-20260918-110000"]
    #expect(TaskFiling.correctedRank(task: "t-20260918-110000", own: "t-20260920-100000", shortlist: shortlist) == "2")
    #expect(TaskFiling.correctedRank(task: "t-20260920-100000", own: "t-20260920-100000", shortlist: shortlist) == "new")
    #expect(TaskFiling.correctedRank(task: "t-20260901-100000", own: "t-20260920-100000", shortlist: shortlist) == "missing")
}

@Test("an app rewrite keeps the classifier's log and replaces only its own keys")
func mergeKeepsTheLog() {
    let disk: [String: Any] = ["task": "t-20260918-100000", "candidates": ["t-1"], "jev": ["gate": 0.9], "tier": "quick"]
    let mine: [String: Any] = ["task": "t-20260918-110000", "decidedBy": "you", "tier": "quick"]
    let merged = TaskFiling.merge(disk: disk, mine: mine, ownKeys: ["task", "candidates", "decidedBy", "tier"])
    #expect(merged["task"] as? String == "t-20260918-110000")
    #expect(merged["decidedBy"] as? String == "you")
    #expect(merged["candidates"] == nil, "a hand placement clears Which one?")
    #expect((merged["jev"] as? [String: Any])?["gate"] as? Double == 0.9, "the log survives")
}

@Test("a hand TASK placement writes taskBy: you; a collection-only change never does")
func mergeWritesTaskByOnlyForHandTaskPlacement() {
    let disk: [String: Any] = ["task": "t-old", "decidedBy": "jev"]
    let ownKeys = ["task", "decidedBy", "collection", "taskBy"]

    // `placeTask` models `taskBy` in `mine`, so it lands on disk.
    let handTask: [String: Any] = ["task": "t-new", "decidedBy": "you", "taskBy": "you"]
    let afterTask = TaskFiling.merge(disk: disk, mine: handTask, ownKeys: ownKeys)
    #expect(afterTask["taskBy"] as? String == "you")

    // `placeCollection` never sets it, so it is absent from `mine` — which
    // `merge` reads as removed, same as any other own key nobody modelled.
    let collectionOnly: [String: Any] = ["task": "t-old", "decidedBy": "jev", "collection": "acme"]
    let afterCollection = TaskFiling.merge(disk: disk, mine: collectionOnly, ownKeys: ownKeys)
    #expect(afterCollection["taskBy"] == nil, "a collection-only change never sets taskBy")
}
