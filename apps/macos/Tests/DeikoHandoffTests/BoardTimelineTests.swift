import Foundation
import Testing
@testable import DeikoHandoff

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
// Fri 25 Sep 2026, 15:00 UTC.
private let now = Date(timeIntervalSince1970: 1_790_348_400)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

@Test("day headings: today, yesterday, this week, then the month")
func headings() {
    #expect(BoardTimeline.heading(for: ago(0.2), now: now, calendar: utc) == "Today")
    #expect(BoardTimeline.heading(for: ago(0.9), now: now, calendar: utc) == "Yesterday")
    #expect(BoardTimeline.heading(for: ago(6), now: now, calendar: utc) == "This week")
    #expect(BoardTimeline.heading(for: ago(7), now: now, calendar: utc).contains("September"))
    #expect(BoardTimeline.heading(for: ago(40), now: now, calendar: utc).contains("August"))
    #expect(BoardTimeline.heading(for: ago(300), now: now, calendar: utc).contains("2025"))
}

@Test("sections keep the order given and group runs under one heading")
func sections() {
    let dates = [ago(0.1), ago(0.2), ago(3), ago(4), ago(40)]
    let out = BoardTimeline.sections(dates, date: { $0 }, now: now, calendar: utc)
    #expect(out.map(\.title).prefix(2) == ["Today", "This week"])
    #expect(out.map(\.items.count) == [2, 2, 1])
}

@Test("a tag counts a task's briefs, never one set aside")
func workCounts() {
    let counts = BoardTimeline.workCounts(["t-1", "t-1", "t-2", nil, "t-1"])
    #expect(counts == ["t-1": 3, "t-2": 1])
}

@Test("only Deiko's own join of another task is announced")
func filedByDeiko() {
    #expect(BoardTimeline.filedByDeiko(decidedBy: "jev", taskBy: nil, task: "t-1", own: "t-2", odds: false))
    #expect(BoardTimeline.filedByDeiko(decidedBy: "local", taskBy: nil, task: "t-1", own: "t-2", odds: false))
    #expect(!BoardTimeline.filedByDeiko(decidedBy: "you", taskBy: "you", task: "t-1", own: "t-2", odds: false), "a hand placement")
    #expect(!BoardTimeline.filedByDeiko(decidedBy: "jev", taskBy: "you", task: "t-1", own: "t-2", odds: false), "undone or dragged")
    #expect(!BoardTimeline.filedByDeiko(decidedBy: "jev", taskBy: nil, task: "t-2", own: "t-2", odds: false), "its own task")
    #expect(!BoardTimeline.filedByDeiko(decidedBy: "jev", taskBy: nil, task: nil, own: "t-2", odds: false))
    #expect(!BoardTimeline.filedByDeiko(decidedBy: "local", taskBy: nil, task: "t-1", own: "t-2", odds: true), "odds and ends")
}

@Test("a drop joins the target's work, or starts it on the target")
func drop() {
    let counts = ["t-a": 3, "t-b": 1]
    let count = { (id: String) in counts[id] ?? 0 }
    // Onto work of three: joins it, target untouched.
    let join = BoardTimeline.drop(dragged: ("x", "t-x"), target: ("a2", "t-a", "t-a2", false), count: count)
    #expect(join?.task == "t-a" && join?.placeTarget == false)
    // Already there: nothing to do.
    #expect(BoardTimeline.drop(dragged: ("a1", "t-a"), target: ("a2", "t-a", "t-a2", false), count: count) == nil)
    // Onto itself: nothing.
    #expect(BoardTimeline.drop(dragged: ("b", "t-b"), target: ("b", "t-b", "t-b", false), count: count) == nil)
    // Onto a lone brief: its task becomes the work.
    let lone = BoardTimeline.drop(dragged: ("x", "t-x"), target: ("b", "t-b", "t-b", false), count: count)
    #expect(lone?.task == "t-b" && lone?.placeTarget == false)
    // Onto odds and ends: the target's own id, and the target placed too.
    let odds = BoardTimeline.drop(dragged: ("x", "t-x"), target: ("o", "t-o", "t-o", true), count: count)
    #expect(odds?.task == "t-o" && odds?.placeTarget == true)
}

@Test("the task note's where-it-stands and decided blocks, markers off")
func noteSections() {
    let note = """
    # Price bug
    build · 3 briefs · Sep 16–Sep 18 · updated from 20260918-162329
    Compiled by Deiko from each brief's outcome.md — edit those, not this file.

    ## Now
    Still open from Sep 18: the toast and the card disagree

    ## Decided
    - Sep 18: re-fetch after save, no optimistic update

    ## Briefs
    - Sep 18, "Thank you." · Google Chrome
    """
    let s = BoardTimeline.noteSections(note)
    #expect(s.now == ["Still open from Sep 18: the toast and the card disagree"])
    #expect(s.decided == ["Sep 18: re-fetch after save, no optimistic update"])
}
