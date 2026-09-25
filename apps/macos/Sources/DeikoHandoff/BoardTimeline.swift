import Foundation

/// The board as a timeline: newest first under day headings, each brief
/// wearing a tag for the work it belongs to. Pure, so it is tested without a
/// board on disk — see `TaskFiling`.
public enum BoardTimeline {

    /// "Today", "Yesterday", "This week" (the five days before that), then
    /// the month — with its year only when it is not this one.
    public static func heading(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if daysAgo <= 0 { return "Today" }
        if daysAgo == 1 { return "Yesterday" }
        if daysAgo < 7 { return "This week" }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMM" : "MMMM yyyy"
        )
        return format.string(from: date)
    }

    /// Runs of items under one heading, in the order given (newest first).
    public static func sections<T>(
        _ items: [T], date: (T) -> Date, now: Date, calendar: Calendar = .current
    ) -> [(title: String, items: [T])] {
        var out: [(title: String, items: [T])] = []
        for item in items {
            let title = heading(for: date(item), now: now, calendar: calendar)
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    /// Briefs per task. Nil is a brief set aside — odds and ends, or a
    /// recording that never finished — which is in no task. A tag is worn
    /// only where this says 2 or more.
    public static func workCounts(_ tasks: [String?]) -> [String: Int] {
        tasks.reduce(into: [:]) { tally, task in if let task { tally[task, default: 0] += 1 } }
    }

    /// Whether Deiko put this brief in another brief's task on its own — the
    /// case the card announces as "Added to … · Undo". Its own task, a hand
    /// placement or odds and ends is nothing to announce.
    public static func filedByDeiko(decidedBy: String?, taskBy: String?, task: String?, own: String, odds: Bool) -> Bool {
        guard !odds, taskBy != "you", let task, task != own else { return false }
        return decidedBy == "jev" || decidedBy == "local"
    }

    /// Where a brief dropped on `target` goes. Into the target's task when
    /// that is already work of two or more; otherwise the target starts one
    /// under its own id — placed there too when it was set aside, so both
    /// leave odds and ends together. `nil` when there is nothing to do.
    public static func drop(
        dragged: (id: String, task: String),
        target: (id: String, task: String, own: String, setAside: Bool),
        count: (String) -> Int
    ) -> (task: String, placeTarget: Bool)? {
        guard dragged.id != target.id else { return nil }
        if !target.setAside, count(target.task) >= 2 {
            return dragged.task == target.task ? nil : (target.task, false)
        }
        return target.setAside ? (target.own, true) : (target.task, false)
    }

    /// The `## Now` and `## Decided` blocks of a compiled task note
    /// (`tasks/<id>.md`, written by `render-brief.mjs`), list markers off.
    public static func noteSections(_ markdown: String) -> (now: [String], decided: [String]) {
        var now: [String] = [], decided: [String] = []
        var into: String?
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { into = String(line.dropFirst(3)); continue }
            guard !line.isEmpty else { continue }
            let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            if into == "Now" { now.append(text) } else if into == "Decided" { decided.append(text) }
        }
        return (now, decided)
    }
}
