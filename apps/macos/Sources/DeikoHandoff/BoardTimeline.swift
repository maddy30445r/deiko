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

    // ── Work names ──────────────────────────────────────────────────────────

    /// What a task's tag calls it. Task titles are summaries ("They want an
    /// explanation of the content and what a sitemap XML is"), which make a
    /// chip that reads "Added to They want an exp…"; a tag wants a name.
    public struct WorkSource: Sendable {
        public let id: String
        /// The task's title, or its first brief's when it has none.
        public let title: String?
        /// The title is one you gave it — it wins, whatever it says.
        public let named: Bool
        /// Every brief's `summary.keys.pages` and `.files`, repeats kept:
        /// the one said most is the place the work is about.
        public let pages: [String]
        public let files: [String]
        public init(id: String, title: String?, named: Bool, pages: [String], files: [String]) {
            self.id = id; self.title = title; self.named = named; self.pages = pages; self.files = files
        }
    }

    /// The longest a name runs, so a tag never truncates on a narrow card.
    public static let nameLimit = 22

    /// Task id → a short name: yours if you gave one; else the page or file
    /// the briefs are about ("Pricing", "Sitemap"); else the head of the
    /// title with its filler off ("Price display bug"). A place two tasks
    /// share would make two identical tags, so those two fall back to their
    /// titles.
    public static func workNames(_ works: [WorkSource]) -> [String: String] {
        let places = Dictionary(works.compactMap { w in place(w).map { (w.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let shared = Dictionary(places.values.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return Dictionary(works.map { w -> (String, String) in
            let title = w.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if w.named, !title.isEmpty { return (w.id, fit(title, ellipsis: true)) }
            if let place = places[w.id], shared[place.lowercased()] == 1 { return (w.id, place) }
            // All filler ("Explain this. What is this?"): its first sentence, as said.
            let said = title.components(separatedBy: CharacterSet(charactersIn: ".?!")).first ?? title
            return (w.id, phrase(title) ?? places[w.id] ?? (said.isEmpty ? "A task" : capitalized(fit(said, ellipsis: true))))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The page said most, else the file: "Pricing | Acme" → "Pricing",
    /// "src/sitemap.xml" → "Sitemap".
    static func place(_ w: WorkSource) -> String? {
        if let page = mostSaid(w.pages) {
            let head = page.components(separatedBy: [":", "|", "–", "—"]).first ?? page
            let name = fit(head.components(separatedBy: " - ").first ?? head, ellipsis: true)
            if !name.isEmpty { return name }
        }
        guard let file = mostSaid(w.files) else { return nil }
        let base = (file as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let name = fit(stem.isEmpty ? base : stem, ellipsis: true)
        return name.isEmpty ? nil : capitalized(name)
    }

    private static func mostSaid(_ values: [String]) -> String? {
        let clean = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tally = Dictionary(clean.map { ($0, 1) }, uniquingKeysWith: +)
        // First said wins a tie, so a name does not flip between loads.
        return clean.first { tally[$0] == tally.values.max() }
    }

    /// Words that open a summary or a sentence without naming anything.
    private static let filler: Set<String> = [
        "they", "they're", "theyre", "he", "she", "user", "users", "want", "wants", "wanted", "would", "like",
        "a", "an", "the", "explanation", "explain", "explains", "clarify", "understand", "please", "tell", "me",
        "can", "could", "you", "i", "i'm", "we", "we're", "need", "needs", "to", "so", "okay", "ok", "hey", "hi",
        "hello", "now", "it", "it's", "is", "are", "what", "what's", "why", "how", "does", "do", "this", "that",
        "these", "those", "confused", "about", "asking", "asks", "ask", "help", "with", "some", "have", "has",
        "there", "here", "just", "also", "let's", "of", "on", "in", "see", "as", "look", "looking", "at",
        "basically", "um", "uh", "yeah", "well", "mean", "means", "where",
    ]
    /// Where the name ends: the verb, the next clause, the next thought.
    private static let stops: Set<String> = [
        "and", "or", "but", "that", "which", "who", "because", "after", "before", "when", "while", "where",
        "why", "if", "so", "to", "for", "in", "on", "at", "with", "from", "instead", "into", "than", "is",
        "are", "was", "were", "be", "been", "has", "have", "had", "shows", "show", "showing", "looks", "seems",
        "should", "would", "will", "can", "could", "i", "we", "you", "now", "here", "there", "it", "its",
        "this", "what",
        // Hinglish connectives: narration mixes them in.
        "aur", "ki", "ka", "ke", "hai", "yeh", "ye", "mein", "ismein", "jo", "pe",
    ]
    /// A stop that says something is wrong: the name gets "bug".
    private static let faults: Set<String> = [
        "doesn't", "isn't", "won't", "can't", "don't", "didn't", "aren't", "wasn't", "not", "never",
        "broken", "fails", "failing", "wrong", "missing",
    ]
    private static let trailing: Set<String> = ["the", "a", "an", "of", "to", "for", "and", "my", "your", "our"]

    /// The head of a title, filler off: "Fix default tab to annual" → "Fix
    /// default tab"; "Price display doesn't update…" → "Price display bug".
    /// Nil when nothing but filler is left.
    static func phrase(_ title: String) -> String? {
        let clauseEnd = CharacterSet(charactersIn: ".,;:!?…")
        let quotes = CharacterSet(charactersIn: "\"'“”‘’()[]")
        func key(_ word: Substring) -> String {
            word.lowercased().replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: clauseEnd.union(quotes))
        }
        var words = title.split(whereSeparator: \.isWhitespace)
        while let first = words.first, filler.contains(key(first)) || key(first).isEmpty { words.removeFirst() }
        var taken: [String] = []
        var fault = false
        for word in words {
            if ["-", "–", "—"].contains(word) { break }
            let k = key(word)
            if stops.contains(k) || faults.contains(k) {
                if taken.isEmpty { continue }
                fault = faults.contains(k)
                break
            }
            taken.append(word.trimmingCharacters(in: clauseEnd.union(quotes)))
            if taken.count == 4 || word.unicodeScalars.last.map(clauseEnd.contains) == true { break }
        }
        while let last = taken.last, trailing.contains(last.lowercased()) { taken.removeLast() }
        taken.removeAll(where: \.isEmpty)
        guard !taken.isEmpty else { return nil }
        if fault, taken.count < 4 { taken.append("bug") }
        let name = fit(taken.joined(separator: " "), ellipsis: false)
        return name.isEmpty ? nil : capitalized(name)
    }

    /// At most `nameLimit` characters, whole words only. `ellipsis` marks
    /// words dropped from a name somebody chose. A single word too long for
    /// the tag is the one thing cut mid-word.
    static func fit(_ text: String, ellipsis: Bool) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > nameLimit else { return clean }
        let room = ellipsis ? nameLimit - 1 : nameLimit
        var words = clean.split(separator: " ").map(String.init)
        while words.count > 1, words.joined(separator: " ").count > room { words.removeLast() }
        while words.count > 1, let last = words.last, trailing.contains(last.lowercased()) { words.removeLast() }
        let kept = words.joined(separator: " ")
        if kept.count > room { return String(kept.prefix(nameLimit - 1)) + "…" }
        return ellipsis ? kept + "…" : kept
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
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
