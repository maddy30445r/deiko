import Foundation
import Network

/// Files briefs that could not be filed when captured (offline, or the filing service busy or
/// refusing). `classify.mjs` leaves a `filing.pending` marker in the session folder; this retries
/// them oldest first through the normal classify-then-rerender flow. It stops at the first brief
/// that fails on the network, but passes over one the service refuses so the rest still file.
@MainActor
final class FilingQueue: ObservableObject {
    static let shared = FilingQueue()

    @Published private(set) var waiting = 0
    @Published private(set) var working = false

    /// After this many failed tries in a row a brief waits for "Try now"; asking again on
    /// every reconnect would only spend requests.
    nonisolated static let autoTries = 8

    private var monitor: NWPathMonitor?
    private var online = true
    private var again = false

    private struct Marker: Decodable { let tries: Int?; let reason: String? }

    /// The brief the review card is showing. Its filing runs in the card's own lane (narration
    /// edits, "Point at more"); filing it from here could race that lane and leave stale words on disk.
    var card: (dir: String, refile: @MainActor () -> Void)?

    /// Only the network pauses the whole queue; a brief the service refuses is passed over.
    private nonisolated static func waitsOnNetwork(_ dir: String) -> Bool {
        guard let data = try? Data(contentsOf: marker(dir)),
              let reason = (try? JSONDecoder().decode(Marker.self, from: data))?.reason else { return true }
        return ["offline", "busy", "unreachable"].contains(reason)
    }

    nonisolated static func marker(_ sessionDir: String) -> URL {
        URL(fileURLWithPath: sessionDir).appendingPathComponent("filing.pending")
    }

    nonisolated static func isPending(_ sessionDir: String) -> Bool {
        FileManager.default.fileExists(atPath: marker(sessionDir).path)
    }

    /// Called once a brief is placed by hand, so it stops waiting.
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
        // Not at launch itself: the menu bar, the model download and the first window want those seconds more.
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
                if let card = self?.card, card.dir == dir { card.refile(); continue }
                let placed = await BriefPipeline.classify(sessionDir: dir)
                if Self.isPending(dir) {
                    if Self.waitsOnNetwork(dir) { break }  // the network: later, all of them
                    continue                               // this one: passed over, the rest go on
                }
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
