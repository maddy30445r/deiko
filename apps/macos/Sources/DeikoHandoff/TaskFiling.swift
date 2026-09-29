import Foundation

/// Small, pure pieces of how a brief was filed, kept here so they are tested
/// without a board on disk.
public enum TaskFiling {
    /// "picks up Signups chart from 3 weeks ago" — so a stale join is easy to
    /// spot and undo. Nil when the task's newest brief is a day old or less.
    public static func agePhrase(from newest: Date, to now: Date) -> String? {
        let days = now.timeIntervalSince(newest) / 86_400
        guard days > 1 else { return nil }
        switch days {
        case ..<2: return "yesterday"
        case ..<7: return "\(Int(days.rounded())) days ago"
        case ..<14: return "last week"
        case ..<30: return "\(Int((days / 7).rounded())) weeks ago"
        case ..<60: return "last month"
        default: return "\(Int((days / 30).rounded())) months ago"
        }
    }

    /// A context.json rewrite by the app: the keys the app models come from
    /// `mine` (absent there means removed); every other key on disk — the
    /// classifier's `jev` log above all — is kept as it was.
    public static func merge(disk: [String: Any], mine: [String: Any], ownKeys: [String]) -> [String: Any] {
        var merged = disk
        for key in ownKeys { merged[key] = mine[key] }
        return merged
    }

    /// Where the task somebody chose sat on the classifier's shortlist:
    /// 1-based, "new" for the brief's own task, "missing" when it was not
    /// shortlisted at all. Right answers landing low say the shortlist should
    /// grow; "missing" says it failed.
    public static func correctedRank(task: String, own: String, shortlist: [String]) -> String {
        if task == own { return "new" }
        return shortlist.firstIndex(of: task).map { String($0 + 1) } ?? "missing"
    }
}
