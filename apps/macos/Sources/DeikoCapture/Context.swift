import AppKit
import DeikoHandoff
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE MEMORY, ON DISK
//
// Flat files, beside the sessions, following `persona.txt`'s arrangement:
//
//   <board>/collections.json   the projects a brief can land in
//   <board>/tasks.json         what each task is called
//   <board>/tasks/<id>.md      a task's note, compiled by
//                              `render-brief.mjs` and never
//                              written here
//   <session>/context.json               where this brief landed, which task
//                                        it belongs to, and how much work it
//                                        looked like
//   <session>/classify.sent              stamped by `classify.mjs` itself,
//                                        before its POST — see `ClassifyRequest`
//
// `scripts/classify.mjs` writes `context.json` from the classifier's answers;
// the review card and the board rewrite it when the developer corrects a
// guess, and mark it `decidedBy: "you"` so the classifier never overwrites a
// decision a person made. `render-brief.mjs` reads it. Nothing here talks to
// a network and nothing is indexed: the folder walk the board already does
// is the index.
// ─────────────────────────────────────────────────────────────────────────────

struct SessionContext: Codable, Equatable {
    struct Confidence: Codable, Equatable {
        var collection: Double?
        var task: Double?
        var tier: Double?
    }

    /// A collection id, or nil for Unsorted.
    var collection: String?
    /// The task this brief belongs to — `t-<stamp>` of the brief that started
    /// it. Nil reads as its own task, which is what every brief was before
    /// tasks existed.
    var task: String?
    /// The earlier tasks `classify.mjs` could not choose between, likeliest
    /// first, while this brief is a new task — what the review card's
    /// "Carries on from which?" offers. Gone the moment somebody places the
    /// TASK by hand (`setTask`, the board's "Move to task"); picking a
    /// project answers a different question and leaves them.
    var candidates: [String]?
    /// `quick` / `medium` / `complex` / `reasoning` — see `TIERS` in
    /// `scripts/lib/context.mjs`.
    var tier: String?
    var confidence = Confidence()
    /// `"jev"`, `"local"` (decided on this Mac, nothing sent — odds and ends
    /// or a short follow-up) or `"you"`. A person's answer is final: the
    /// classifier never re-sorts a brief somebody placed, task or project.
    var decidedBy: String = "you"
    var model: String?
    /// `"you"` once somebody picked the project by hand, `"jev"` once a
    /// hand placement of the TASK had to say the project was still Deiko's
    /// guess. Separate from `decidedBy` because tapping a task chip is a hand
    /// placement too, and it must not turn a guessed project into a stated
    /// one. Absent on contexts from before it existed — see `isGuess`.
    var collectionBy: String?
    /// `"odds"` for odds and ends: too little said, or nothing Groq could
    /// make sense of, so no task. Gone once somebody moves it to one.
    var pile: String?
    /// An earlier task this brief is RELATED to but not part of — linked by
    /// the classifier instead of merged. The card says "Related to …".
    var related: String?
    /// Whether a person put this brief in its task BY HAND — the task
    /// picker, the "Which one?" chip, "None of these", or "Move to task" on
    /// the board. Scripts treat a brief as firm filing on this, separately
    /// from `decidedBy`: a collection-only change never sets it. See
    /// `placeTask`, the one place that does.
    var taskBy: String?

    var isOdds: Bool { pile == "odds" }

    /// Put the brief in a project by hand.
    mutating func placeCollection(_ id: String?) {
        collection = id
        decidedBy = "you"
        collectionBy = "you"
    }

    /// Put the brief in a task by hand. That answers the question the
    /// candidates were asking, so they go; and how the project was decided is
    /// written down first, so the `decidedBy` this sets reads neither as a
    /// pick of Deiko's guess nor as a guess at somebody's pick.
    mutating func placeTask(_ id: String) {
        collectionBy = collectionBy ?? (decidedBy == "you" ? "you" : "jev")
        task = id
        decidedBy = "you"
        taskBy = "you"
        candidates = nil
        pile = nil
        if related == id { related = nil }
    }

    static func path(sessionDir: String) -> URL {
        URL(fileURLWithPath: sessionDir).appendingPathComponent("context.json")
    }

    static func read(sessionDir: String) -> SessionContext? {
        guard let data = try? Data(contentsOf: path(sessionDir: sessionDir)) else { return nil }
        return try? JSONDecoder().decode(SessionContext.self, from: data)
    }

    /// The keys this type owns. Every other key in the file — `jev`, where
    /// `classify.mjs` logs each probability and the shortlist for tuning —
    /// is written back exactly as it was read. A hand placement used to drop
    /// that log on the floor.
    private static let ownKeys = [
        "collection", "task", "candidates", "tier", "confidence", "decidedBy",
        "model", "collectionBy", "pile", "related", "taskBy",
    ]

    func write(sessionDir: String) throws {
        let url = Self.path(sessionDir: sessionDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let disk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        let mine = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any] ?? [:]
        let merged = TaskFiling.merge(disk: disk, mine: mine, ownKeys: Self.ownKeys)
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        if decidedBy == "you" { FilingQueue.settle(sessionDir) }
    }

    /// Note, in `jev.correctedRank`, where the task somebody picked sat on the
    /// classifier's shortlist. Only for a v3 filing (one that logged a
    /// shortlist); anything else is left untouched.
    static func noteCorrection(sessionDir: String, task: String) {
        let url = path(sessionDir: sessionDir)
        guard var doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              var jev = doc["jev"] as? [String: Any],
              let shortlist = jev["shortlist"] as? [String]
        else { return }
        let own = Tasks.own((sessionDir as NSString).lastPathComponent)
        jev["correctedRank"] = TaskFiling.correctedRank(task: task, own: own, shortlist: shortlist)
        doc["jev"] = jev
        guard let data = try? JSONSerialization.data(
            withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Whether the collection was the classifier's guess rather than a sure
    /// thing or a person's choice — the case the card marks so a correction
    /// reads as invited.
    /// Above this the answer is stated; below it, hedged. The floors that
    /// decide whether an answer is taken at all live in
    /// `scripts/lib/context.mjs`; this one is only ever about wording, so it
    /// lives where the wording does.
    static let sureEnough = 0.85

    var isGuess: Bool {
        // No `collectionBy` and `decidedBy: "you"` is a project picked by hand
        // before `collectionBy` existed, when a pick was the only way to get it.
        let picked = collectionBy == "you" || (collectionBy == nil && decidedBy == "you")
        return !picked && collection != nil && (confidence.collection ?? 1) < Self.sureEnough
    }

    /// The tier, in the words the card uses.
    var tierLabel: String? {
        switch tier {
        case "quick": return "Quick one"
        case "medium": return "A short one"
        case "complex": return "Needs digging"
        case "reasoning": return "Needs a thinker"
        default: return nil
        }
    }

    /// What the size label means, on hover. Deiko's guess at how big the
    /// ask is — it only ever becomes a line in the brief when "Mention when a
    /// brief looks quick" is on, and the agent still decides for itself.
    var tierHelp: String? {
        let tail = " Deiko's guess from what you said; your agent still decides for itself."
        switch tier {
        case "quick": return "Quick one: a small, clear change, like a label, a colour or a one-line fix. A fast model will likely do." + tail
        case "medium": return "A short one: a contained change to a feature or two, a few minutes of work." + tail
        case "complex": return "Needs digging: the agent will have to read around the code and work out the cause before changing anything." + tail
        case "reasoning": return "Needs a thinker: an open question or a design decision, worth the agent's most careful model." + tail
        default: return nil
        }
    }
}

/// EVERY KEY MAY BE MISSING. Odds and ends are written as `{ pile, decidedBy }`
/// alone, and a synthesized decoder fails the whole file over one absent
/// `confidence`, losing the task and project with it. In an extension, so the
/// memberwise initializer stays.
extension SessionContext {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decodeIfPresent(String.self, forKey: .collection)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        candidates = try c.decodeIfPresent([String].self, forKey: .candidates)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence) ?? Confidence()
        decidedBy = try c.decodeIfPresent(String.self, forKey: .decidedBy) ?? "you"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        collectionBy = try c.decodeIfPresent(String.self, forKey: .collectionBy)
        pile = try c.decodeIfPresent(String.self, forKey: .pile)
        related = try c.decodeIfPresent(String.self, forKey: .related)
        taskBy = try c.decodeIfPresent(String.self, forKey: .taskBy)
    }
}

/// Whether `classify.mjs` ever sent this session to the relay.
///
/// NOT `SessionContext`. `context.json` might not exist at all — two 5xx in a
/// row, a timeout, no network — or it might exist with `model: nil` and
/// `decidedBy: "you"` because a hand placement raced the answer back and won.
/// Either way the POST that carried the narration, the summary and the
/// window titles had already gone out by the time any of that happened, so
/// asking `context.json` "was this filed?" can answer "no" for a session
/// whose words already left — exactly the understatement `SessionClaims`
/// exists to prevent. `classify.mjs` writes `classify.sent` immediately
/// before its first POST for that reason, and here it is read back.
///
/// The marker also says whether the request carried a summary, because the
/// card's summary can arrive after the request left without one. A marker
/// from before that was recorded is a bare timestamp, read as "it did" — the
/// line may overstate by two words, never understate.
enum ClassifyRequest {
    /// Nil when nothing went. Otherwise whether a summary went with it — or
    /// with an earlier request for the same brief.
    static func sentSummary(sessionDir: String) -> Bool? {
        struct Record: Decodable { let summary: Bool }
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: sessionDir).appendingPathComponent("classify.sent")
        ) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.summary ?? true
    }
}

struct Collection: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// One line the classifier reads as the option's description — "the
    /// mobile app, not the website". The cheapest accuracy there is.
    var hint: String = ""
}

enum Collections {

    /// Where the sessions are. `--out` moves them, and the scripts resolve
    /// `collections.json` from the session's own parent — so pinning this to
    /// the default root meant the classifier's collections and the app's were
    /// two different files, and the card showed "Unsorted" for a brief that
    /// had been filed. Set once at launch beside the recorder's root.
    nonisolated(unsafe) static var root = Sessions.defaultRoot

    static var file: URL {
        URL(fileURLWithPath: root).appendingPathComponent("collections.json")
    }

    static func all() -> [Collection] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Collection].self, from: data)) ?? []
    }

    static func name(for id: String?) -> String? {
        guard let id else { return nil }
        return all().first { $0.id == id }?.name
    }

    /// The list to EDIT. `all()` reads an unreadable file as empty, which is
    /// right for showing chips and wrong for saving: adding one project to
    /// that "empty" list used to write it back with a single row, and every
    /// other project was gone. Nil here means refused, left as it is. Missing
    /// or empty (a crash already lost it) is a fresh list, as in
    /// `readListToRewrite` on the scripts' side.
    private static func editable() -> [Collection]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file) else { return nil }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let list = try? JSONDecoder().decode([Collection].self, from: data) else {
            Emit.log("collections: \(file.lastPathComponent) is unreadable — left as it is rather than overwritten")
            return nil
        }
        return list
    }

    /// A collection id from its name. MIRRORS `slug` in `scripts/lib/context.mjs`:
    /// the classifier creates collections too, and the two must agree on what
    /// "Deiko" is called.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "collection" : out
    }

    /// Add a collection by name, or return the one that already has it.
    @discardableResult
    static func add(name raw: String) -> Collection? { BoardLock.with { addLocked(name: raw) } }

    private static func addLocked(name raw: String) -> Collection? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var list = editable() else { return nil }
        if let existing = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let id = slug(name)
        if let clash = list.first(where: { $0.id == id }) { return clash }
        let made = Collection(id: id, name: name)
        list.append(made)
        return save(list) ? made : nil
    }

    static func rename(id: String, to raw: String) { BoardLock.with { renameLocked(id: id, to: raw) } }

    private static func renameLocked(id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var list = editable() else { return }
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = name
        save(list)
    }

    static func describe(id: String, hint: String) { BoardLock.with { describeLocked(id: id, hint: hint) } }

    private static func describeLocked(id: String, hint: String) {
        guard var list = editable() else { return }
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        save(list)
    }

    /// Forget a collection. Sessions that pointed at it keep their
    /// `context.json` and read as Unsorted — see `SessionsStore.load`, which
    /// resolves an id no collection claims back to nil so those briefs stay
    /// reachable from a chip rather than from the All list alone. Nothing
    /// else on disk is touched.
    static func delete(id: String) {
        BoardLock.with {
            guard let list = editable() else { return }
            save(list.filter { $0.id != id })
        }
    }

    /// ONE WAY TO ASK FOR A LINE OF TEXT, because three surfaces need it —
    /// naming a collection from the review card, naming one from a board
    /// card, renaming and describing one from its chip — and three
    /// hand-rolled alerts drift into three different wordings of the same
    /// question.
    ///
    /// Returns nil when cancelled, which is not the same as an empty string:
    /// clearing a description is a real answer.
    @MainActor
    static func askText(
        title: String, informative: String, value: String = "",
        placeholder: String, confirm: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        // The caret starts in the field, so the first keystroke types rather
        // than ringing the system bell.
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name a new collection and make it. Nil when cancelled or left blank.
    @MainActor
    static func ask(prefill: String?, informative: String) -> Collection? {
        guard let name = askText(
            title: "New project",
            informative: informative,
            value: prefill ?? "",
            placeholder: "Project name",
            confirm: "Create"
        ), !name.isEmpty else { return nil }
        return add(name: name)
    }

    @discardableResult
    private static func save(_ list: [Collection]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            BoardLock.keepPrevious(file)
            try encoder.encode(list).write(to: file, options: .atomic)
            return true
        } catch {
            Emit.log("collections: could not write \(file.lastPathComponent) — \(error.localizedDescription)")
            return false
        }
    }
}

struct BriefTask: Decodable, Identifiable, Equatable {
    let id: String
    var title: String
    /// "you" when you named it; the scripts write "summary" or "narration".
    var from: String?
}

/// ONE WRITER AT A TIME for `tasks.json` and `collections.json`, shared with
/// the scripts (`withBoardLock` in `scripts/lib/session-io.mjs`): a lock folder
/// beside them. Waits up to three seconds, then goes ahead anyway; a lock older
/// than fifteen was left by a crash and is broken.
enum BoardLock {
    static func with<T>(_ body: () -> T) -> T {
        let url = URL(fileURLWithPath: Collections.root).appendingPathComponent(".lists.lock")
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(3)
        var held = false
        while !held {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                held = true
            } catch {
                // Not "someone holds it" (no board folder yet, no permission): go ahead.
                guard fm.fileExists(atPath: url.path) else { break }
                if let made = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(made) > 15 {
                    try? fm.removeItem(at: url)
                    continue
                }
                if Date() > deadline { break }
                usleep(25_000)
            }
        }
        defer { if held { try? fm.removeItem(at: url) } }
        return body()
    }

    /// The list as it was before this change, beside it as `<name>.prev`:
    /// one step back when an edit goes wrong. Called under the lock, right
    /// before the list is rewritten.
    static func keepPrevious(_ file: URL) {
        let prev = file.appendingPathExtension("prev")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.copyItem(at: file, to: prev)
    }
}

/// Task titles, beside the collections. Membership is not here — it is each
/// brief's `context.json` — so this file only ever answers "what is it called".
enum Tasks {
    static var file: URL {
        URL(fileURLWithPath: Collections.root).appendingPathComponent("tasks.json")
    }

    /// The task a brief is when nobody has put it in another one.
    static func own(_ stamp: String) -> String { "t-" + stamp }

    /// Row by row: one row this app cannot read costs that row, not every
    /// task's name.
    static func all() -> [BriefTask] {
        struct Row: Decodable {
            let task: BriefTask?
            init(from decoder: Decoder) throws { task = try? BriefTask(from: decoder) }
        }
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap(\.task)
    }

    /// Name or rename a task, marked as named by you. Upserts: a task nobody
    /// has named yet has no row. Every other row is written back exactly as
    /// it was read — see `TaskTitles`.
    static func name(_ id: String, _ raw: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        BoardLock.with { nameLocked(id, title) }
    }

    private static func nameLocked(_ id: String, _ title: String) {
        guard let data = TaskTitles.renaming(try? Data(contentsOf: file), id: id, to: title) else {
            Emit.log("tasks: \(file.lastPathComponent) is not a list — left as it is rather than overwritten")
            return
        }
        do {
            BoardLock.keepPrevious(file)
            try data.write(to: file, options: .atomic)
        } catch {
            Emit.log("tasks: could not write \(file.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Compiled by `render-brief.mjs` for tasks of two briefs or more.
    static func notePath(for id: String) -> URL {
        URL(fileURLWithPath: Collections.root).appendingPathComponent("tasks/\(id).md")
    }
}

/// WHAT DEIKO REMEMBERS, AS YOU CORRECTED IT. "Forget" and "Edit" on a task's
/// notes write `tasks/<id>.overrides.json` — `{ forget: [line], edit: {line:
/// replacement} }`, keyed by the line as the agent wrote it — and every
/// script applies it (`readOverrides` in scripts/lib/tasks.mjs): the note,
/// the next prompt, filing, the memory helper. outcome.md is never touched,
/// so the history stays and every change can be taken back.
enum TaskMemoryEdits {
    typealias Edits = MemoryEdits

    static func file(_ task: String) -> URL {
        Tasks.notePath(for: task).deletingLastPathComponent().appendingPathComponent("\(task).overrides.json")
    }

    /// Every task's edits at once, for a board load.
    static func all() -> [String: Edits] {
        let dir = Tasks.notePath(for: "x").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, Edits)? in
            guard name.hasSuffix(".overrides.json") else { return nil }
            let task = String(name.dropLast(".overrides.json".count))
            return (task, read(task))
        })
    }

    static func read(_ task: String) -> Edits {
        (try? JSONDecoder().decode(Edits.self, from: Data(contentsOf: file(task)))) ?? Edits()
    }

    static func forget(_ line: String, in task: String) {
        var e = read(task)
        if !e.forget.contains(line) { e.forget.append(line) }
        save(e, task)
    }

    /// An empty replacement, or one the same as what the agent wrote, puts
    /// the original back.
    static func edit(_ line: String, to text: String, in task: String) {
        var e = read(task)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        e.edit[line] = text.isEmpty || text == line ? nil : text
        save(e, task)
    }

    static func bringBack(in task: String) {
        var e = read(task)
        e.forget = []
        save(e, task)
    }

    /// Then the task notes are rebuilt at once: an agent may be reading one.
    private static func save(_ e: Edits, _ task: String) {
        let url = file(task)
        do {
            if e.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(e).write(to: url, options: .atomic)
            }
        } catch {
            Emit.log("tasks: could not save the edits to \(url.lastPathComponent) — \(error.localizedDescription)")
        }
        Task.detached { await BriefPipeline.rebuildNotes() }
    }
}
