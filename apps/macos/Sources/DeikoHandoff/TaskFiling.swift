import Foundation

/// Small, pure pieces of how a brief was filed, kept here so they are tested
/// without a board on disk.
public enum TaskFiling {
    /// "picks up Signups chart from 3 weeks ago" — so a stale join is easy to
    /// spot and undo. Nil when the task's newest brief is a day old or less.
    /// ponytail: the one-day line is the owner's starting value.
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

    /// Where the task somebody chose sat on the classifier's shortlist:
    /// 1-based, "new" for the brief's own task, "missing" when it was not
    /// shortlisted at all. Right answers landing low say the shortlist should
    /// grow; "missing" says it failed.
    public static func correctedRank(task: String, own: String, shortlist: [String]) -> String {
        if task == own { return "new" }
        return shortlist.firstIndex(of: task).map { String($0 + 1) } ?? "missing"
    }
}
