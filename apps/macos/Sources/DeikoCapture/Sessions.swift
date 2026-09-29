import Foundation
import DeikoHandoff

/// The sessions folder: one timestamped folder per recording under `defaultRoot`. This lists, measures
/// and sweeps them.
///
/// A session is its name. `stamp` is strict about the `yyyyMMdd-HHmmss` shape the recorder mints and
/// everything here filters on it, because this file deletes from a folder on the user's Mac. Anything
/// placed there by hand is not a session and is never touched.
enum Sessions {

    /// Where sessions live; `main.swift` can override the root with `--out`. Application Support
    /// rather than `~/Documents`, which iCloud's Desktop & Documents sync would carry off the Mac.
    /// `models/` sits beside the session folders; nothing here reads a folder that is not a stamp.
    static let defaultRoot = "\(NSHomeDirectory())/Library/Application Support/Deiko"

    /// One-time move of the board out of `~/Documents/Deiko` (see `BoardMove`).
    @discardableResult
    static func migrateFromDocuments(home: String = NSHomeDirectory()) -> Int {
        BoardMove.run(from: "\(home)/Documents/Deiko", to: defaultRoot)
    }

    /// How long a finished session is kept before the launch sweep removes it. `0`, the default,
    /// disables the sweep: the board is Deiko's memory, and deleting is a decision made on a card or in
    /// Settings. The defaults key overrides it without a rebuild.
    static let retentionDaysKey = "DEIKO_SESSION_RETENTION_DAYS"
    static let defaultRetentionDays = 0

    /// When retention first applied to this install. Nothing recorded before the rule existed is
    /// swept: the first launch records the date and sweeps nothing, so an upgrade never deletes an
    /// existing archive. Older sessions go only when removed by hand.
    static let retentionSinceKey = "DEIKO_RETENTION_SINCE"

    static func retentionStart(now: Date = Date()) -> Date {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: retentionSinceKey)
        if stored > 0 { return Date(timeIntervalSince1970: stored) }
        defaults.set(now.timeIntervalSince1970, forKey: retentionSinceKey)
        return now
    }

    static var retentionDays: Int {
        // `object(forKey:)` rather than `integer(forKey:)`, which returns 0 for an unset key and so
        // cannot be told apart from an explicit "never sweep".
        guard let configured = UserDefaults.standard.object(forKey: retentionDaysKey) as? Int
        else { return defaultRetentionDays }
        return max(0, configured)
    }

    /// The instant a session folder's name says it was recorded, or nil if the name is not one Deiko
    /// minted. Two gates, and the second is not redundant: the regex accepts `20261347-995999`, which
    /// `DateFormatter` refuses. A name that merely looks like a stamp must not be dated, because being
    /// dated makes it eligible for deletion.
    static func stamp(_ name: String) -> Date? {
        guard name.count == 15,
              name.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.isLenient = false
        return formatter.date(from: name)
    }

    /// Session folders, newest first. Names only, not paths.
    static func list(root: String = defaultRoot) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .compactMap { name -> (String, Date)? in
                guard let date = stamp(name) else { return nil }
                return (name, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// What the folder costs, in bytes. Walks the whole tree, so callers run it off the main thread.
    static func sizeBytes(root: String = defaultRoot) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            // The models share the folder; they are not sessions.
            if enumerator.level == 1, url.lastPathComponent == "models" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            // Allocated size where known: that is what the disk gives up when the file goes.
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// "1.2 GB" / "480 MB".
    static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Delete sessions older than `days`, and return how many went. `keeping` is the open session,
    /// never touched however old its name: a reopened session can carry an earlier stamp.
    @discardableResult
    static func sweep(
        root: String = defaultRoot, olderThanDays days: Int, keeping open: String? = nil
    ) -> Int {
        guard days > 0 else { return 0 }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        // Sessions from before the retention rule are never swept; see `retentionStart`.
        let floor = retentionStart(now: now)
        let openName = open.map { ($0 as NSString).lastPathComponent }

        var removed = 0
        for name in list(root: root) {
            guard name != openName, let date = stamp(name),
                  date < cutoff, date >= floor else { continue }
            do {
                try FileManager.default.removeItem(atPath: "\(root)/\(name)")
                removed += 1
            } catch {
                // Not worth failing a launch over; retried on the next one.
                Emit.log("sweep: could not remove \(name): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            Emit.log("sweep: removed \(removed) session(s) older than \(days) days")
        }
        return removed
    }

    /// Remove one session. Only a folder shaped like a session (`stamp` is strict for this reason) is
    /// deleted: that check is all that stands between this and an arbitrary path.
    @discardableResult
    static func delete(dir: String) -> Bool {
        let name = (dir as NSString).lastPathComponent
        guard stamp(name) != nil else { return false }
        // The task note quotes this brief: read which task it belongs to before the folder goes.
        let context = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("context.json"))
        )) as? [String: Any]
        let task = context?["task"] as? String ?? Tasks.own(name)
        guard trash(dir) else { return false }
        // The board index caches every brief's words; it is rebuilt on the next read.
        try? FileManager.default.removeItem(atPath: ((dir as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".board-index.json"))
        if task.range(of: #"^t-\d{8}-\d{6}$"#, options: .regularExpression) != nil {
            let note = ((dir as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("tasks/\(task).md")
            try? FileManager.default.removeItem(atPath: note)
        }
        return true
    }

    /// Moves to the Trash, as Finder does, so a mistaken delete is one drag back. The launch sweep
    /// removes outright.
    static func trash(_ path: String) -> Bool {
        (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil
    }

    /// Remove every past session; the open one survives. Task notes and titles go too, since they are
    /// built from what those briefs said. Projects stay: a name and a line someone typed.
    @discardableResult
    static func deleteAll(root: String = defaultRoot, keeping open: String? = nil) -> Int {
        let openName = open.map { ($0 as NSString).lastPathComponent }
        var removed = 0
        for name in list(root: root) where name != openName {
            if trash("\(root)/\(name)") {
                removed += 1
            }
        }
        for memory in ["tasks", "tasks.json", "tasks.json.prev", ".board-index.json"] {
            try? FileManager.default.removeItem(atPath: "\(root)/\(memory)")
        }
        return removed
    }
}
