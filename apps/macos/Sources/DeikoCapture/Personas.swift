import CryptoKit
import Foundation
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE PERSONAS FOLDER
//
// `~/Documents/Deiko/personas/<id>.md`, one file each, beside the sessions they
// shape. Files rather than a preferences blob because the whole feature is "a
// prompt you can own": a developer who wants to read one, diff it, put it in a
// repo or rewrite it in their own editor should not have to go through us.
//
// THE FILE ON DISK WINS. Every read compares the file against the digest we
// stored when we last wrote it; if they differ, somebody edited it by hand and
// that text becomes the persona — the form is put away rather than silently
// re-rendered over their work. Reset brings the form back. This is the one
// rule that makes a folder-of-files safe to also have a UI for.
//
// What lives in `UserDefaults` is the FORM (options, names, which one is the
// default) and the digests. What lives on disk is the prose. Neither can be
// reconstructed from the other, and only one of them is somebody's writing.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum Personas {

    private static let listKey = "DEIKO_PERSONAS"
    private static let defaultKey = "DEIKO_PERSONA_DEFAULT"
    private static let digestKey = "DEIKO_PERSONA_DIGESTS"

    /// Beside the sessions, not inside one. `Sessions`'s sweep only ever
    /// touches folders named like a timestamp, so this cannot age out.
    static var root: String { Sessions.defaultRoot + "/personas" }

    static func file(for id: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent("\(id).md")
    }

    // ── What exists ─────────────────────────────────────────────────────────

    /// Every persona, with hand-edited files already adopted.
    ///
    /// Seeding is additive and never destructive: a built-in the user deleted
    /// from the list stays gone, but a built-in this VERSION added appears.
    static func all() -> [Persona] {
        var list = stored()
        let known = Set(list.map(\.id))
        let seenBuiltIns = Set(UserDefaults.standard.stringArray(forKey: listKey + "_SEEDED") ?? [])
        for builtIn in Persona.builtIns where !known.contains(builtIn.id) && !seenBuiltIns.contains(builtIn.id) {
            list.append(builtIn)
        }
        UserDefaults.standard.set(Persona.builtIns.map(\.id), forKey: listKey + "_SEEDED")
        list = list.map(adoptHandEdit)
        save(list)
        return list
    }

    static var defaultID: String {
        get { UserDefaults.standard.string(forKey: defaultKey) ?? Persona.Base.qaTicket.builtInID }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey) }
    }

    /// The persona a new brief is written for. Nil only when the user has
    /// deleted every persona they had, which is allowed — a brief without one
    /// is the document Deiko always produced.
    static func current() -> Persona? {
        let list = all()
        return list.first { $0.id == defaultID } ?? list.first
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    static func save(_ list: [Persona]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    /// Render a persona to its file and remember what we wrote.
    ///
    /// The digest is of OUR text, so the next read can tell "unchanged since
    /// Deiko wrote it" from "somebody has been in here".
    @discardableResult
    static func write(_ persona: Persona) -> URL? {
        let url = file(for: persona.id)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let text = persona.markdown
            try text.write(to: url, atomically: true, encoding: .utf8)
            setDigest(persona.id, digest(text))
            return url
        } catch {
            Emit.log("persona: could not write \(url.lastPathComponent) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Point a session at the persona its brief should be written for.
    ///
    /// The same shape as `narration.override.txt`: a file beside the session
    /// that `render-brief.mjs` reads if it is there. Absent — no personas, or
    /// a brief rendered from the command line — the renderer behaves exactly
    /// as it did before this feature existed.
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
    }

    /// The file's contents, for a destination that cannot open a path.
    static func text(forSession sessionDir: String) -> String? {
        let pointer = URL(fileURLWithPath: sessionDir).appendingPathComponent("persona.txt")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // ── Hand edits ──────────────────────────────────────────────────────────

    /// Adopt whatever is on disk when it is not what we put there.
    private static func adoptHandEdit(_ persona: Persona) -> Persona {
        var persona = persona
        let url = file(for: persona.id)
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else {
            // Deleted — including by somebody tidying the folder. Put it back
            // from the form rather than losing the persona with the file.
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
