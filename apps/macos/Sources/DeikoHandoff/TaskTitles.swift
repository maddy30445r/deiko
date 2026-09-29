import Foundation

/// A rename of one row of `tasks.json`, losing nothing else in the file.
///
/// The file is edited as JSON rather than decoded into the app's type, so a row
/// the app cannot decode, or a key it does not model, is kept as read.
///
/// In `DeikoHandoff` so it can be tested: `DeikoCapture` cannot be linked into
/// a test binary (see `SessionClaims`).
public enum TaskTitles {

    /// `existing` with task `id` titled `title`, marked `from: "you"` so
    /// `classify.mjs` never replaces it, and every other row exactly as read.
    /// Nil when `existing` is not a JSON list: refused, not overwritten.
    public static func renaming(_ existing: Data?, id: String, to title: String) -> Data? {
        var rows: [Any] = []
        if let existing, !existing.isEmpty {
            guard let read = (try? JSONSerialization.jsonObject(with: existing)) as? [Any] else { return nil }
            rows = read
        }
        let named: [String: Any] = ["id": id, "title": title, "from": "you"]
        if let index = rows.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == id }),
           let row = rows[index] as? [String: Any] {
            rows[index] = row.merging(named) { $1 }
        } else {
            rows.append(named)
        }
        return try? JSONSerialization.data(
            withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
