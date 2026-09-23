import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE SESSIONS FOLDER, AND WHAT LIVES IN IT
//
// Every session Deiko has ever recorded sits in `~/Documents/Deiko`, one
// timestamped folder each, and until now nothing ever removed one. The audio is
// deleted as soon as the brief exists — that has always been true and is the
// promise the microphone prompt makes — but the crops are not: they are
// full-resolution Retina PNGs of whatever was circled, and the product's own
// habit target is five sessions a week. Nobody was told the folder existed,
// nothing reported its size, and the only tool was Finder.
//
// So: one place that knows what a session folder is, and three things to do
// with the answer — list them, measure them, and sweep the old ones.
//
// A SESSION IS ITS NAME. `stamp` is strict about the `yyyyMMdd-HHmmss` shape
// the recorder mints, and everything here filters on it, because this file's
// whole job is deleting things out of a directory inside somebody's Documents.
// Anything a person put there by hand is not a session and is never touched.
// ─────────────────────────────────────────────────────────────────────────────

enum Sessions {

    /// Where sessions live. `main.swift` can still override the root with
    /// `--out`; this is the default both it and Diagnostics resolve to.
    static let defaultRoot = "\(NSHomeDirectory())/Documents/Deiko"

    /// How long a finished session is kept before the launch sweep removes it.
    ///
    /// ONE constant, and a defaults key beside it for anybody who wants a
    /// different answer without a rebuild. `0` disables the sweep entirely —
    /// worth having, because "delete my work on a timer" is a reasonable thing
    /// to refuse, and a user who refuses it should not have to trust that
    /// setting it to a huge number works.
    static let retentionDaysKey = "DEIKO_SESSION_RETENTION_DAYS"
    static let defaultRetentionDays = 30

    /// When retention first applied to this install.
    ///
    /// NOTHING RECORDED BEFORE THE RULE EXISTED IS EVER SWEPT. Without this,
    /// the first launch of the build that introduced retention would delete a
    /// user's entire back-catalogue — six months of screenshots, gone before
    /// they had any opportunity to read the Settings line that explains the
    /// policy, on an app they merely updated. Deleting somebody's data as a
    /// side effect of an upgrade is not a default anyone gets to choose for
    /// them.
    ///
    /// So the first launch records the date and sweeps nothing; from then on
    /// only sessions minted under the rule age out. An old archive stays until
    /// it is removed by hand, which Settings offers.
    static let retentionSinceKey = "DEIKO_RETENTION_SINCE"

    static func retentionStart(now: Date = Date()) -> Date {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: retentionSinceKey)
        if stored > 0 { return Date(timeIntervalSince1970: stored) }
        defaults.set(now.timeIntervalSince1970, forKey: retentionSinceKey)
        return now
    }

    static var retentionDays: Int {
        // `object(forKey:)` rather than `integer(forKey:)`: the latter returns
        // 0 for an unset key, which is the same value that means "never
        // sweep" — so an install that had never chosen would read as having
        // chosen to keep everything forever.
        guard let configured = UserDefaults.standard.object(forKey: retentionDaysKey) as? Int
        else { return defaultRetentionDays }
        return max(0, configured)
    }

    /// The instant a session folder's name says it was recorded, or nil if the
    /// name is not one Deiko minted.
    ///
    /// Two gates, and the second is not redundant: the regex accepts
    /// `20261347-995999`, which `DateFormatter` then refuses. A folder whose
    /// name merely looks like a stamp must not be dated by accident, because
    /// being dated is what makes it eligible for deletion.
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

    /// What the folder is costing, in bytes.
    ///
    /// Walks the whole tree, which is why callers do it off the main thread:
    /// a year of sessions is thousands of PNGs, and this is drawn in a window
    /// nobody wants to watch stutter.
    static func sizeBytes(root: String = defaultRoot) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            // Allocated size where it is known — that is what the disk actually
            // gives up when the file goes.
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// "1.2 GB" / "480 MB" — for the one line in Settings that says what this
    /// is costing.
    static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Delete sessions older than `days`, and say how many went.
    ///
    /// `keeping` is the session currently open, which is never touched however
    /// old its name — a reopened session can carry a stamp from an earlier
    /// launch, and deleting the folder being written to is the one mistake this
    /// cannot make.
    @discardableResult
    static func sweep(
        root: String = defaultRoot, olderThanDays days: Int, keeping open: String? = nil
    ) -> Int {
        guard days > 0 else { return 0 }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        // Never older than the rule itself — see `retentionStart`.
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
                // A session that will not delete is not worth failing a launch
                // over — it is retried on the next one.
                Emit.log("sweep: could not remove \(name): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            Emit.log("sweep: removed \(removed) session(s) older than \(days) days")
        }
        return removed
    }

    /// Remove ONE session. Named by its folder, and only if that folder is
    /// shaped like a session (`stamp` is strict for exactly this reason): this
    /// deletes a directory inside somebody's Documents, and the only thing
    /// standing between it and an arbitrary path is that check.
    @discardableResult
    static func delete(dir: String) -> Bool {
        let name = (dir as NSString).lastPathComponent
        guard stamp(name) != nil else { return false }
        return (try? FileManager.default.removeItem(atPath: dir)) != nil
    }

    /// Remove every past session. The open one, if any, survives.
    @discardableResult
    static func deleteAll(root: String = defaultRoot, keeping open: String? = nil) -> Int {
        let openName = open.map { ($0 as NSString).lastPathComponent }
        var removed = 0
        for name in list(root: root) where name != openName {
            if (try? FileManager.default.removeItem(atPath: "\(root)/\(name)")) != nil {
                removed += 1
            }
        }
        return removed
    }
}
