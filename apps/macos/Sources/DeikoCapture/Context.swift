import AppKit
import DeikoHandoff
import Foundation

// The memory on disk: flat files beside the sessions, following `persona.txt`'s arrangement.
//
//   <board>/collections.json   the projects a brief can land in
//   <board>/tasks.json         what each task is called
//   <board>/tasks/<id>.md      a task's note, compiled by `render-brief.mjs`, never written here
//   <session>/context.json     where this brief landed, its task, and how much work it looked like
//   <session>/classify.sent    stamped by `classify.mjs` before its POST (see `ClassifyRequest`)
//
// `packages/core/src/classify.mjs` writes `context.json`. The review card and the board rewrite it when
// a person corrects a guess and mark it `decidedBy: "you"`, which the classifier never overwrites.

struct SessionContext: Codable, Equatable {
    struct Confidence: Codable, Equatable {
        var collection: Double?
        var task: Double?
        var tier: Double?
    }

    /// A collection id, or nil for Unsorted.
    var collection: String?
    /// The task this brief belongs to: `t-<stamp>` of the brief that started it. Nil reads as its own task.
    var task: String?
    /// The earlier tasks `classify.mjs` could not choose between, likeliest first, while this brief is a
    /// new task; what the review card's "Carries on from which?" offers. Cleared when somebody places
    /// the task by hand (`setTask`, "Move to task"); picking a project leaves them.
    var candidates: [String]?
    /// `quick` / `medium` / `complex` / `reasoning` — see `TIERS` in
    /// `packages/core/src/lib/context.mjs`.
    var tier: String?
    var confidence = Confidence()
    /// `"jev"`, `"local"` (decided on this Mac, nothing sent: odds and ends or a short follow-up) or
    /// `"you"`. A person's answer is final: the classifier never re-sorts a brief somebody placed.
    var decidedBy: String = "you"
    var model: String?
    /// `"you"` once somebody picked the project by hand, `"jev"` when a hand placement of the task left
    /// the project as Deiko's guess. Separate from `decidedBy` because tapping a task chip is a hand
    /// placement too and must not turn a guessed project into a stated one. Absent on older contexts;
    /// see `isGuess`.
    var collectionBy: String?
    /// `"odds"` for odds and ends: too little said, or nothing Groq could make sense of, so no task.
    /// Cleared once somebody moves it to one.
    var pile: String?
    /// An earlier task this brief is related to but not part of, linked by the classifier instead of
    /// merged. The card says "Related to …".
    var related: String?
    /// Whether a person put this brief in its task by hand (task picker, "Which one?" chip, "None of
    /// these", "Move to task"). Scripts treat it as firm filing, separately from `decidedBy`: a
    /// collection-only change never sets it. `placeTask` is the only setter.
    var taskBy: String?
    /// `"reference"` when Deiko joined this brief to its task because the
    /// brief pointed back at that work ("in that task", "the fix we did…").
    /// Read-only here: `classify.mjs` writes it, the card explains the join.
    var because: String?

    var isOdds: Bool { pile == "odds" }

    /// Put the brief in a project by hand.
    mutating func placeCollection(_ id: String?) {
        collection = id
        decidedBy = "you"
        collectionBy = "you"
    }

    /// Put the brief in a task by hand. The candidates go, since this answers their question, and how
    /// the project was decided is recorded first so `decidedBy` reads neither as a pick of Deiko's guess
    /// nor as a guess at somebody's pick.
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

    /// The keys this type owns. Every other key in the file (such as `jev`, where `classify.mjs` logs
    /// probabilities and the shortlist) is written back exactly as it was read.
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

    /// Records in `jev.correctedRank` where the task somebody picked sat on the classifier's shortlist.
    /// Only when a shortlist was logged; anything else is left untouched.
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

    /// Above this the answer is stated; below it, hedged. The floors that decide whether an answer is
    /// taken at all live in `packages/core/src/lib/context.mjs`; this one only affects wording.
    static let sureEnough = 0.85

    /// Whether the collection was the classifier's guess rather than a sure thing or a person's choice;
    /// the card marks it so a correction reads as invited.
    var isGuess: Bool {
        // Older contexts: no `collectionBy` with `decidedBy: "you"` means a project picked by hand.
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

    /// What the size label means, on hover. It only becomes a line in the brief when "Mention when a
    /// brief looks quick" is on; the agent still decides for itself.
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

/// Every key may be missing: odds and ends are written as `{ pile, decidedBy }` alone, and a synthesized
/// decoder would fail the whole file over one absent `confidence`. In an extension so the memberwise
/// initializer stays.
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
        because = try c.decodeIfPresent(String.self, forKey: .because)
    }
}

/// Whether `classify.mjs` ever sent this session to the relay.
///
/// Deliberately not `SessionContext`: `context.json` may not exist (5xx, timeout, no network) or may show a
/// hand placement that won the race, yet the POST carrying the narration, summary and window titles had
/// already gone out. `classify.mjs` writes `classify.sent` immediately before its first POST so a claim
/// can never understate what left the Mac (see `SessionClaims`).
///
/// The marker also records whether the request carried a summary, because the card's summary can arrive
/// after the request left without one. A bare-timestamp marker reads as "it did": the line may
/// overstate, never understate.
enum ClassifyRequest {
    /// Nil when nothing went; otherwise whether a summary went with it, or with an earlier request for
    /// the same brief.
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
    /// One line the classifier reads as the option's description, such as "the mobile app, not the website".
    var hint: String = ""
    /// Standing rules every brief in this project carries ("we use pnpm"),
    /// one per line, at most five (see `buildPrompt` in packages/core/src/lib/prompt.mjs).
    var rules: [String]? = nil
}

enum Collections {

    /// Where the sessions are. `--out` moves them, and the scripts resolve `collections.json` from the
    /// session's own parent, so this must follow the recorder's root rather than the default. Set once at
    /// launch.
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

    /// The list to edit. `all()` reads an unreadable file as empty, which is right for showing chips but
    /// wrong for saving: it would write back a single row and lose every other project. Nil means
    /// refused and left as it is; a missing or empty file is a fresh list, as in `readListToRewrite` on
    /// the scripts' side.
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

    /// A collection id from its name. Mirrors `slug` in `packages/core/src/lib/context.mjs`; change both,
    /// since the classifier creates collections too.
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

    static func setRules(id: String, rules: [String]) {
        BoardLock.with {
            guard var list = editable(), let index = list.firstIndex(where: { $0.id == id }) else { return }
            let kept = rules.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            list[index].rules = kept.isEmpty ? nil : Array(kept.prefix(5))
            save(list)
        }
    }

    /// Several lines at once, one per line: a project's rules.
    @MainActor
    static func askLines(title: String, informative: String, value: [String], confirm: String) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informative
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 110)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.string = value.joined(separator: "\n")
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        alert.accessoryView = scroll
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return text.string.components(separatedBy: .newlines)
    }

    private static func describeLocked(id: String, hint: String) {
        guard var list = editable() else { return }
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].hint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        save(list)
    }

    /// Forget a collection. Sessions that pointed at it keep their `context.json` and read as Unsorted
    /// (see `SessionsStore.load`, which resolves an unclaimed id back to nil so they stay reachable from
    /// a chip). Nothing else on disk is touched.
    static func delete(id: String) {
        BoardLock.with {
            guard let list = editable() else { return }
            save(list.filter { $0.id != id })
        }
    }

    /// The one way to ask for a line of text, shared by every surface that names or describes a
    /// collection so the wording does not drift.
    ///
    /// Returns nil when cancelled, which is not the same as an empty string: clearing a description is a
    /// real answer.
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

/// One writer at a time for `tasks.json` and `collections.json`, using a lock folder beside them. Same
/// protocol as `withBoardLock` in `packages/core/src/lib/session-io.mjs`; change both. Waits up to three
/// seconds, then goes ahead anyway; a lock older than fifteen is from a crash and is broken.
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

    /// Keeps the list as it was before this change, beside it as `<name>.prev`: one step back if an edit
    /// goes wrong. Called under the lock, right before the list is rewritten.
    static func keepPrevious(_ file: URL) {
        let prev = file.appendingPathExtension("prev")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.copyItem(at: file, to: prev)
    }
}

/// Task titles, beside the collections. Membership is not here (it is each brief's `context.json`), so
/// this file only answers "what is it called".
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

    /// Name or rename a task, marked as named by you. Upserts: a task nobody has named yet has no row.
    /// Every other row is written back exactly as it was read (see `TaskTitles`).
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

/// A person's corrections to what Deiko remembers. "Forget" and "Edit" on a task's notes write
/// `tasks/<id>.overrides.json` (`{ forget: [line], edit: {line: replacement} }`, keyed by the line as
/// the agent wrote it), and every script applies it (`readOverrides` in packages/core/src/lib/tasks.mjs).
/// outcome.md is never touched, so every change can be taken back.
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

    @MainActor static func forget(_ line: String, in task: String) {
        var e = read(task)
        if !e.forget.contains(line) { e.forget.append(line) }
        save(e, task)
    }

    /// An empty replacement, or one the same as what the agent wrote, puts
    /// the original back.
    @MainActor static func edit(_ line: String, to text: String, in task: String) {
        var e = read(task)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        e.edit[line] = text.isEmpty || text == line ? nil : text
        save(e, task)
    }

    @MainActor static func bringBack(in task: String) {
        var e = read(task)
        e.forget = []
        save(e, task)
    }

    /// Writes the edits, then rebuilds the task notes at once because an agent may be reading one.
    @MainActor private static func save(_ e: Edits, _ task: String) {
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
        rebuild()
    }

    /// One rebuild at a time, with a final one after the last edit: two side-by-side runs could finish in
    /// either order and leave the older note written last.
    @MainActor private static var rebuilding = false
    @MainActor private static var again = false

    @MainActor private static func rebuild() {
        guard !rebuilding else { again = true; return }
        rebuilding = true
        Task {
            repeat {
                again = false
                await BriefPipeline.rebuildNotes()
            } while again
            rebuilding = false
        }
    }
}

/// "Pick this up" on a piece of work arms it: the next session the recorder starts is written into that
/// task as placed by you before anything renders, so filing leaves it be and its first prompt already
/// carries where the work stands. One brief, then it disarms.
@MainActor
final class PickUp: ObservableObject {
    static let shared = PickUp()
    @Published private(set) var task: String?
    /// The session it went to, until that session makes a brief or goes.
    private var placed: (dir: String, task: String)?

    func arm(_ task: String) { self.task = task }
    func cancel() { task = nil }

    /// A session discarded before it made a brief (Escape, too short): the
    /// promise "your next brief joins this work" still stands.
    func discarded(sessionDir: String) {
        guard let placed, placed.dir == sessionDir else { return }
        self.placed = nil
        task = task ?? placed.task
    }

    /// The recorder, with the folder of a session it just started.
    func place(sessionDir: String) {
        guard let task else { return }
        self.task = nil
        placed = (sessionDir, task)
        var context = SessionContext()
        // Its project is the work's own.
        context.placeCollection(SessionsStore.shared.items.first { $0.task == task && !$0.odds }?.collection)
        context.placeTask(task)
        try? context.write(sessionDir: sessionDir)
    }
}
