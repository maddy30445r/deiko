import Foundation

/// A rename of one row of `tasks.json`, losing nothing else in the file.
///
/// The app used to decode the whole list, change one title and encode it
/// again — so one row it could not decode emptied the list, and the rename
/// wrote the file back with a single row: every other task lost its name.
/// Keys it did not model (`from`, and whatever the scripts add next) went the
/// same way. Here the file is edited as JSON rather than as the app's type.
///
/// In `DeikoHandoff` so it can be tested — `DeikoCapture` cannot be linked
/// into a test binary (see `SessionClaims`).
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
