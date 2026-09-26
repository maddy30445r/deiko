import Foundation
import Network

// ─────────────────────────────────────────────────────────────────────────────
// BRIEFS WAITING TO BE FILED
//
// Filing a brief into its task asks the filing service, which needs the
// network. When it can't be reached (offline, the service busy or refusing)
// `classify.mjs` leaves a `filing.pending` marker in the session folder instead
// of guessing the brief into a task of its own. The brief itself has already
// gone to the agent; only its place on the board waits.
//
// This files them later through the SAME flow a new brief takes (classify,
// then re-render so the prompt carries its memory), oldest first, one at a
// time: when the network comes back, a few seconds after launch, after any
// brief that files, and from "Try now" on the board. It stops at the first
// brief that still can't get through, so a dead network is asked once, not
// once per waiting brief.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class FilingQueue: ObservableObject {
    static let shared = FilingQueue()

    /// How many briefs wait, for the board's row.
    @Published private(set) var waiting = 0
    @Published private(set) var working = false

    /// After this many failed tries in a row a brief waits for "Try now":
    /// by then something other than the network is wrong, and asking again
    /// on every reconnect would only spend requests.
    nonisolated static let autoTries = 8

    private var monitor: NWPathMonitor?
    private var online = true
    private var again = false

    private struct Marker: Decodable { let tries: Int? }

    nonisolated static func marker(_ sessionDir: String) -> URL {
        URL(fileURLWithPath: sessionDir).appendingPathComponent("filing.pending")
    }

    nonisolated static func isPending(_ sessionDir: String) -> Bool {
        FileManager.default.fileExists(atPath: marker(sessionDir).path)
    }

    /// Placed by hand: it no longer waits for anything.
    nonisolated static func settle(_ sessionDir: String) {
        try? FileManager.default.removeItem(at: marker(sessionDir))
    }

    /// Waiting briefs, oldest first (session folders are named by their time).
    nonisolated static func pending(includingStuck: Bool) -> [String] {
        let root = Collections.root
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted().compactMap { name in
            let dir = (root as NSString).appendingPathComponent(name)
            guard isPending(dir) else { return nil }
            if !includingStuck,
               let data = try? Data(contentsOf: marker(dir)),
               (try? JSONDecoder().decode(Marker.self, from: data))?.tries ?? 0 >= autoTries {
                return nil
            }
            return dir
        }
    }

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = up && !self.online
                self.online = up
                if cameBack { self.fileAll() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
        refresh()
        // Not at launch itself: the menu bar, the model download and the
        // first window all want the first seconds more than this does.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.fileAll()
        }
    }

    func refresh() {
        waiting = Self.pending(includingStuck: true).count
    }

    /// File every waiting brief through the normal flow. Safe to call often:
    /// a call while it runs just asks for one more pass after it.
    func fileAll(tryStuck: Bool = false) {
        guard !working else { again = true; return }
        let dirs = Self.pending(includingStuck: tryStuck)
        guard !dirs.isEmpty else { refresh(); return }
        working = true
        Task { [weak self] in
            var filed = false
            for dir in dirs where Self.isPending(dir) {
                let placed = await BriefPipeline.classify(sessionDir: dir)
                if Self.isPending(dir) { break }           // still can't get through: later
                if placed != nil {
                    _ = try? await BriefPipeline.rerender(sessionDir: dir)
                    filed = true
                }
            }
            guard let self else { return }
            if filed { await SessionsStore.shared.load(root: Collections.root) }
            self.working = false
            self.refresh()
            if self.again { self.again = false; self.fileAll() }
        }
    }
}
