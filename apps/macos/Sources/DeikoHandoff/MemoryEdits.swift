import Foundation

/// A task's "What Deiko remembers" as the person corrected it, the shape of
/// `tasks/<id>.overrides.json`: lines to forget, and lines reworded, both
/// keyed by the line as the agent wrote it in outcome.md. The scripts apply
/// the same file (`readOverrides` in scripts/lib/tasks.mjs).
public struct MemoryEdits: Codable, Equatable, Sendable {
    public var forget: [String] = []
    public var edit: [String: String] = [:]
    public var isEmpty: Bool { forget.isEmpty && edit.isEmpty }

    public init() {}

    /// Missing or mistyped fields read as "nothing corrected", as the
    /// scripts read them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forget = (try? c.decodeIfPresent([String].self, forKey: .forget)) ?? []
        edit = (try? c.decodeIfPresent([String: String].self, forKey: .edit)) ?? [:]
    }

    /// The line an agent wrote, for the one shown (which may be an edit).
    public func original(of shown: String) -> String {
        edit.first { $0.value == shown }?.key ?? shown
    }

    public func applied(to o: BoardTimeline.Outcome) -> BoardTimeline.Outcome {
        var out = o
        let fix = { (lines: [String]) in lines.filter { !forget.contains($0) }.map { edit[$0] ?? $0 } }
        out.did = fix(o.did)
        out.decided = fix(o.decided)
        out.open = fix(o.open)
        out.files = fix(o.files)
        return out
    }
}
