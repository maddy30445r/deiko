import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE MEMORY, ON DISK
//
// Flat files, beside the sessions, following `persona.txt`'s arrangement:
//
//   ~/Documents/Deiko/collections.json   the projects a brief can land in
//   ~/Documents/Deiko/tasks.json         what each task is called
//   ~/Documents/Deiko/tasks/<id>.md      a task's note, compiled by
//                                        `render-brief.mjs` and never
//                                        written here
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
    /// `"jev"` or `"you"`. A person's answer is final: the classifier never
    /// re-sorts a brief somebody placed, task or project.
    var decidedBy: String = "you"
    var model: String?
    /// `"you"` once somebody picked the project by hand. Separate from
    /// `decidedBy` because tapping a task chip is a hand placement too, and it
    /// must not turn Deiko's guess at the project into a stated answer.
    var collectionBy: String?

    static func path(sessionDir: String) -> URL {
        URL(fileURLWithPath: sessionDir).appendingPathComponent("context.json")
    }

    static func read(sessionDir: String) -> SessionContext? {
        guard let data = try? Data(contentsOf: path(sessionDir: sessionDir)) else { return nil }
        return try? JSONDecoder().decode(SessionContext.self, from: data)
    }

    func write(sessionDir: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.path(sessionDir: sessionDir), options: .atomic)
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
        collectionBy != "you" && collection != nil && (confidence.collection ?? 1) < Self.sureEnough
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
/// before its first POST for that reason; this only checks it exists.
enum ClassifyRequest {
    static func wasSent(sessionDir: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: sessionDir).appendingPathComponent("classify.sent").path
        )
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
    static func add(name raw: String) -> Collection? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var list = all()
        if let existing = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let id = slug(name)
        if let clash = list.first(where: { $0.id == id }) { return clash }
        let made = Collection(id: id, name: name)
        list.append(made)
        return save(list) ? made : nil
    }

    static func rename(id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var list = all()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = name
        save(list)
    }

    static func describe(id: String, hint: String) {
        var list = all()
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
        save(all().filter { $0.id != id })
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
            title: "New collection",
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
            try encoder.encode(list).write(to: file, options: .atomic)
            return true
        } catch {
            Emit.log("collections: could not write \(file.lastPathComponent) — \(error.localizedDescription)")
            return false
        }
    }
}

struct BriefTask: Codable, Identifiable, Equatable {
    let id: String
    var title: String
}

/// Task titles, beside the collections. Membership is not here — it is each
/// brief's `context.json` — so this file only ever answers "what is it called".
enum Tasks {
    static var file: URL {
        URL(fileURLWithPath: Collections.root).appendingPathComponent("tasks.json")
    }

    /// The task a brief is when nobody has put it in another one.
    static func own(_ stamp: String) -> String { "t-" + stamp }

    static func all() -> [BriefTask] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([BriefTask].self, from: data)) ?? []
    }

    /// Name or rename a task. Upserts: a task nobody has named yet has no row.
    static func name(_ id: String, _ raw: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var list = all()
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].title = title
        } else {
            list.append(BriefTask(id: id, title: title))
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(list).write(to: file, options: .atomic)
        } catch {
            Emit.log("tasks: could not write \(file.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Compiled by `render-brief.mjs` for tasks of two briefs or more.
    static func notePath(for id: String) -> URL {
        URL(fileURLWithPath: Collections.root).appendingPathComponent("tasks/\(id).md")
    }
}
