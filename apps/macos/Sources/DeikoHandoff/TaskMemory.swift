import Foundation

/// Whether a brief's memory of its task is older than the task.
///
/// A brief carries what its task's earlier briefs had written back when it
/// rendered. If an earlier brief's agent writes back after that, handing it
/// over would report stale state ("still open" for finished work). Checked just
/// before a brief goes out, so it is re-rendered only then.
///
/// In `DeikoHandoff` so it can be tested; see `TaskTitles`.
public enum TaskMemory {

    /// True when any of `mates` wrote an `outcome.md` after `sessionDir`'s
    /// `prompt.txt` was rendered. A stat per file, nothing read. False with no
    /// prompt: there is nothing stale to refresh, and the read that follows
    /// says what is missing.
    public static func isStale(sessionDir: String, mates: [String]) -> Bool {
        guard let rendered = modified(sessionDir, "prompt.txt") else { return false }
        return mates.contains { (modified($0, "outcome.md") ?? .distantPast) > rendered }
    }

    private static func modified(_ dir: String, _ name: String) -> Date? {
        let path = (dir as NSString).appendingPathComponent(name)
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// "Sort briefs into tasks", in Settings: whether a brief's words may leave
/// this Mac to be filed with the earlier work it belongs to.
public enum Sorting {

    /// `env` with the classifier pointed at `relay` while sorting is on, and at
    /// nothing while it is off. Off is stated outright as `DEIKO_SORT_BRIEFS=0`
    /// because `classify.mjs` would otherwise fall back to the transcription
    /// relay a keyless install carries. Briefs that need no relay are still
    /// placed on this Mac either way.
    public static func environment(
        _ env: [String: String], relay: String?, on: Bool, token: () -> String
    ) -> [String: String] {
        var env = env
        env["DEIKO_SORT_BRIEFS"] = on ? nil : "0"
        guard on else {
            env["DEIKO_CLASSIFY_URL"] = nil
            env["DEIKO_CLASSIFY_TOKEN"] = nil
            return env
        }
        if let relay {
            env["DEIKO_CLASSIFY_URL"] = relay
            env["DEIKO_CLASSIFY_TOKEN"] = token()
        }
        return env
    }

    /// Whether to tell someone on their own key that filing sends what they said
    /// to the relay. Only while it does, and yes once only: the answer is
    /// remembered.
    public static func noticeDue(
        ownKey: @autoclosure () -> Bool, files: @autoclosure () -> Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let told = "DEIKO_SORTING_NOTICE_SHOWN"
        guard !defaults.bool(forKey: told), ownKey(), files() else { return false }
        defaults.set(true, forKey: told)
        return true
    }
}
