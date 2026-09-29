import CryptoKit
import Foundation
import DeikoHandoff

/// Persona files live in `<board>/personas/<id>.md`, one per persona, so they can be read, diffed and
/// edited in any editor.
///
/// The file on disk wins: every read compares it with the digest stored at the last write, and a
/// mismatch means it was hand-edited, so that text becomes the persona (Reset restores the form).
/// `UserDefaults` holds the form (options, names, default) and the digests; the disk holds the prose.
@MainActor
enum Personas {

    private static let listKey = "DEIKO_PERSONAS"
    private static let defaultKey = "DEIKO_PERSONA_DEFAULT"
    private static let digestKey = "DEIKO_PERSONA_DIGESTS"

    /// Beside the sessions, not inside one: `Sessions`'s sweep only touches timestamp-named folders,
    /// so this never ages out.
    static var root: String { Sessions.defaultRoot + "/personas" }

    static func file(for id: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent("\(id).md")
    }

    /// Every persona, with hand-edited files already adopted. Seeding only adds built-ins this
    /// version introduced.
    static func all() -> [Persona] {
        var list = retireBugReport(stored())
        let known = Set(list.map(\.id))
        // Additive is enough: `remove` refuses to delete a built-in, so one cannot go missing and return.
        for builtIn in Persona.builtIns where !known.contains(builtIn.id) {
            list.append(builtIn)
        }
        list = list.map(adoptHandEdit)
        save(list)
        return list
    }

    /// Removes the retired built-in "Bug report" persona, once. One whose file no longer matches its
    /// stored digest was edited by hand, so it is kept as an ordinary persona. The flag stops a persona
    /// recreated later under the same name from being removed.
    private static func retireBugReport(_ list: [Persona]) -> [Persona] {
        let done = "DEIKO_BUG_REPORT_RETIRED"
        guard !UserDefaults.standard.bool(forKey: done) else { return list }
        UserDefaults.standard.set(true, forKey: done)

        guard let leftover = list.first(where: { $0.id == "bug-report" }) else { return list }
        let url = file(for: leftover.id)
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        let untouched = onDisk == nil || digest(onDisk!) == storedDigest(leftover.id)
        guard untouched else {
            Emit.log("persona: kept a hand-edited bug-report.md — it is yours to delete")
            return list
        }

        try? FileManager.default.removeItem(at: url)
        if defaultID == leftover.id { defaultID = Persona.Base.qaTicket.builtInID }
        let kept = list.filter { $0.id != leftover.id }
        save(kept)
        Emit.log("persona: retired the built-in bug-report — a QA ticket writes the same document")
        return kept
    }

    static var defaultID: String {
        get { UserDefaults.standard.string(forKey: defaultKey) ?? Persona.Base.qaTicket.builtInID }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey) }
    }

    /// The persona a new brief is written for. Nil only when every persona has been deleted, which is allowed.
    static func current() -> Persona? {
        let list = all()
        return list.first { $0.id == defaultID } ?? list.first
    }

    static func save(_ list: [Persona]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    /// Render a persona to its file and remember what was written. The digest is of Deiko's own text,
    /// so the next read can tell an unchanged file from a hand edit.
    @discardableResult
    static func write(_ persona: Persona) -> URL? {
        let url = file(for: persona.id)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // From the cache, never a fresh read: this runs on the path that
            // renders a brief. See `AgentConfigs.connected`.
            let text = persona.markdown(connected: AgentConfigs.connectedTrackers)
            try text.write(to: url, atomically: true, encoding: .utf8)
            setDigest(persona.id, digest(text))
            return url
        } catch {
            Emit.log("persona: could not write \(url.lastPathComponent) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Point a session at the persona its brief should be written for: a file beside the session, like
    /// `narration.override.txt`, that `render-brief.mjs` reads if present.
    static func point(session sessionDir: String, to persona: Persona?) {
        let pointer = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.txt")
        guard let persona else {
            try? FileManager.default.removeItem(at: pointer)
            return
        }
        // Rewritten every time: the form may have changed since the last brief,
        // and a stale file would shape this one.
        guard let url = write(persona) else { return }
        try? url.path.write(to: pointer, atomically: true, encoding: .utf8)
        // The browser form, beside it. Written here rather than at release time: the fling has a tight
        // time budget and no business rendering a template.
        let brief = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.brief.txt")
        if let summary = persona.summary(connected: AgentConfigs.connectedTrackers) {
            try? summary.write(to: brief, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: brief)
        }
    }

    /// The persona file this session points at, for a destination that can take a document rather
    /// than prose. `nonisolated` because it touches no main-actor state.
    nonisolated static func file(forSession sessionDir: String) -> String? {
        let pointer = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.txt")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return path
    }

    /// What a browser gets: the short form when there is one, the whole file when the persona is
    /// hand-written (see `Persona.summary`).
    nonisolated static func browserText(forSession sessionDir: String) -> String? {
        let brief = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.brief.txt")
        if let short = try? String(contentsOf: brief, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !short.isEmpty {
            return short
        }
        return text(forSession: sessionDir)
    }

    nonisolated static func text(forSession sessionDir: String) -> String? {
        let pointer = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.txt")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Which persona this session will be written up as, read from the pointer beside it rather than
    /// the current default, which can change while a brief renders. The name comes from the file's own
    /// `# Heading`.
    nonisolated static func name(forSession sessionDir: String) -> String? {
        let pointer = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.txt")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
            let heading = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") })
        else { return nil }
        return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    /// Adopt whatever is on disk when it is not what we put there.
    private static func adoptHandEdit(_ persona: Persona) -> Persona {
        var persona = persona
        let url = file(for: persona.id)
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else {
            // Deleted, including by tidying the folder: restore it from the form rather than lose the persona.
            write(persona)
            return persona
        }
        let seen = digest(onDisk)
        guard seen != storedDigest(persona.id) else { return persona }
        persona.overrideText = onDisk
        setDigest(persona.id, seen)
        return persona
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func storedDigest(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: digestKey) as? [String: String])?[id]
    }

    private static func setDigest(_ id: String, _ value: String) {
        var all = (UserDefaults.standard.dictionary(forKey: digestKey) as? [String: String]) ?? [:]
        all[id] = value
        UserDefaults.standard.set(all, forKey: digestKey)
    }

    private static func stored() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([Persona].self, from: data)
        else { return Persona.builtIns }
        return list
    }
}
