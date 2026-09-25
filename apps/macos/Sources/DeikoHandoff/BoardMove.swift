import Foundation

/// THE BOARD MOVES ONCE: out of `~/Documents/Deiko`, which iCloud's Desktop &
/// Documents sync carries off the Mac, into Application Support.
///
/// Each entry is renamed across (the same volume, so it is instant), never
/// over something already there. Sessions store their paths absolute — a crop
/// in `events.jsonl` and `brief.json`, a persona in `persona.txt`, a note's
/// links — so every text file that names the old folder is rewritten to name
/// the new one. The old folder goes once it is empty.
public enum BoardMove {
    /// How many entries moved; 0 when there was no old folder.
    @discardableResult
    public static func run(from old: String, to new: String) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: old) else { return 0 }
        try? fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        var moved: [String] = []
        for name in names where name != ".DS_Store" && !fm.fileExists(atPath: "\(new)/\(name)") {
            if (try? fm.moveItem(atPath: "\(old)/\(name)", toPath: "\(new)/\(name)")) != nil { moved.append(name) }
        }
        for name in moved { rewrite("\(new)/\(name)", from: "\(old)/", to: "\(new)/") }
        if ((try? fm.contentsOfDirectory(atPath: old)) ?? []).allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(atPath: old)
        }
        return moved.count
    }

    /// Every text file at or under `path` that names `from`, rewritten to `to`.
    private static func rewrite(_ path: String, from: String, to: String) {
        let text: Set = ["json", "jsonl", "txt", "md"]
        let url = URL(fileURLWithPath: path)
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files + [url] where text.contains(file.pathExtension) {
            guard let body = try? String(contentsOf: file, encoding: .utf8), body.contains(from) else { continue }
            try? body.replacingOccurrences(of: from, with: to).write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
