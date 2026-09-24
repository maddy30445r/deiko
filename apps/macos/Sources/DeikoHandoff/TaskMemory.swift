import Foundation

/// Whether a brief's memory of its task is older than the task.
///
/// A brief carries what its task's earlier briefs wrote back AT THE MOMENT IT
/// RENDERED. Rendered at 10:05 while the agent was still on the brief before
/// it, then thrown at 10:25 after that agent wrote back at 10:20, it handed
/// over 10:05's state — "still open" for work that was done. Checked just
/// before a brief goes out, so it is re-rendered only when that happened.
///
/// In `DeikoHandoff` so it can be tested — see `TaskTitles`.
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
