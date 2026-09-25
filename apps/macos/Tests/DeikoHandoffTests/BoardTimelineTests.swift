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

@Test("an outcome, by its headings: agent named, fences skipped, other sections dropped")
func outcomeSections() {
    let o = BoardTimeline.outcome("""
    # Outcome
    **Agent:** Claude Code
    ## Did
    - Synced the price after save.
    ```md
    ## Open
    - not open
    ```
    ## Decided
    - Re-fetch after save, no optimistic update
    ## Summary
    A long recap.
    Next steps:
    - The listing page still caches the old price.
    ## Files touched
    src/Price.tsx
    """)
    #expect(o.agent == "Claude Code")
    #expect(o.did == ["Synced the price after save."])
    #expect(o.decided == ["Re-fetch after save, no optimistic update"])
    #expect(o.open == ["The listing page still caches the old price."])
    #expect(o.files == ["src/Price.tsx"])
    // No headings is all Did, and "#2" is text, not a heading.
    #expect(BoardTimeline.outcome("#2 still flaky\nFixed it.").did == ["#2 still flaky", "Fixed it."])
    #expect(BoardTimeline.outcomeLine("Agent: Codex\n## Open\nTest it.") == "Test it.")
}

@Test("what was asked: the summary's first line, else a sentence of narration, never cut mid-word")
func askedLine() {
    #expect(BoardTimeline.asked(summary: "Fix the tab.\nAnd the price.", narration: "x") == "Fix the tab.")
    // A summary that could not tell falls back to what was said.
    #expect(BoardTimeline.asked(summary: "Too short to tell what was asked.",
                                narration: "What is this site about? And the sitemap.") == "What is this site about?")
    #expect(BoardTimeline.asked(summary: nil, narration: "I") == nil)
    let long = String(repeating: "wordy ", count: 40)
    let cut = BoardTimeline.asked(summary: long, narration: nil)!
    #expect(cut.hasSuffix("wordy…") && cut.count <= BoardTimeline.askedLimit)
}

@Test("a work's state: open from the newest write-back, every decision, the last ask")
func workState() {
    let day = { (d: Double) in Date(timeIntervalSince1970: d * 86_400) }
    var older = BoardTimeline.Outcome(); older.open = ["stale"]; older.decided = ["keep the toast"]; older.agent = "Codex"
    var newer = BoardTimeline.Outcome(); newer.decided = ["re-fetch after save"]
    let s = BoardTimeline.workState([
        .init(date: day(1), asked: "First ask", outcome: older),
        .init(date: day(3), asked: nil, outcome: nil),
        .init(date: day(2), asked: "Second ask", outcome: newer),
    ])
    #expect(s.lastAsked?.text == "Second ask" && s.lastAsked?.date == day(2))
    #expect(s.open.isEmpty && s.wroteBack == day(2))
    #expect(s.decided.map(\.text) == ["re-fetch after save", "keep the toast"])
    #expect(s.decided.last?.agent == "Codex" && s.decided.last?.date == day(1))
    // Nobody wrote back: no notes, but still the last ask.
    let quiet = BoardTimeline.workState([.init(date: day(1), asked: "Only ask", outcome: nil)])
    #expect(quiet.wroteBack == nil && quiet.open.isEmpty && quiet.lastAsked?.text == "Only ask")
}

private func name(_ title: String?, named: Bool = false, pages: [String] = [], files: [String] = []) -> String {
    BoardTimeline.workNames([.init(id: "t", title: title, named: named, pages: pages, files: files)])["t"]!
}

@Test("a work name: yours, else the page or file, else the title's head")
func workNames() {
    // A name you gave wins, even over a page.
    #expect(name("Checkout copy", named: true, pages: ["Pricing"]) == "Checkout copy")
    #expect(name("The whole onboarding flow for new teams", named: true) == "The whole onboarding…")
    // The page said most, then the file.
    #expect(name("They want an explanation", pages: ["Signups", "Pricing", "Pricing"]) == "Pricing")
    #expect(name("Pricing | Acme Inc", pages: ["Pricing | Acme Inc"]) == "Pricing")
    #expect(name("They want an explanation of the content and what a sitemap XML is",
                 files: ["public/sitemap.xml"]) == "Sitemap")
    // The title's head, filler off.
    #expect(name("They want an explanation of the content and what a sitemap XML is") == "Content")
    #expect(name("Price display doesn’t update after editing – toast shows new value but UI stays…") == "Price display bug")
    #expect(name("Fix default tab to annual instead of monthly") == "Fix default tab")
    #expect(name("Match the card radius to the left one") == "Match the card radius")
    #expect(name("They’re confused why the week‑32 signup chart shows a drop while another chart…") == "Week‑32 signup chart")
    #expect(name("Okay, so we have some issues here that we need to solve.") == "Issues")
    // Nothing but filler: its first sentence as said.
    #expect(name("Explain this. What is this? What is this?") == "Explain this")
    #expect(name(nil) == "A task")
    // Never over the limit, never cut mid-word.
    for title in ["Supercalifragilistic expialidocious button spacing", "Please make the navigation drawer animation smoother"] {
        let n = name(title)
        #expect(n.count <= BoardTimeline.nameLimit, "\(n)")
        #expect(title.lowercased().contains(n.lowercased().replacingOccurrences(of: "…", with: "")), "\(n)")
    }
}

@Test("two tasks on one page are told apart by their titles")
func workNamesShared() {
    let names = BoardTimeline.workNames([
        .init(id: "a", title: "Price display doesn’t update after editing", named: false, pages: ["Catalogue"], files: []),
        .init(id: "b", title: "Fix the sort order of shoes", named: false, pages: ["Catalogue"], files: []),
        .init(id: "c", title: "Fix default tab to annual", named: false, pages: ["Pricing"], files: []),
    ])
    #expect(names == ["a": "Price display bug", "b": "Fix the sort order", "c": "Pricing"])
}

@Test("every set-aside brief folds, a lone one among real briefs included")
func fold() {
    // Lowercase is set aside.
    let out = BoardTimeline.fold(Array("abCdDefgH"), setAside: \.isLowercase)
    #expect(String(out.cards) == "CDH")
    #expect(String(out.folded) == "abdefg")
    #expect(String(BoardTimeline.fold(Array("Ca"), setAside: \.isLowercase).folded) == "a")
}
