import AppKit
import SwiftUI
import QuickLook
import DeikoGesture
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE DEIKO WINDOW
//
// Everything that is not the orb: what you have recorded, how briefs get
// written, and every setting. Deiko stays an accessory app — the orb over your
// editor is still the product — but "where do my briefs go?" and "how do I
// make it write tickets my way?" are questions a menu cannot answer, and a
// 520pt settings sheet was never going to hold a board of sessions.
//
// ONE WINDOW, one sidebar, four places. Adding a fifth means adding a case and
// a view, which is the point: the board, personas and the dashboard were three
// separate designs before this, and each would have grown its own chrome.
// ─────────────────────────────────────────────────────────────────────────────

enum MainSection: String, CaseIterable, Identifiable {
    case dashboard, board, personas, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .board: return "Board"
        case .personas: return "Personas"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .board: return "rectangle.3.group"
        case .personas: return "person.crop.square"
        case .settings: return "gearshape"
        }
    }
}

/// Which section is showing, so the menu bar can open the window straight at
/// one rather than opening it and making somebody click.
@MainActor
final class MainNav: ObservableObject {
    static let shared = MainNav()
    @Published var section: MainSection = .dashboard
    /// The one piece of work the board is opened on, or nil for every brief.
    /// Here rather than in the board, so the sidebar's Board row can clear it:
    /// clicking "Board" while inside a work must show all briefs again.
    @Published var work: String?
    /// The one brief the board is showing, by session id, or nil.
    @Published var brief: String?

    /// Show one brief on the board, from wherever it was picked.
    func open(brief id: String) {
        section = .board
        work = nil
        brief = id
    }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var holdsDock = false
    /// Handed in rather than read from a global: "Delete all past sessions"
    /// must be able to spare the session being recorded right now, and this
    /// window has no recorder of its own.
    var openSessionDir: (() -> String?)?
    var sessionRoot: String = Sessions.defaultRoot

    func present(_ section: MainSection = .dashboard) {
        MainNav.shared.section = section
        // Every time, not only on the first open.
        Task { await SessionsStore.shared.load(root: sessionRoot) }
        // A REGULAR APP WHILE THIS WINDOW IS OPEN: a Dock tile for a
        // minimized window to come back from, ⌘-Tab, full screen and the
        // menu bar. `windowWillClose` hands the Dock tile back.
        if !holdsDock {
            DockPresence.acquire()
            holdsDock = true
        }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: MainWindowView(openSessionDir: openSessionDir, sessionRoot: sessionRoot)
        )
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Deiko"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // The sidebar runs under the title bar, the way every Mac app with one
        // does. Without `fullSizeContentView` the material stops at the bar and
        // the window reads as a dialog wearing a sidebar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // THE CORNERS. On macOS 26 a window's corner radius follows its title
        // bar: a bare one gets 16pt, a compact unified toolbar 20pt, a full one
        // 26pt. Compact, and empty: its 40pt bar stays above the 44pt this
        // layout already leaves clear (sidebar brand row, pane headers), so no
        // control ends up under the window's drag area. A full toolbar's 66pt
        // bar would swallow the page headers' clicks.
        window.useRoundedTitleBar("DeikoMainWindow")
        // The green button goes full screen, as in every other Mac app;
        // Option-click (or a double-click on the bar) zooms.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 980, height: 660))
        window.minSize = NSSize(width: 860, height: 560)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DeikoMainWindow")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to the menu bar. Not on minimize: a minimized window needs
        // its Dock tile to come back from.
        SessionsStore.shared.windowClosed()
        if holdsDock {
            DockPresence.release()
            holdsDock = false
        }
    }

    /// ZOOM FILLS THE SCREEN'S HEIGHT, NOT ITS WIDTH: a board three cards
    /// wide reads the same at 1320pt as at 2560, and an ultrawide stretch
    /// only puts the cards further from each other.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let width = min(defaultFrame.width, 1320)
        return NSRect(x: defaultFrame.midX - width / 2, y: defaultFrame.minY, width: width, height: defaultFrame.height)
    }
}

// ── The window ──────────────────────────────────────────────────────────────

struct MainWindowView: View {
    @ObservedObject private var nav = MainNav.shared
    @ObservedObject private var sessions = SessionsStore.shared
    let openSessionDir: (() -> String?)?
    let sessionRoot: String

    var body: some View {
        // AN EXPLICIT SPLIT, NOT `NavigationSplitView`.
        //
        // The sidebar here is fixed furniture: four places, always visible,
        // 198pt, on paper. `NavigationSplitView` brings a collapsible column,
        // a toolbar toggle and a translucent material to match — none of which
        // this design wants, all of which would have to be argued back out.
        // It also declines to lay out at all outside a real window scene,
        // which made every shot of this window a blank column.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 198)
                .background(DeikoStyle.paper)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // PAPER, NOT CARD. This was `card`, which is also what every
                // `InsetCard` inside it is filled with — white on white,
                // measured at 1.00:1, with the whole grouping carried by one
                // hairline at 1.17:1. Cards sit ON paper; that is the entire
                // reason paper exists as a token.
                .background(DeikoStyle.paper)
        }
        .task { await sessions.load(root: sessionRoot) }
        // NO SAFE-AREA INSET. The window is `fullSizeContentView` with a hidden,
        // transparent title bar, and under that style the pane's scroll view is
        // handed a title-bar inset on top of the 44pt `PaneScroll` already pads
        // by hand. Two things went wrong with that. The real window drew every
        // pane lower than the design it was reviewed against, which was only
        // ever rendered borderless. And inside the scroll view SwiftUI's own
        // hit-testing did not agree with the drawing by that same inset: the
        // board's filter chips drew in one place and took clicks in another,
        // hovering them lit the card beneath, while the ⋯ menus — AppKit
        // controls, hit-tested by AppKit — kept working, and the sidebar,
        // outside any scroll view, was never affected. One coordinate space
        // for both, and the 44pt is the whole of the title-bar allowance.
        .ignoresSafeArea(.container, edges: .top)
        // THE CONTROLS DEIKO DID NOT DRAW still have to carry the palette.
        //
        // A Toggle, a segmented Picker, a text field's caret and selection,
        // and a standard button's focus ring all take the SYSTEM accent —
        // whatever blue (or graphite, or pink) the person set in System
        // Settings. So half this window is Deiko's indigo and the other half
        // is a colour chosen by somebody who has never seen it. One line
        // moves the lot onto the palette, and `DESIGN.md` already says which
        // colour: indigo marks selecting and focusing.
        .tint(DeikoStyle.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                CoinView(kind: .ready, diameter: 24)
                Text("Deiko").deikoTitle(17)
            }
            // 9, not 12: the rows below inset their label by 6 (row padding)
            // + 9 (content padding) = 15, and the wordmark sat 4pt right of
            // every one of them.
            .padding(.horizontal, 9)
            // CLEAR OF THE TRAFFIC LIGHTS. The title bar is transparent and
            // its title hidden, so the window's own buttons are drawn over
            // this column — they finish around 32pt down, and the brand row
            // was landing at 25.
            .padding(.top, 44)
            .padding(.bottom, 14)

            ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, section in
                SidebarRow(
                    section: section,
                    selected: nav.section == section,
                    // ⌘1…⌘4. This is a menu-bar app for developers; the second
                    // thing they try after opening a window is a number key.
                    shortcut: KeyEquivalent(Character("\(index + 1)"))
                ) {
                    nav.section = section
                    if section == .board { nav.work = nil; nav.brief = nil }
                }
            }

            Spacer()
            quotaStrip
        }
        .padding(.vertical, 10)
    }

    /// What is left, where it is always visible. The trial was knowable only
    /// from a sentence in a window nobody opened; this is the same number the
    /// Settings card draws, in the place people actually look.
    @ViewBuilder private var quotaStrip: some View {
        if let quota = License.cachedQuota, quota.capSeconds > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text(quota.usedSentence)
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DeikoStyle.hairline)
                        Capsule()
                            .fill(quota.isSpent ? DeikoStyle.needsYou : DeikoStyle.accent)
                            .frame(width: bar.size.width * min(max(quota.usedFraction, 0), 1))
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 4)
            .accessibilityElement()
            .accessibilityLabel("Transcription minutes used")
            .accessibilityValue(quota.usedSentence)
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .dashboard: DashboardPane(sessions: sessions)
        case .board: BoardPane(sessions: sessions)
        case .personas: PersonasPane()
        case .settings:
            SettingsView(openSessionDir: openSessionDir, sessionRoot: sessionRoot)
                // Its own scroll view, so it is not wrapped in `PaneScroll` —
                // but it carries the same header, because a section that
                // opens differently from its neighbours reads as a different
                // window.

        }
    }
}

private struct SidebarRow: View {
    let section: MainSection
    let selected: Bool
    let shortcut: KeyEquivalent
    let go: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .frame(width: 17)
                    .foregroundStyle(selected ? DeikoStyle.accent : .secondary)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DeikoStyle.controlRadius)
                    .fill(selected ? DeikoStyle.accentSoft
                          : (hovering ? Color.primary.opacity(0.055) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Before the outer padding, so the ring lands on the row's own
        // background rather than on the gap between it and the sidebar edge.
        .deikoFocusRing()
        .keyboardShortcut(shortcut, modifiers: .command)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .tip("\(section.title) (⌘\(String(describing: shortcut.character)))")
    }
}

// ── What has been recorded ──────────────────────────────────────────────────

@MainActor
final class SessionsStore: ObservableObject {

    /// Shared, so `MainWindowController.present()` can refresh it. The window
    /// is kept alive between openings (`isReleasedWhenClosed = false`), so a
    /// `.task` on the view runs exactly once per launch — and the pane whose
    /// lede is "what Deiko has heard on this Mac" was showing what it had
    /// heard by the time you first opened the window.
    static let shared = SessionsStore()

    /// The session being recorded right now, if any. Set once at launch
    /// alongside `Collections.root` (see `MenuBar`). `load` skips this
    /// session entirely — never "Unfinished recording", never a card, never
    /// a "Delete…" on the brief that is still being made.
    nonisolated(unsafe) static var openSessionDir: (() -> String?)?

    struct Item: Identifiable, Sendable {
        let id: String
        let dir: String
        let date: Date
        /// The narration, which is the only line anybody recognises a session
        /// by. A session whose brief never rendered has none — it is listed
        /// anyway, because it is still theirs and still on the disk.
        let line: String?

        /// What to call this when the narration is missing or says nothing
        /// ("Thank you." is a real transcript, and a real board is full of
        /// them). The app it was captured from beats an apology.
        var title: String {
            if unreadable { return "Couldn't read this brief" }
            if unfinished { return "Unfinished recording" }
            if let line, line.count > 12 { return Self.trimmedTitle(line) }
            if let app = apps.first { return "Something in \(app)" }
            return crops.isEmpty ? "A session with nothing saved" : "\(crops.count) screenshots, no words"
        }

        /// Drops the trailing full stop a sentence naturally ends on and caps
        /// at a word boundary — mirrors `tasks.mjs`'s `trimTitle`, so a title
        /// never runs to paragraph length.
        private static func trimmedTitle(_ text: String) -> String {
            var trimmed = text
            while let last = trimmed.last, ".!? ".contains(last) { trimmed.removeLast() }
            guard trimmed.count > 80 else { return trimmed }
            let cut = String(trimmed.prefix(80))
            guard let boundary = cut.lastIndex(of: " "), boundary > cut.startIndex else { return cut + "…" }
            return String(cut[..<boundary]) + "…"
        }
        let crops: [String]
        let apps: [String]
        let repo: String?
        /// The pages and files the brief is about — what its work is named after.
        var pages: [String] = []
        var files: [String] = []
        /// Where this brief sits in what Deiko remembers — see `Context.swift`.
        /// All three come from the same detached pass that reads the manifest,
        /// so the memory costs the board one more small decode per session.
        var collection: String?
        /// The task this brief belongs to; its own when nobody moved it. An
        /// odds brief still carries its own id here but is in no task, so
        /// every lookup by task id skips it.
        var task: String
        /// In odds and ends: in no task, set aside in the timeline.
        var odds: Bool
        /// The first line an agent wrote back about what it did, if one did.
        let outcome: String?
        /// No brief.json: a recording that never finished rendering. Set
        /// aside as "Unfinished recording".
        /// ponytail: a brief mid-pipeline reads as unfinished for the seconds
        /// before its first render; the board reloads when it lands.
        let unfinished: Bool
        /// A brief.json exists but this build could not decode it — an older
        /// schema, or a write that was cut short. Distinct from `unfinished`:
        /// the recording finished, this build just can't read what it wrote.
        /// Set aside alongside it, as "Couldn't read this brief".
        let unreadable: Bool
        /// The likeliest task the classifier asked "Which one?" about, while
        /// this brief is still its own task — the board's "Looks like …?".
        var maybe: String?
        /// A task this brief is related to but not part of.
        var related: String?
        /// Deiko put this brief in another brief's task on its own — the card
        /// says "Added to … · Undo" until it has been seen once.
        var filedByDeiko: Bool

        /// Odds and ends and recordings that never finished: in the timeline
        /// with everything else, but quiet, and in no task.
        var setAside: Bool { odds || unfinished || unreadable }
    }

    @Published private(set) var items: [Item] = [] {
        didSet {
            workCounts = BoardTimeline.workCounts(items.map { $0.setAside ? nil : $0.task })
            // Once per board, not once per card: see `BoardTimeline.TaskIndex`.
            taskIndex = BoardTimeline.TaskIndex(items.map {
                .init(id: $0.id, task: $0.task, odds: $0.odds, date: $0.date, title: $0.title)
            })
            allGroups = groups(of: items)
            nameWork()
        }
    }
    private var taskIndex = BoardTimeline.TaskIndex()
    /// `groups(of: items)`, kept: every card's Move-to-task menu asks for it.
    private var allGroups: [Group] = []
    /// Briefs per task, set-aside ones in none. A card wears its task's tag
    /// only where this is 2 or more.
    @Published private(set) var workCounts: [String: Int] = [:]
    @Published private(set) var loaded = false
    /// The projects briefs are filed under, reloaded beside them: a collection
    /// created by the classifier during a brief must appear on the board
    /// without anybody restarting anything.
    @Published private(set) var collections: [Collection] = []

    /// How many briefs sit in each collection, and how many sit in none.
    ///
    /// Tallied once when the board loads rather than filtered per lookup: the
    /// chip row sorts collections by size, and a comparator that walks every
    /// session is the shape of thing that is fine at thirty briefs and silly
    /// at three thousand.
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var unsortedCount = 0

    func count(of id: String) -> Int { counts[id] ?? 0 }

    @Published private(set) var taskTitles: [String: String] = [:] { didSet { nameWork() } }
    /// Tasks you named yourself: their names are used as given.
    private var namedByYou: Set<String> = []
    /// Task id → the short name its tag wears — see `BoardTimeline.workNames`.
    @Published private(set) var workNames: [String: String] = [:]

    private func nameWork() {
        workNames = BoardTimeline.workNames(groups(of: items).map { group in
            .init(id: group.id, title: taskTitles[group.id] ?? group.items.last?.title,
                  named: namedByYou.contains(group.id),
                  pages: group.items.flatMap(\.pages), files: group.items.flatMap(\.files))
        })
    }

    /// What a tag, "Added to …" and the work header call a task: short.
    /// `title(ofTask:)` is the whole title, for a tooltip or a subtitle.
    func workName(ofTask id: String) -> String { workNames[id] ?? title(ofTask: id) }

    struct Group: Identifiable {
        let id: String
        let items: [Item]
    }

    /// Briefs by task, each task's newest first, tasks ordered by their
    /// newest brief — so a task sits where its latest work is rather than
    /// jumping to the top of the board. Odds and ends are in no task, so
    /// none of these, and never a task to move a brief into; nor is a
    /// recording that never finished.
    func groups(of items: [Item]) -> [Group] {
        Dictionary(grouping: items.filter { !$0.odds && !$0.unfinished && !$0.unreadable }, by: \.task)
            .map { Group(id: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.items[0].date > $1.items[0].date }
    }

    func title(ofTask id: String) -> String {
        taskTitles[id] ?? taskIndex.firstTitle(ofTask: id) ?? "A task"
    }

    func recentTasks(excluding id: String?) -> [Group] {
        Array(allGroups.filter { $0.id != id }.prefix(20))
    }

    /// Whether any brief but `id` is in `task` — so "Start a new task" for a
    /// brief whose own id that is, and which is not in it, would join them.
    func hasOthers(inTask task: String, besides id: String) -> Bool {
        taskIndex.hasOthers(inTask: task, besides: id)
    }

    static let ownTaskTakenHelp = "Other briefs are already in the task this one started, so this would join them rather than start a new one."

    /// Put a brief in another task. Re-rendered, because the prompt carries
    /// the task — unlike a collection move, which changes nothing it says.
    /// The board window's, set by `BoardPane`: every move is one ⌘Z.
    weak var undoManager: UndoManager?

    func move(_ item: Item, toTask id: String) {
        // UNDO PUTS BACK EXACTLY WHAT WAS THERE — the file as it was, not a
        // second move, which would stamp the brief as placed by hand.
        let file = SessionContext.path(sessionDir: item.dir)
        let before = try? Data(contentsOf: file)
        let shown = items.first { $0.id == item.id }
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(item, file: file, before: before, shown: shown, redo: id)
        }
        undoManager?.setActionName("Move to \(workName(ofTask: id))")
        var context = SessionContext.read(sessionDir: item.dir) ?? SessionContext()
        context.placeTask(id)
        try? context.write(sessionDir: item.dir)
        SessionContext.noteCorrection(sessionDir: item.dir, task: id)
        // On the board at once — a drag that takes a re-render to land reads
        // as a drag that did nothing. The reload after it says the same.
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].task = id
            items[index].odds = false
            items[index].filedByDeiko = false
            items[index].maybe = nil
            if items[index].related == id { items[index].related = nil }
        }
        Task {
            _ = try? await BriefPipeline.rerender(sessionDir: item.dir)
            await load(root: root)
        }
    }

    private func restore(_ item: Item, file: URL, before: Data?, shown: Item?, redo id: String) {
        if let before { try? before.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
        if let shown, let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = shown }
        undoManager?.registerUndo(withTarget: self) { $0.move(item, toTask: id) }
        Task {
            _ = try? await BriefPipeline.rerender(sessionDir: item.dir)
            await load(root: root)
        }
    }

    /// Whether an earlier brief of this one's task wrote back since this one
    /// rendered — see `TaskMemory`. Earlier only: those are all
    /// `render-brief.mjs` carries. Its own task from `context.json`, not the
    /// board, which may not have caught up with the filing yet; odds and ends
    /// have no task to remember.
    func memoryIsStale(sessionDir: String) -> Bool {
        let id = (sessionDir as NSString).lastPathComponent
        let context = SessionContext.read(sessionDir: sessionDir)
        guard context?.isOdds != true else { return false }
        let task = context?.task ?? Tasks.own(id)
        let mates = items.filter { $0.task == task && !$0.odds && $0.id < id }.map(\.dir)
        return TaskMemory.isStale(sessionDir: sessionDir, mates: mates)
    }

    /// The brief as it would go out now, re-rendered first when its memory is
    /// stale. What the board's copies read; the throw checks inside its own
    /// render lane instead.
    func freshPrompt(sessionDir: String) async -> BriefPipeline.Prompt? {
        if memoryIsStale(sessionDir: sessionDir) {
            _ = try? await BriefPipeline.rerender(sessionDir: sessionDir)
        }
        return try? BriefPipeline.prompt(sessionDir: sessionDir)
    }

    /// File a brief somewhere else, from the board rather than the card.
    /// Marked as the developer's decision, which the classifier never
    /// overwrites.
    func move(_ item: Item, to collection: String?) {
        var context = SessionContext.read(sessionDir: item.dir) ?? SessionContext()
        context.placeCollection(collection)
        try? context.write(sessionDir: item.dir)
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let was = item.collection { counts[was, default: 1] -= 1 } else { unsortedCount -= 1 }
        if let now = collection { counts[now, default: 0] += 1 } else { unsortedCount += 1 }
        items[index].collection = collection
    }

    // ── "Added to … · Undo", shown once ─────────────────────────────────────

    /// Where the seen-markers live. Nil in `ui-shot`, which must never mark
    /// a real brief as seen.
    nonisolated(unsafe) static var seenDefaults: UserDefaults? = .standard
    private static let seenKey = "DEIKO_FILING_SEEN"
    /// Brief ids whose filing has had its one showing. Internal so `ui-shot`
    /// can pose which ones still announce.
    var seen: Set<String> = Set(SessionsStore.seenDefaults?.stringArray(forKey: SessionsStore.seenKey) ?? [])
    /// Shown while this window has been open: seen now, but not taken away
    /// from under the pointer mid-look. Cleared when the window closes.
    private var showing: Set<String> = []

    func announces(_ item: Item) -> Bool {
        item.filedByDeiko && (showing.contains(item.id) || !seen.contains(item.id))
    }

    /// Called as the card comes on screen.
    func sawFiling(_ item: Item) {
        guard announces(item), !seen.contains(item.id) else { return }
        showing.insert(item.id)
        seen.insert(item.id)
        Self.seenDefaults?.set(Array(seen), forKey: Self.seenKey)
    }

    func windowClosed() { showing = [] }

    /// FIRST RUN OF THE TIMELINE: every filing already on the board is old
    /// news. Without this the first open wore an Undo on every joined brief
    /// Deiko ever made; the announcement is for filings from now on.
    private func seedSeen(_ read: [Item]) {
        guard let defaults = Self.seenDefaults, defaults.object(forKey: Self.seenKey) == nil else { return }
        seen = Set(read.filter(\.filedByDeiko).map(\.id))
        defaults.set(Array(seen), forKey: Self.seenKey)
    }

    var thisWeek: Int {
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        return items.filter { $0.date > since }.count
    }

    /// The apps that appear in the most sessions — "where you have been
    /// pointing", which is a fact the manifests already carry.
    var topApps: [(name: String, count: Int)] {
        var tally: [String: Int] = [:]
        for item in items { for app in Set(item.apps) { tally[app, default: 0] += 1 } }
        return tally.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }

    /// Forget one session: to the Trash, and off the board. The confirmation
    /// lives with the caller.
    func delete(_ item: Item) {
        guard Sessions.delete(dir: item.dir) else { return }
        items.removeAll { $0.id == item.id }
    }

    /// The root these sessions were read from, so a reload after a rename
    /// goes back to the same place rather than to the default one.
    private(set) var root = Sessions.defaultRoot

    func load(root: String) async {
        self.root = root
        Collections.root = root
        let known = Set(Collections.all().map(\.id))
        let names = Sessions.list(root: root)
        // The session being recorded right now, if any — computed on the main
        // actor (it asks the recorder) and captured by value, because it must
        // never appear on the board at all: no card means no "Delete…" for it.
        // By name, matching `Sessions.deleteAll(keeping:)`, not by full path.
        let openName = Self.openSessionDir?().map { ($0 as NSString).lastPathComponent }
        // Manifests are small but there can be hundreds; read them off the main
        // actor so opening the window never stutters.
        let read = await Task.detached(priority: .userInitiated) { () -> [Item] in
            names.compactMap { name in
                guard name != openName else { return nil }
                let dir = (root as NSString).appendingPathComponent(name)
                guard let date = Sessions.stamp(name) else { return nil }
                let hasBrief = FileManager.default.fileExists(
                    atPath: (dir as NSString).appendingPathComponent("brief.json")
                )
                let digest = try? BriefPipeline.digest(sessionDir: dir)
                let narration = digest?.summary.narration.trimmingCharacters(in: .whitespacesAndNewlines)
                // An id no collection claims any more — its collection was
                // deleted — reads as Unsorted, which is what the confirmation
                // promised and what the card says. Left as-is, those briefs
                // answered to no chip at all.
                let stored = SessionContext.read(sessionDir: dir)
                let context = known.contains(stored?.collection ?? "") ? stored : nil
                let outcome = (try? String(
                    contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("outcome.md"),
                    encoding: .utf8
                )).flatMap(BoardTimeline.outcomeLine)
                let own = Tasks.own(name)
                let isOwnTask = stored?.task == nil || stored?.task == own
                let odds = stored?.isOdds == true
                return Item(
                    id: name,
                    dir: dir,
                    date: date,
                    line: (narration?.isEmpty == false) ? narration : nil,
                    crops: digest?.cropPaths ?? [],
                    apps: digest?.summary.apps ?? [],
                    repo: digest?.summary.repoHints.first,
                    pages: digest?.summary.keys?.pages ?? [],
                    files: digest?.summary.keys?.files ?? [],
                    collection: context?.collection,
                    task: stored?.task ?? own,
                    odds: odds,
                    outcome: outcome,
                    unfinished: !hasBrief,
                    unreadable: hasBrief && digest == nil,
                    maybe: isOwnTask ? stored?.candidates?.first : nil,
                    related: isOwnTask ? stored?.related : nil,
                    filedByDeiko: BoardTimeline.filedByDeiko(
                        decidedBy: stored?.decidedBy, taskBy: stored?.taskBy,
                        task: stored?.task, own: own, odds: odds
                    )
                )
            }
        }.value
        seedSeen(read)
        items = read
        collections = Collections.all()
        let tasks = Tasks.all()
        namedByYou = Set(tasks.filter { $0.from == "you" }.map(\.id))
        taskTitles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        counts = read.reduce(into: [:]) { tally, item in
            if let id = item.collection { tally[id, default: 0] += 1 }
        }
        unsortedCount = read.count { $0.collection == nil }
        loaded = true
    }
}

// ── Dashboard ───────────────────────────────────────────────────────────────

private struct DashboardPane: View {
    @ObservedObject var sessions: SessionsStore
    @State private var copied: String?

    var body: some View {
        PaneScroll(title: "Dashboard", lede: "What Deiko has heard on this Mac.") {
            if sessions.items.isEmpty {
                // NO ZEROES. Three 28pt noughts were the first thing a new
                // install showed, with the one sentence that tells you what to
                // do pushed underneath them. Nothing recorded is not a
                // statistic, it is an invitation.
                EmptyPane(
                    title: sessions.loaded ? "Nothing on the desk yet" : "Reading your sessions…",
                    line: "Double-tap \(SessionKey.selected.name), point at something, and say what should change. Whatever you say lands here — and nowhere else."
                )
            } else {
                latest
                HStack(spacing: 12) {
                    stat("\(sessions.items.count)", "briefs kept", Sessions.retentionDays > 0
                        ? "older than \(Sessions.retentionDays) days are swept"
                        : "every one of them is memory for the next")
                    stat("\(sessions.thisWeek)", "this week", "double-tap \(SessionKey.selected.name) to add one")
                    stat("\(sessions.items.reduce(0) { $0 + $1.crops.count })", "screenshots drawn",
                         "the crops that travelled with your briefs")
                }

                if !sessions.topApps.isEmpty {
                    SectionLabel("Where you point")
                    InsetCard {
                        ForEach(Array(sessions.topApps.enumerated()), id: \.element.name) { index, app in
                            if index > 0 { Divider().padding(.horizontal, 14) }
                            HStack {
                                Text(app.name).font(.system(size: 13))
                                Spacer()
                                Text("\(app.count) session\(app.count == 1 ? "" : "s")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DeikoStyle.ink2)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }

                if sessions.items.count > 1 {
                    SectionLabel("Before that")
                    InsetCard {
                        ForEach(Array(sessions.items.dropFirst().prefix(4).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.horizontal, 14) }
                            SessionRow(item: item, store: sessions)
                        }
                    }
                }
            }
        }
    }

    /// THE LAST BRIEF, NOT A COUNT OF THEM. What somebody wants from this pane
    /// ninety seconds after talking to their screen is the thing they just
    /// made — and the one action that was missing everywhere: take it with you.
    private var latest: some View {
        let item = sessions.items[0]
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("The last thing you said").deikoTitle(15)
                Spacer()
                Text(BoardCard.stamp(item.date))
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            Text(item.title)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            if !item.crops.isEmpty {
                HStack(spacing: 8) {
                    ForEach(item.crops.prefix(4), id: \.self) { path in
                        CropThumbnail(path: path, width: 96, height: 58, radius: 8)
                    }
                    if item.crops.count > 4 {
                        Text("+\(item.crops.count - 4)")
                            .font(.system(size: 11))
                            .foregroundStyle(DeikoStyle.ink2)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(copied == item.id ? "Copied" : "Copy the brief") { copy(item) }
                    .buttonStyle(InkButtonStyle())
                    .disabled(copied == item.id)
                Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: item.dir)) }
                Spacer()
                if let repo = item.repo {
                    Text(repo)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DeikoStyle.mark)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DeikoStyle.accentSoft, in: Capsule())
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                .fill(DeikoStyle.wall)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: 13, x: 0, y: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
        .onTapGesture { MainNav.shared.open(brief: item.id) }
        .tip("Click to open this brief")
    }

    /// The same text the fling would paste. Read from disk, because the review
    /// window may have rewritten it since, and fresh — see `freshPrompt`.
    private func copy(_ item: SessionsStore.Item) {
        Task {
            guard let prompt = await sessions.freshPrompt(sessionDir: item.dir) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt.text, forType: .string)
            copied = item.id
            try? await Task.sleep(for: .seconds(2))
            if copied == item.id { copied = nil }
        }
    }

    private func stat(_ value: String, _ label: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).deikoTitle(28)
            Text(label).font(.system(size: 12, weight: .medium))
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .deikoCard()
    }
}

// ── Board ───────────────────────────────────────────────────────────────────

private struct BoardPane: View {
    @ObservedObject var sessions: SessionsStore
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var nav = MainNav.shared
    @State private var query = ""
    @State private var filter: Filter = .all
    /// One piece of work, oldest first — what a card's tag opens.
    private var work: String? {
        get { nav.work }
        nonmutating set { nav.work = newValue }
    }
    /// Where a carried brief lands if it is let go now: on a card, or on the
    /// timeline's empty space. The lede says which.
    @State private var overCard: String?
    @State private var overSpace = false
    /// Days whose set-aside briefs are shown, by heading.
    @State private var unfolded: Set<String> = UIShotPose.unfolded
    @FocusState private var searching: Bool

    /// Which slice of the board is on screen. Unsorted is its own answer
    /// rather than an empty collection: "nothing filed this yet" is a thing
    /// somebody looks for on purpose.
    private enum Filter: Hashable {
        case all, unsorted, collection(String)
    }

    private var shown: [SessionsStore.Item] {
        var inFilter = sessions.items.filter { item in
            switch filter {
            case .all: return true
            case .unsorted: return item.collection == nil
            case .collection(let id): return item.collection == id
            }
        }
        // ONE PIECE OF WORK READS FORWARDS: how it started, then what came of
        // it. The timeline reads the other way, newest on top.
        if let work { inFilter = inFilter.filter { $0.task == work && !$0.setAside }.reversed() }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return inFilter }
        // A TASK IS FOUND BY ITS NAME, and found whole: its tag counts its
        // briefs, so showing only the ones whose words also matched made the
        // count and the cards disagree. Titled from the group, not per brief
        // — `title(ofTask:)` walks the board for an untitled task.
        let named = Set(sessions.groups(of: inFilter).filter { group in
            (sessions.taskTitles[group.id] ?? group.items.last?.title ?? "").lowercased().contains(q)
                || (sessions.workNames[group.id] ?? "").lowercased().contains(q)
        }.map(\.id))
        return inFilter.filter {
            (!$0.setAside && named.contains($0.task))
                || ($0.line ?? "").lowercased().contains(q)
                || ($0.repo ?? "").lowercased().contains(q)
                || $0.apps.contains { $0.lowercased().contains(q) }
        }
    }

    /// THE PROJECT, AS ONE QUIET MENU. Projects were a row of chips over the
    /// timeline, a third way of grouping briefs beside days and works, and
    /// the loudest of the three. A filter somebody uses now and then reads
    /// as a filter: "Project: All", its choices ordered by size.
    ///
    /// It sits in the pane's fixed band, not in the scroll view with the
    /// cards — see `body` for why that is the whole of the fix.
    @ViewBuilder private var projectMenu: some View {
        if !sessions.collections.isEmpty {
            let sorted = sessions.collections.sorted { sessions.count(of: $0.id) > sessions.count(of: $1.id) }
            Menu {
                Picker("Project", selection: $filter) {
                    Text("All projects · \(sessions.items.count)").tag(Filter.all)
                    ForEach(sorted) { collection in
                        Text("\(collection.name) · \(sessions.count(of: collection.id))")
                            .tag(Filter.collection(collection.id))
                    }
                    if sessions.unsortedCount > 0 {
                        Text("Unsorted · \(sessions.unsortedCount)").tag(Filter.unsorted)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Menu("Edit a project") {
                    ForEach(sorted) { collection in
                        Menu(collection.name) { CollectionMenu(collection: collection, store: sessions) }
                    }
                }
            } label: {
                Text("Project: \(projectName)").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(filter == .all ? DeikoStyle.ink2 : DeikoStyle.mark)
            .tip("Show one project's briefs, or edit a project")
        }
    }

    private var projectName: String {
        switch filter {
        case .all: return "All"
        case .unsorted: return "Unsorted"
        case .collection(let id): return sessions.collections.first { $0.id == id }?.name ?? "All"
        }
    }

    /// The way back from one piece of work, in the band for the same reason
    /// the chips are: nothing clickable lives above the cards in their own
    /// scroll view.
    @ViewBuilder private var workRow: some View {
        if let work {
            HStack(spacing: 10) {
                Button { self.work = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        Text("Show all briefs").font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(ChipButtonStyle(on: false))
                .deikoFocusRing(Capsule())
                .keyboardShortcut(.cancelAction)
                .tip("Back to every brief, newest first (Esc)")
                (Text("Everything about \(sessions.workName(ofTask: work))").font(.system(size: 12, weight: .semibold))
                    + Text("  ·  oldest first").font(.system(size: 11)).foregroundColor(DeikoStyle.ink2))
                    .lineLimit(1)
                Spacer()
                Menu {
                    TaskMenu(task: work, store: sessions)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(DeikoStyle.ink2)
                .tip("Rename this work or open its note")
            }
        }
    }

    /// The brief open on the board, while it still exists. A brief deleted
    /// or trashed while open simply isn't found, and the list comes back.
    private var openBrief: SessionsStore.Item? {
        nav.brief.flatMap { id in sessions.items.first { $0.id == id } }
    }

    @State private var copiedBrief: String?

    /// Back, and the brief's two actions: Copy (the one thing a brief is
    /// for) and everything else behind ⋯ — the card's own menu.
    private func briefRow(_ item: SessionsStore.Item) -> some View {
        HStack(spacing: 10) {
            Button { nav.brief = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text(work.map { "Back to \(sessions.workName(ofTask: $0))" } ?? "Show all briefs")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(ChipButtonStyle(on: false))
            .deikoFocusRing(Capsule())
            .keyboardShortcut(.cancelAction)
            .tip("Back to the board (Esc)")
            Spacer()
            if !item.unfinished, !item.unreadable {
                Button(copiedBrief == item.id ? "Copied" : "Copy the brief") {
                    Task {
                        guard let prompt = await sessions.freshPrompt(sessionDir: item.dir) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.text, forType: .string)
                        copiedBrief = item.id
                        try? await Task.sleep(for: .seconds(1.5))
                        if copiedBrief == item.id { copiedBrief = nil }
                    }
                }
                .buttonStyle(InkButtonStyle())
                .tip("Put this brief on the clipboard, ready to paste into any agent")
            }
            Menu {
                SessionMenu(item: item, store: sessions)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(DeikoStyle.ink2)
            .tip("Open folder, move, or delete this brief")
        }
    }

    private var lede: String {
        if openBrief != nil { return "One brief, as your agent got it." }
        if overCard != nil { return "Let go and they're one piece of work." }
        if overSpace { return "Let go and it stands on its own." }
        if work != nil { return "Drag one out onto empty space and it stands on its own." }
        return "Newest first. Drag one brief onto another to group them."
    }

    /// CHROME ABOVE, CONTENT BELOW, AND NEVER IN THE SAME SCROLL VIEW.
    ///
    /// The other panes use `PaneScroll`, where the title scrolls away with
    /// the content. The board does not, because it has a filter, and the
    /// filter cannot share a scroll view with the cards it filters. Each card
    /// carries four AppKit tracking areas — help, context menu, hover, tap —
    /// and when a segment changed and the grid reflowed from two cards to
    /// thirty-seven, the first card's stale tracking rect landed on the
    /// filter: the segment stuck, and the pointer over it lit the card. Every
    /// version of the filter as a chip died the same way, for the same
    /// reason, before the cause was found.
    ///
    /// So the board is built the way a browser is: a fixed band holding the
    /// title, the search and the filter, a hairline, and a scroll view holding
    /// only the grid. The scroll view clips its content, so a card's tracking
    /// area cannot exist above the hairline whatever the grid is doing.
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Board", lede: lede) {
                    if openBrief == nil {
                        HStack(spacing: 14) {
                            projectMenu
                            searchField
                        }
                    }
                }
                if let item = openBrief { briefRow(item) } else { workRow }
                if openBrief == nil, work == nil { FilingQueueRow() }
            }
            .padding(.horizontal, 26)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollViewReader { scroller in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                Group {
                    if shown.isEmpty && openBrief == nil {
                        EmptyPane(
                            title: sessions.items.isEmpty ? "The board is empty" : "Nothing here yet",
                            line: sessions.items.isEmpty
                                ? "Briefs pin themselves here as you record them. Nothing is uploaded — they live in a folder on this Mac."
                                : "Try another project, a task name, an app name, or a word you said."
                        )
                    } else if let item = openBrief {
                        BriefView(item: item, store: sessions) { task in
                            nav.brief = nil
                            query = ""
                            work = task
                        }
                    } else {
                        timeline
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { sessions.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in sessions.undoManager = manager }
            // A brief opens at its top, whatever depth of board it came from.
            .onChange(of: nav.brief) { _, _ in scroller.scrollTo("top", anchor: .top) }
            }
            // EMPTY SPACE IS A PLACE TO DROP. A card's own destination wins
            // over this one, so only a drop between or below cards lands here.
            .dropDestination(for: String.self) { ids, _ in
                standAlone(ids)
            } isTargeted: { overSpace = $0 }
        }
    }

    /// NOTHING MOVES UNLESS YOU MOVE IT. Newest first under the day it was
    /// said, so a brief just recorded is always the first card — never
    /// halfway down the page inside whichever task Deiko thought it was.
    /// No pinned headers: a pinned view fights the scroll view for the same
    /// tracking areas the fixed band escaped.
    private var timeline: some View {
        let sections = work == nil
            ? BoardTimeline.sections(shown, date: \.date, now: Date())
            : [(title: "", items: shown)]
        return VStack(alignment: .leading, spacing: 26) {
            // Above the cards, for the reason the day heading is: it must
            // win the click where the two meet.
            if let work { WorkNotes(task: work, store: sessions).zIndex(1) }
            ForEach(sections, id: \.title) { section in
                let fold = BoardTimeline.fold(section.items, setAside: \.setAside)
                VStack(alignment: .leading, spacing: 14) {
                    if !section.title.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(section.title).deikoTitle(15)
                            Text("· \(section.items.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(DeikoStyle.ink2)
                            // SET ASIDE, FOLDED INTO THE HEADING: mic checks
                            // and unfinished recordings take no row of their
                            // own, so they never push the work down or break
                            // its grid. Opens in place, under the heading.
                            if !fold.folded.isEmpty {
                                foldLine(section.title, count: fold.folded.count)
                                    .padding(.leading, 12)
                            }
                        }
                        .accessibilityAddTraits(.isHeader)
                        // Above the grid: where the two meet, the chip wins the click.
                        .zIndex(1)
                    }
                    if unfolded.contains(section.title) { grid(fold.folded).padding(.bottom, 8) }
                    grid(fold.cards)
                }
            }
        }
    }

    private func grid(_ items: [SessionsStore.Item]) -> some View {
        CardGrid {
            ForEach(items) { item in
                BoardCard(
                    item: item, store: sessions, showsTag: work == nil,
                    openWork: { task in
                        query = ""
                        work = task
                    },
                    openBrief: { nav.brief = item.id },
                    dropped: { join($0, onto: item) },
                    targeted: { overCard = $0 ? item.id : (overCard == item.id ? nil : overCard) }
                )
            }
        }
    }

    /// "3 mic checks & scraps", a hairline chip on a hairline rule beside the
    /// day's heading: the quietest thing on the board until it is clicked.
    /// Named for what is in it — "set aside" said only that something was
    /// hidden, never what.
    private func foldLine(_ key: String, count: Int) -> some View {
        let open = unfolded.contains(key)
        return HStack(spacing: 10) {
            Button {
                if open { unfolded.remove(key) } else { unfolded.insert(key) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("\(count) mic checks & scraps").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(ChipButtonStyle(on: false))
            .deikoFocusRing(Capsule())
            .tip(open
                  ? "Tuck them away again"
                  : "Recordings too short or too broken to be a brief: mic checks, thank-yous, ones that never finished. Tucked here so they don't bury your work. Click to see them.")
            .accessibilityLabel("\(count) mic checks and scraps")
            .accessibilityValue(open ? "Shown" : "Folded")
            Rectangle().fill(DeikoStyle.hairline).frame(height: 1)
        }
    }

    /// A brief dropped on another: the same work from now on, by hand, so the
    /// classifier never files it anywhere else. A name is asked for only when
    /// the work is new and has none, prefilled from the brief it was dropped on.
    private func join(_ ids: [String], onto target: SessionsStore.Item) -> Bool {
        guard let id = ids.first,
              let dragged = sessions.items.first(where: { $0.id == id }),
              !dragged.unfinished, !dragged.unreadable, !target.unfinished, !target.unreadable,
              let plan = BoardTimeline.drop(
                  dragged: (dragged.id, dragged.setAside ? "" : dragged.task),
                  target: (target.id, target.task, Tasks.own(target.id), target.setAside),
                  count: { sessions.workCounts[$0] ?? 0 }
              )
        else { return false }
        let named = sessions.taskTitles[plan.task] != nil
        // After the drop returns: a modal inside a drop handler holds the
        // drag session open under it.
        DispatchQueue.main.async {
            if !named {
                guard let name = Collections.askText(
                    title: "Name this piece of work",
                    informative: "These two briefs go together now. The next one that belongs with them joins them.",
                    value: target.title,
                    placeholder: "What the work is",
                    confirm: "Group them"
                ), !name.isEmpty else { return }
                Tasks.name(plan.task, name)
            }
            if plan.placeTarget { sessions.move(target, toTask: plan.task) }
            sessions.move(dragged, toTask: plan.task)
        }
        return true
    }

    /// A brief dropped on empty space: its own work again. Refused when it
    /// already is, or when other briefs have since joined the task it
    /// started — "its own" would join them (see `ownTaskTakenHelp`).
    private func standAlone(_ ids: [String]) -> Bool {
        guard let id = ids.first,
              let item = sessions.items.first(where: { $0.id == id }),
              !item.unfinished, !item.unreadable
        else { return false }
        let own = Tasks.own(item.id)
        guard item.odds || item.task != own, !sessions.hasOthers(inTask: own, besides: item.id) else { return false }
        sessions.move(item, toTask: own)
        return true
    }

    private var searchField: some View {
        TextField("Search briefs", text: $query)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .frame(width: 190)
            .focused($searching)
            // ⌘F puts the cursor here. A search field nobody can reach
            // from the keyboard is a search field for other people.
            .overlay {
                Button("") { searching = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }
}

/// A chip that is a button. `on` is the wash chip the system already has
/// (DESIGN.md §Chips), with an accent edge under the pointer; off is a hairline
/// outline that takes a faint wash.
///
/// THE WHOLE LOOK LIVES IN A `ButtonStyle`, and that is the point rather than
/// a tidying. This was built the way `SidebarRow` is — `.buttonStyle(.plain)`
/// with the capsule drawn in the label's `.background` — and the sidebar works.
/// In a pane it did not: the chips drew correctly and took neither a hover nor
/// a click, while the pointer carried on to the cards. The sidebar is not
/// inside a `ScrollView` and every pane is, and inside a pane every control
/// that works is either a menu or a custom `ButtonStyle` (`InkButtonStyle` on
/// the Dashboard). The chip was the only `.plain` button in a scrolling pane,
/// and the only dead one. So it is built the way the ones that work are built.
/// The review card's "Carries on from which?" chips borrow it, for the same reason.
struct ChipButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, on: on)
    }

    /// Named `Chip`, not `Body`: `Body` is the protocol's own associated type
    /// and a nested struct by that name satisfies it instead — the same trap
    /// `InkButtonStyle` documents.
    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let on: Bool
        /// Hover lives with the drawing rather than outside the button, so
        /// nothing between the two can get out of step.
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(on ? DeikoStyle.mark : DeikoStyle.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    if on {
                        Capsule().fill(DeikoStyle.accentSoft)
                            .overlay(Capsule().strokeBorder(DeikoStyle.accent.opacity(hovering ? 0.6 : 0), lineWidth: 1))
                    } else {
                        Capsule()
                            .fill(hovering ? DeikoStyle.accentSoft.opacity(0.5) : .clear)
                            .overlay(Capsule().strokeBorder(DeikoStyle.hairline, lineWidth: 1))
                    }
                }
                // The whole capsule, not the letters.
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Columns of at least `minColumn`, 14pt apart, each row as tall as its
/// tallest card, cards top-aligned: `LazyVGrid(.adaptive(minimum:))`'s look,
/// without its laziness.
///
/// WHY NOT LAZY. A lazy grid guesses the height of every row it has not
/// drawn yet, and corrects the guess as the row scrolls in. With an open
/// "mic checks & scraps" fold — a second grid above the day's cards — each
/// correction moved everything below it, and scrolling past it jittered
/// back and forth. This lays every card out once, at its real height. The
/// board is a few hundred cards at most; laying them all out is cheap.
struct CardGrid: SwiftUI.Layout {
    var minColumn: CGFloat = 210
    var spacing: CGFloat = 14

    private func columns(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minColumn + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// Each row's cards and its height: the tallest card's, at the column width.
    private func rows(_ subviews: LayoutSubviews, _ count: Int, _ column: CGFloat) -> [(range: Range<Int>, height: CGFloat)] {
        let proposal = ProposedViewSize(width: column, height: nil)
        var rows: [(range: Range<Int>, height: CGFloat)] = []
        for start in stride(from: 0, to: subviews.count, by: count) {
            let range = start..<min(start + count, subviews.count)
            var height: CGFloat = 0
            for index in range { height = max(height, subviews[index].sizeThatFits(proposal).height) }
            rows.append((range, height))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        // A scroll view also asks with `.infinity`; three columns then.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (minColumn * 3 + spacing * 2)
        let (count, column) = columns(width)
        let all = rows(subviews, count, column)
        var height: CGFloat = 0
        for row in all { height += row.height }
        height += spacing * CGFloat(max(0, all.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let (count, column) = columns(bounds.width)
        let size = ProposedViewSize(width: column, height: nil)
        var y = bounds.minY
        for row in rows(subviews, count, column) {
            for (i, index) in row.range.enumerated() {
                let x = bounds.minX + CGFloat(i) * (column + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: UnitPoint.topLeading, proposal: size)
            }
            y += row.height + spacing
        }
    }
}


private struct BoardCard: View {
    let item: SessionsStore.Item
    let store: SessionsStore
    /// Off inside one piece of work, where every card would wear the same one.
    let showsTag: Bool
    let openWork: (String) -> Void
    let openBrief: () -> Void
    let dropped: ([String]) -> Bool
    let targeted: (Bool) -> Void
    @State private var hovering = false
    @State private var dropping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A brief is being held over this card.
    private var lit: Bool { dropping || UIShotPose.dropTarget == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let first = item.crops.first {
                // SET ASIDE BY ITS PICTURES, NOT ITS WORDS: the thumbnail
                // fades, the text keeps full contrast (an opacity of 0.6 on
                // the whole card put it under AA).
                CropThumbnail(path: first, height: 74)
                    .opacity(item.setAside ? 0.4 : 1)
            }
            // EVERYTHING THIS CARD CAN DO, VISIBLE AT REST.
            //
            // The verbs were reachable only by right-click, a gesture you
            // have to already suspect is there. Nothing on the card said so,
            // so copying a brief or filing it in a collection was a feature
            // you found by accident or never found.
            //
            // The same `ellipsis.circle` the Personas pane uses, not a second
            // affordance invented for this one. Beside the title rather than
            // on the metadata line, which it crowded into wrapping a date
            // mid-string; and not over the thumbnail, because a crop is
            // somebody else's pixels and this app does not paint its own
            // colours onto those.
            HStack(alignment: .top, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.line == nil ? DeikoStyle.ink2 : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu {
                    SessionMenu(item: item, store: store)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // TINT, NOT `foregroundStyle`. A menu label takes its colour
                // from the tint, so the window-wide accent won and every card
                // wore a full-strength indigo dot — a grid of buttons with the
                // briefs arranged around them. Quiet until the card is under
                // the cursor.
                .tint(hovering ? DeikoStyle.mark : DeikoStyle.ink2)
                .tip("Copy, open, file or delete this brief")
            }
            if let link {
                Text(link)
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .lineLimit(1)
            }
            // WHAT CAME OF IT, in the agent's own words, when one wrote back.
            //
            // Labelled rather than dropped in bare: an unmarked second
            // sentence under the narration reads as more of what the
            // developer said, and this is the one line on the card that
            // somebody else wrote. Both stay in the second voice — the
            // narration is still how you recognise the session.
            if let outcome = item.outcome {
                (Text("What happened: ").font(.system(size: 11, weight: .medium))
                    + Text(outcome).font(.system(size: 11)))
                    .foregroundStyle(DeikoStyle.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ONE LINE, the date whole: "Sat, 19 Sep at 19:01" broke in two
            // on a narrow card; the repo gives way first.
            HStack(spacing: 6) {
                Text(Self.stamp(item.date)).layoutPriority(1)
                if !item.crops.isEmpty {
                    Text("·")
                    Text("\(item.crops.count) crop\(item.crops.count == 1 ? "" : "s")").layoutPriority(1)
                }
                if let repo = item.repo { Text("·"); Text(repo) }
            }
            .lineLimit(1)
            .font(.system(size: 11))
            .foregroundStyle(DeikoStyle.ink2)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                .fill(lit ? DeikoStyle.accentSoft : DeikoStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .strokeBorder(lit || hovering ? DeikoStyle.accent : DeikoStyle.hairline, lineWidth: lit ? 1.5 : 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: hovering || lit ? 16 : 10, x: 0, y: hovering || lit ? 9 : 5)
        )
        // NO GROWING, NO LIFTING. A card that scaled up on hover or drop
        // reached over the controls beside it — a day heading's chip, a
        // neighbour's tag — and took their clicks. A card says "hovered" and
        // "drop here" with its border and shadow alone, inside its own frame.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: lit)
        .onHover { hovering = $0 }
        // A CLICK OPENS THE BRIEF, in the app — as a card opens on any board.
        // The card's own controls (its tag, ⋯, "Put with…?", Undo) are buttons
        // and keep their clicks; a drag still groups. A double-click is two
        // clicks, so it opens it too.
        .contentShape(RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
        .onTapGesture { openBrief() }
        // Kept beside the button: somebody who already reaches for a
        // right-click should not have to learn a new way to do it.
        .contextMenu { SessionMenu(item: item, store: store) }
        .tip("Click to open this brief · drag onto another to group them")
        .onAppear { store.sawFiling(item) }
        .draggable(item.id) { preview }
        .dropDestination(for: String.self) { ids, _ in
            dropped(ids)
        } isTargeted: { over in
            dropping = over && !item.unfinished && !item.unreadable
            targeted(dropping)
        }
    }

    /// Where this brief belongs, in one line at the foot of the card. While a
    /// brief is held over it, what letting go will do instead.
    @ViewBuilder private var footer: some View {
        let count = store.workCounts[item.task] ?? 0
        if lit {
            Label("Same work as this", systemImage: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DeikoStyle.mark)
                .padding(.vertical, 3)
        } else if store.announces(item) {
            // FILING IS VISIBLE. Deiko put this with earlier work on its own;
            // said once, beside the way to take it back.
            HStack(spacing: 8) {
                WorkTag(text: "Added to \(store.workName(ofTask: item.task))") { openWork(item.task) }
                    .tip("Deiko put this with \(count - 1) earlier brief\(count == 2 ? "" : "s") in “\(store.title(ofTask: item.task))”. Click to see everything about it.")
                let own = Tasks.own(item.id)
                let taken = store.hasOthers(inTask: own, besides: item.id)
                Button("Undo") { store.move(item, toTask: own) }
                    .buttonStyle(TextButtonStyle())
                    .disabled(taken)
                    .tip(taken ? SessionsStore.ownTaskTakenHelp : "Make it its own work again")
                    .fixedSize()
            }
        } else if let target = suggestion {
            // ONE CLICK TO ANSWER. "Looks like Sitemap?" was a question with
            // no way to say yes but a drag. Yes files it by hand, exactly as
            // a drag would; no makes it its own work, as Undo does.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { suggestionButtons(target) }
                VStack(alignment: .leading, spacing: 4) { suggestionButtons(target) }
            }
        } else if item.setAside {
            Text("Scrap")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DeikoStyle.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(DeikoStyle.hairline, lineWidth: 1))
                .tip(item.odds
                      ? "Too short or unclear to be a brief — a mic check, a thank-you. Drag it onto a brief to put it with that work."
                      : "This recording never became a brief.")
        } else if showsTag, count >= 2 {
            WorkTag(text: store.workName(ofTask: item.task), count: count) { openWork(item.task) }
                .tip("See everything about \(store.workName(ofTask: item.task)): its briefs, where it stands, what was decided")
        }
    }

    @ViewBuilder private func suggestionButtons(_ target: String) -> some View {
        Button {
            store.move(item, toTask: target)
        } label: {
            Label("Put with \(store.workName(ofTask: target))?", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(TightLabel())
                .lineLimit(1)
        }
        .buttonStyle(ChipButtonStyle(on: false))
        .deikoFocusRing(Capsule())
        .tip("Deiko thinks this carries on “\(store.title(ofTask: target))”. Click to put it there, or drag it onto any brief.")
        let own = Tasks.own(item.id)
        let taken = store.hasOthers(inTask: own, besides: item.id)
        Button("Not this one") { store.move(item, toTask: own) }
            .buttonStyle(TextButtonStyle(quiet: true))
            .disabled(taken)
            .tip(taken ? SessionsStore.ownTaskTakenHelp : "Keep it as its own work. Deiko won't ask again.")
            .fixedSize()
    }

    private var preview: some View {
        Text(item.title)
            .font(.system(size: 12.5))
            .lineLimit(2)
            .padding(11)
            .frame(width: 220, alignment: .leading)
            .background(DeikoStyle.card, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
    }

    /// A task id, while that task still has briefs on the board.
    private func live(_ id: String?) -> String? {
        id.flatMap { id in store.items.contains { $0.task == id && !$0.odds } ? id : nil }
    }

    /// The work Deiko thinks this brief carries on — asked at the card's
    /// foot as "Put with …?". While that question is open, "Related to" waits.
    private var suggestion: String? { live(item.maybe) }

    private var link: String? {
        guard suggestion == nil, let id = live(item.related) else { return nil }
        return "Related to \(store.workName(ofTask: id))"
    }

    /// Day and time, because six sessions from one afternoon were
    /// typographically identical; the year appears only when it is not this
    /// one, so the common case stays short.
    static let when: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f
    }()

    static let whenOlder: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    static func stamp(_ date: Date) -> String {
        let thisYear = Calendar.current.component(.year, from: Date())
        let year = Calendar.current.component(.year, from: date)
        return year == thisYear ? when.string(from: date) : whenOlder.string(from: date)
    }
}

/// A card's work tag: the wash chip (DESIGN.md §Chips), name first and the
/// count quiet, the name giving way before the count does. Clicking it opens
/// that work on its own — which the chevron says at rest and the accent edge
/// says under the pointer, because a wash chip alone reads as a label.
private struct WorkTag: View {
    let text: String
    var count: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(text).lineLimit(1).truncationMode(.tail)
                if let count { Text("· \(count)").opacity(0.7).fixedSize() }
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold)).opacity(0.8)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(ChipButtonStyle(on: true))
        .deikoFocusRing(Capsule())
    }
}

/// Icon and title 4pt apart: the system's gap is wide for an 11pt chip.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}

/// A verb said as a word: mark indigo, underlined under the pointer. A
/// `ButtonStyle` for the reason `ChipButtonStyle` gives — a `.plain` button
/// in a scrolling pane took no clicks.
/// "Waiting to be filed": briefs that went to their agent while Deiko
/// couldn't reach its filing service, and are filed when it can.
private struct FilingQueueRow: View {
    @ObservedObject private var queue = FilingQueue.shared

    var body: some View {
        if queue.waiting > 0 {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(DeikoStyle.mark)
                Text(queue.waiting == 1 ? "1 brief is waiting to be filed" : "\(queue.waiting) briefs are waiting to be filed")
                    .font(.system(size: 12, weight: .semibold))
                Text("They reached your agent. Deiko files them into their tasks when it can reach its filing service.")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(queue.working ? "Filing…" : "Try now") { queue.fileAll(tryStuck: true) }
                    .buttonStyle(TextButtonStyle())
                    .disabled(queue.working)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(DeikoStyle.accentSoft))
        }
    }
}

private struct TextButtonStyle: ButtonStyle {
    /// Ink 2 instead of the mark: the verb beside a stronger one.
    var quiet = false

    func makeBody(configuration: Configuration) -> some View { Word(configuration: configuration, quiet: quiet) }

    private struct Word: View {
        let configuration: ButtonStyleConfiguration
        let quiet: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled && !quiet ? DeikoStyle.mark : DeikoStyle.ink2)
                .underline(hovering && enabled)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// The head of one piece of work: its name, its span, what you last asked,
/// and what agents wrote back about it — where it stands and what was
/// decided, read from each brief's `outcome.md`. Everything else the next
/// brief carries (every brief, every note in full) waits behind "Full
/// history". On the wall, because it is a header; above the cards in the
/// stack (`zIndex`), so a hovered card never takes its buttons' clicks.
private struct WorkNotes: View {
    let task: String
    let store: SessionsStore
    @State private var briefs: [Brief] = []
    @State private var expanded = UIShotPose.notesExpanded
    @State private var history = UIShotPose.historyOpen

    /// One brief as read off disk for this panel.
    struct Brief: Identifiable {
        let id: String
        let date: Date
        let asked: String?
        let outcome: BoardTimeline.Outcome?
    }

    /// Lines per block while folded. Whole lines, never a line cut short.
    private static let folded = 3

    var body: some View {
        let items = store.items.filter { $0.task == task && !$0.setAside }
        let state = BoardTimeline.workState(briefs.map { .init(date: $0.date, asked: $0.asked, outcome: $0.outcome) })
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                let name = store.workName(ofTask: task), title = store.title(ofTask: task)
                Text(name)
                    .deikoTitle(19)
                    .fixedSize(horizontal: false, vertical: true)
                // The whole title under the short name, when they differ.
                if title.trimmingCharacters(in: .punctuationCharacters) != name.trimmingCharacters(in: .punctuationCharacters) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeikoStyle.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(span(items))
                    .font(.system(size: 11.5))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            if let asked = state.lastAsked {
                VStack(alignment: .leading, spacing: 4) {
                    heading("You last asked", meta: Self.day.string(from: asked.date))
                    Text(asked.text)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let wrote = state.wroteBack {
                // One column at a reading measure: two side by side squeezed
                // each note into a narrow wrap at this window's width.
                VStack(alignment: .leading, spacing: 16) {
                    blocks(state, wrote: wrote)
                    let hidden = max(0, state.open.count - Self.folded) + max(0, state.decided.count - Self.folded)
                    if hidden > 0 || expanded {
                        toggle(expanded ? "Show less" : "Show all \(state.open.count + state.decided.count) notes",
                               open: expanded) { expanded.toggle() }
                            .padding(.top, -6)
                    }
                }
            } else {
                Text("No notes yet. When an agent finishes work here, what's left and what got decided shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                toggle("Full history", open: history) { history.toggle() }
                    .tip("Every brief in this work, and everything agents wrote back, in full")
                if history { fullHistory }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DeikoStyle.wall, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
        .task(id: items.map(\.id).joined(separator: ",")) {
            let sources = items.map { (id: $0.id, dir: $0.dir, date: $0.date, said: $0.line) }
            briefs = await Task.detached(priority: .userInitiated) {
                sources.map { b in
                    let url = URL(fileURLWithPath: b.dir)
                    let summary = try? String(contentsOf: url.appendingPathComponent("review-summary.txt"), encoding: .utf8)
                    let outcome = (try? String(contentsOf: url.appendingPathComponent("outcome.md"), encoding: .utf8))
                        .map(BoardTimeline.outcome)
                        .flatMap { o in o.did.isEmpty && o.decided.isEmpty && o.open.isEmpty && o.files.isEmpty ? nil : o }
                    return Brief(id: b.id, date: b.date,
                                 asked: BoardTimeline.asked(summary: summary, narration: b.said), outcome: outcome)
                }
            }.value
        }
    }

    @ViewBuilder private func blocks(_ state: BoardTimeline.WorkState, wrote: Date) -> some View {
        let limit = expanded ? Int.max : Self.folded
        VStack(alignment: .leading, spacing: 6) {
            heading("Where it stands", meta: meta(wrote, agent(on: wrote)))
            if state.open.isEmpty {
                note("Nothing left open.")
            } else {
                ForEach(Array(state.open.prefix(limit).enumerated()), id: \.offset) { note($0.element.text) }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        if !state.decided.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                heading("Decided", meta: nil)
                ForEach(Array(state.decided.prefix(limit).enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 1) {
                        note(line.text)
                        Text(meta(line.date, line.agent))
                            .font(.system(size: 10.5))
                            .foregroundStyle(DeikoStyle.ink2)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// Every brief, oldest first like the cards below, each with what its
    /// agent wrote back under the four headings; then the task's id and the
    /// history file Deiko compiles from them.
    private var fullHistory: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(briefs.sorted { $0.date < $1.date }) { brief in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(BoardCard.stamp(brief.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DeikoStyle.ink2)
                        .frame(width: 118, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(brief.asked ?? "Nothing clear was said")
                            .font(.system(size: 12))
                            .foregroundStyle(brief.asked == nil ? DeikoStyle.ink2 : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let o = brief.outcome {
                            section("Did", o.did)
                            section("Decided", o.decided)
                            section("Open", o.open)
                            section("Files", o.files)
                            if let agent = o.agent {
                                Text("Written back by \(agent)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(DeikoStyle.ink2)
                            }
                        } else {
                            Text("No agent wrote back on this one.")
                                .font(.system(size: 11))
                                .foregroundStyle(DeikoStyle.ink2)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                // No raw task id here: it is plumbing, not something a person
                // reads. The history file carries it for whoever needs it.
                let file = Tasks.notePath(for: task)
                if FileManager.default.fileExists(atPath: file.path) {
                    Button("Open the history file") { NSWorkspace.shared.open(file) }
                        .buttonStyle(TextButtonStyle())
                        .tip(file.path)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            (Text("\(title): ").font(.system(size: 11, weight: .semibold))
                + Text(lines.joined(separator: " · ")).font(.system(size: 11.5)))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ title: String, meta: String?) -> some View { NoteStyle.heading(title, meta: meta) }
    private func note(_ text: String) -> some View { NoteStyle.note(text) }
    private func toggle(_ label: String, open: Bool, action: @escaping () -> Void) -> some View {
        NoteStyle.toggle(label, open: open, action: action)
    }

    /// "19 Sep · Claude Code", or just the day when no agent signed it.
    private func meta(_ date: Date, _ agent: String?) -> String {
        [Self.day.string(from: date), agent].compactMap { $0 }.joined(separator: " · ")
    }

    private func agent(on date: Date) -> String? {
        briefs.first { $0.date == date }?.outcome?.agent
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    /// "5 briefs · 16 Sep – 18 Sep · build"
    private func span(_ briefs: [SessionsStore.Item]) -> String {
        let dates = briefs.map(\.date)
        var parts = ["\(briefs.count) brief\(briefs.count == 1 ? "" : "s")"]
        if let first = dates.min(), let last = dates.max() {
            let a = Self.day.string(from: first), b = Self.day.string(from: last)
            parts.append(a == b ? a : "\(a) – \(b)")
        }
        if let project = store.collections.first(where: { $0.id == briefs.first?.collection })?.name {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }
}

// ── One brief ──────────────────────────────────────────────────────────────

/// Everything the brief view shows, read off disk once, off the main thread.
/// Only reads: opening a brief never re-runs the pipeline the way the review
/// panel's `load` does.
private struct BriefDetail: Sendable {
    var asked: String?
    var narration: String?
    var edited = false
    var crops: [(path: String, said: String?)] = []
    var digest: BriefDigest?
    var summary: BriefSummary?
    var context: SessionContext?
    var outcome: BoardTimeline.Outcome?
    var wroteBack: Date?
    var persona: String?
    var prompt: String?

    static func load(dir: String, line: String?) -> BriefDetail {
        let url = URL(fileURLWithPath: dir)
        let read = { (name: String) in try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) }
        var d = BriefDetail()
        let digest = try? BriefPipeline.digest(sessionDir: dir)
        d.digest = digest
        d.summary = digest?.summary
        d.asked = BoardTimeline.asked(summary: read("review-summary.txt"), narration: line)
        let override = read("narration.override.txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
        d.narration = override.flatMap { $0.isEmpty ? nil : $0 } ?? line
        d.edited = override?.isEmpty == false || digest?.summary.narrationEdited == true
        d.crops = (digest?.cropPaths ?? []).map { ($0, digest?.captions[$0]) }
        d.context = SessionContext.read(sessionDir: dir)
        let outcomeFile = url.appendingPathComponent("outcome.md")
        if let text = read("outcome.md") {
            let o = BoardTimeline.outcome(text)
            if !(o.did.isEmpty && o.decided.isEmpty && o.open.isEmpty && o.files.isEmpty) {
                d.outcome = o
                d.wroteBack = (try? FileManager.default.attributesOfItem(atPath: outcomeFile.path))?[.modificationDate] as? Date
            }
        }
        d.persona = Personas.name(forSession: dir)
        d.prompt = read("prompt.txt")
        return d
    }
}

/// ONE BRIEF, READ LIKE THE HANDOFF IT WAS: what you asked, what you said,
/// what you pointed at (each screenshot with the sentence said over it),
/// what came back, and the brief itself behind a disclosure. The work view
/// explains a task; this is the only place a brief in no task is explained
/// at all. A reading column, not panes: narrations run long, and a
/// screenshot is only worth opening at a size you can read.
private struct BriefView: View {
    let item: SessionsStore.Item
    @ObservedObject var store: SessionsStore
    let openWork: (String) -> Void
    @State private var detail: BriefDetail?
    @State private var showPrompt = UIShotPose.promptOpen
    @State private var allCrops = false
    /// Screenshots shown before "Show all": a page of twelve full-size
    /// images buries everything under them.
    private static let firstCrops = 4
    /// The screenshot Quick Look is showing, or nil.
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            if item.unfinished || item.unreadable {
                NoteStyle.note(item.unfinished
                    ? "This recording never became a brief — there is nothing here but the audio's folder."
                    : "Deiko couldn't read this brief's file. Its folder is still there to open.")
            } else if let detail {
                // Not twice: a short brief's title IS what was said.
                if !Self.same(detail.narration, detail.asked ?? item.title) { said(detail) }
                pointedAt(detail)
                // A mic check has nobody to write back.
                if !item.setAside { cameBack(detail) }
                details(detail)
                briefAsSent(detail)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .quickLookPreview($preview, in: (detail?.crops ?? []).map { URL(fileURLWithPath: $0.path) })
        .task(id: item.id) {
            let dir = item.dir, line = item.line
            detail = await Task.detached(priority: .userInitiated) { BriefDetail.load(dir: dir, line: line) }.value
        }
    }

    // ── Header ──────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail?.asked ?? item.title)
                    .deikoTitle(19)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(meta)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            filing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DeikoStyle.wall, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
    }

    /// "Tue 16 Sep at 01:39 · 43s · Chrome · Pricing"
    private var meta: String {
        var parts = [BoardCard.stamp(item.date)]
        if let ms = detail?.summary?.durationMs, ms > 0 { parts.append(Self.duration(ms)) }
        if !item.apps.isEmpty { parts.append(item.apps.prefix(2).joined(separator: ", ")) }
        if let page = item.pages.first ?? item.repo { parts.append(page) }
        return parts.joined(separator: " · ")
    }

    /// Where it is filed, in the chips the board already uses.
    @ViewBuilder private var filing: some View {
        let count = store.workCounts[item.task] ?? 0
        HStack(spacing: 8) {
            if item.setAside {
                quietChip("Scrap")
            } else if count >= 2 {
                WorkTag(text: store.workName(ofTask: item.task), count: count) { openWork(item.task) }
                    .tip("See everything about \(store.workName(ofTask: item.task))")
            } else {
                quietChip("On its own")
                    .tip("This brief isn't part of any piece of work yet — Deiko didn't find earlier briefs it carries on. When the next brief about the same thing arrives, they're grouped into one task, and each brief then carries the other's story. Group it yourself with Move to task, or drag it onto another brief.")
                if let target = live(item.maybe) {
                    Button {
                        store.move(item, toTask: target)
                    } label: {
                        Label("Put with \(store.workName(ofTask: target))?", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .labelStyle(TightLabel())
                            .lineLimit(1)
                    }
                    .buttonStyle(ChipButtonStyle(on: false))
                    .deikoFocusRing(Capsule())
                    .tip("Deiko thinks this carries on “\(store.title(ofTask: target))”. Click to put it there.")
                } else if let related = live(item.related) {
                    Text("Related to \(store.workName(ofTask: related))")
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                }
            }
            if let project = store.collections.first(where: { $0.id == item.collection })?.name {
                Text(project).font(.system(size: 11)).foregroundStyle(DeikoStyle.ink2)
            }
            if let tier = detail?.context?.tierLabel {
                Text(tier)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DeikoStyle.accentSoft, in: Capsule())
                    .tip(detail?.context?.tierHelp ?? "")
            }
        }
    }

    private func quietChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DeikoStyle.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(DeikoStyle.hairline, lineWidth: 1))
    }

    private func live(_ id: String?) -> String? {
        id.flatMap { id in store.items.contains { $0.task == id && !$0.odds } ? id : nil }
    }

    // ── Sections ────────────────────────────────────────────────────────────

    @ViewBuilder private func said(_ d: BriefDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteStyle.heading("What you said", meta: d.edited ? "edited" : nil)
            Text(d.narration ?? "Nothing was said — only pointed.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(d.narration == nil ? DeikoStyle.ink2 : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func pointedAt(_ d: BriefDetail) -> some View {
        let withheld = (d.digest?.cropsWithheld ?? 0) > 0
        if !d.crops.isEmpty || withheld {
            VStack(alignment: .leading, spacing: 10) {
                NoteStyle.heading("What you pointed at", meta: d.crops.isEmpty ? nil : "\(d.crops.count)")
                CardGrid(minColumn: 280) {
                    ForEach(allCrops ? d.crops : Array(d.crops.prefix(Self.firstCrops)), id: \.path) { crop in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { preview = URL(fileURLWithPath: crop.path) } label: {
                                LargeCrop(path: crop.path)
                            }
                            .buttonStyle(.plain)
                            .tip("Open it large (Quick Look)")
                            if let said = crop.said, !said.isEmpty {
                                Text("while you said “\(said)”")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DeikoStyle.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if d.crops.count > Self.firstCrops {
                    NoteStyle.toggle(allCrops ? "Show fewer" : "Show all \(d.crops.count) screenshots", open: allCrops) {
                        allCrops.toggle()
                    }
                }
                if withheld, let digest = d.digest {
                    NoteStyle.note(ReviewView.withheldSentence(digest))
                }
            }
        }
    }

    @ViewBuilder private func cameBack(_ d: BriefDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let o = d.outcome {
                NoteStyle.heading("What came back", meta: [o.agent, d.wroteBack.map { Self.day.string(from: $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                NoteStyle.lines("Did", o.did)
                NoteStyle.lines("Decided", o.decided)
                NoteStyle.lines("Still open", o.open)
                NoteStyle.lines("Files", o.files)
            } else {
                NoteStyle.heading("What came back", meta: nil)
                NoteStyle.note("Nothing back yet — when your agent finishes, its notes land here.")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private func details(_ d: BriefDetail) -> some View {
        let rows = Self.detailRows(d, repo: item.repo)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NoteStyle.heading("Details", meta: nil)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(rows, id: \.0) { row in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(row.0).foregroundStyle(DeikoStyle.ink2)
                            Text(row.1)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11.5))
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    @ViewBuilder private func briefAsSent(_ d: BriefDetail) -> some View {
        if let prompt = d.prompt {
            VStack(alignment: .leading, spacing: 10) {
                NoteStyle.toggle("The brief as your agent got it", open: showPrompt) { showPrompt.toggle() }
                    .tip("Exactly what Copy the brief puts on the clipboard")
                if showPrompt {
                    Text(prompt)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(DeikoStyle.card, in: RoundedRectangle(cornerRadius: DeikoStyle.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: DeikoStyle.controlRadius).strokeBorder(DeikoStyle.hairline, lineWidth: 1))
                }
            }
        }
    }

    /// Label and value for each detail the brief has; empty ones are left out.
    static func detailRows(_ d: BriefDetail, repo: String?) -> [(String, String)] {
        let summary = d.summary
        let keys = summary?.keys
        var rows: [(String, String)] = []
        rows.append(("Windows", (summary?.windows ?? []).prefix(3).joined(separator: "\n")))
        rows.append(("Pages", (keys?.pages ?? []).joined(separator: ", ")))
        rows.append(("Files", (keys?.files ?? []).joined(separator: ", ")))
        rows.append(("Tickets", (keys?.tickets ?? []).joined(separator: ", ")))
        rows.append(("Repo", repo ?? ""))
        rows.append(("Written as", d.persona ?? ""))
        rows.append(("Transcribed by", transcriber(summary?.transcriber)))
        if let summary {
            let note = ReviewView.degradedSentence(summary.degradedReason, degraded: summary.degraded ?? false)
            rows.append(("Note", note ?? ""))
        }
        return rows.filter { !$0.1.isEmpty }
    }

    // ── Formatting ──────────────────────────────────────────────────────────

    /// The same words, ignoring case, spacing and a closing full stop.
    static func same(_ a: String?, _ b: String) -> Bool {
        let norm = { (s: String) in
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return a.map { norm($0) == norm(b) } ?? true
    }

    static func duration(_ ms: Double) -> String {
        let s = Int((ms / 1000).rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    static func transcriber(_ name: String?) -> String {
        guard let name else { return "" }
        if name == "on-device" { return "This Mac" }
        if name.hasPrefix("groq") { return "Groq, with your key" }
        if name == "deiko" { return "Deiko's service" }
        return name.capitalized
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
}

/// A screenshot whole — `.fit`, never the card's cropped `.fill` — at a size
/// it can be read, decoded off the main thread through the shared cache.
private struct LargeCrop: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                DeikoStyle.wall.aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 320, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DeikoStyle.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .task(id: path) { image = await Thumbnails.shared.image(path, maxPoints: 640) }
        .accessibilityLabel("Screenshot")
    }
}

/// The note blocks the work view and the brief view both write in: a 12pt
/// semibold heading with quiet meta, 12pt ink-2 notes, and the text toggle.
@MainActor
private enum NoteStyle {
    static func heading(_ title: String, meta: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let meta, !meta.isEmpty {
                Text(meta).font(.system(size: 11)).foregroundStyle(DeikoStyle.ink2)
            }
        }
    }

    static func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DeikoStyle.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// "Did: …" — one labelled block, nothing when there are no lines.
    @ViewBuilder static func lines(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DeikoStyle.ink2)
                ForEach(Array(lines.enumerated()), id: \.offset) { note($0.element) }
            }
        }
    }

    static func toggle(_ label: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .buttonStyle(TextButtonStyle())
        .deikoFocusRingLoose()
        .accessibilityValue(open ? "Open" : "Closed")
    }
}

private struct TaskMenu: View {
    let task: String
    let store: SessionsStore

    var body: some View {
        Button("Rename…") {
            guard let title = Collections.askText(
                title: "Rename this work",
                informative: "Its briefs stay together. The next one that belongs here joins them.",
                value: store.title(ofTask: task),
                placeholder: "What the work is",
                confirm: "Rename"
            ), !title.isEmpty else { return }
            Tasks.name(task, title)
            Task { await store.load(root: store.root) }
        }
        Button("Open the task note") {
            let note = Tasks.notePath(for: task)
            if FileManager.default.fileExists(atPath: note.path) { NSWorkspace.shared.open(note) }
        }
    }
}

/// Every verb a recorded session has, in one place, so the board card and the
/// dashboard row cannot drift apart.
struct SessionMenu: View {
    let item: SessionsStore.Item
    let store: SessionsStore

    var body: some View {
        Button("Open brief") { MainNav.shared.open(brief: item.id) }
        Button("Copy the brief") {
            Task {
                guard let prompt = await store.freshPrompt(sessionDir: item.dir) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt.text, forType: .string)
            }
        }
        Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: item.dir)) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.dir)])
        }
        Divider()
        Menu("Move to project") {
            Button("Unsorted") { store.move(item, to: nil) }
            if !store.collections.isEmpty { Divider() }
            ForEach(store.collections) { collection in
                Button {
                    store.move(item, to: collection.id)
                } label: {
                    Text(collection.id == item.collection ? "✓ \(collection.name)" : "   \(collection.name)")
                }
            }
            Divider()
            Button("New project…") { newCollection() }
        }
        Menu("Move to task") {
            // The brief that started its task is already on its own task:
            // moving it there would change nothing — unless it is in odds
            // and ends, which this takes it out of.
            // Its own id taken by briefs moved into it since: "new" would
            // join them, so that is chosen from the list instead.
            let own = Tasks.own(item.id)
            let taken = (item.odds || item.task != own) && store.hasOthers(inTask: own, besides: item.id)
            Button("Start a new task") { store.move(item, toTask: own) }
                .disabled(taken || (item.task == own && !item.odds))
                .tip(taken ? SessionsStore.ownTaskTakenHelp : "")
            let others = store.recentTasks(excluding: item.odds ? nil : item.task)
            if !others.isEmpty { Divider() }
            // The short name a tag wears ("Sitemap · 3"), not the sentence
            // the task was summarised as: a menu of sentences is unreadable.
            ForEach(others) { group in
                Button("\(store.workName(ofTask: group.id)) · \(group.items.count)") {
                    store.move(item, toTask: group.id)
                }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete() }
    }

    private func newCollection() {
        guard let made = Collections.ask(
            prefill: item.repo,
            informative: "Briefs about the same project, kept together."
        ) else { return }
        store.move(item, to: made.id)
        Task { await store.load(root: store.root) }
    }

    /// ASKED, ALWAYS. The screenshots are the only copy, and "Delete all past
    /// sessions" in Settings already sets the house rule that removing
    /// somebody's captures is a question, not a click.
    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete this session?"
        alert.informativeText = "\(item.title)\n\nMoves the brief and its "
            + "\(item.crops.count) screenshot\(item.crops.count == 1 ? "" : "s") to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(item)
    }
}

/// What can be done to a collection, from the chip that names it. Renaming
/// and describing are the two things that change how the classifier reads it;
/// deleting forgets the folder, never the briefs.
private struct CollectionMenu: View {
    let collection: Collection
    let store: SessionsStore

    var body: some View {
        Button("Describe…") {
            guard let hint = Collections.askText(
                title: "What is \(collection.name)?",
                informative: "One line on what it covers. Deiko reads it when it works out where a new brief belongs.",
                value: collection.hint,
                placeholder: "the mobile app, not the website",
                confirm: "Save"
            ) else { return }
            Collections.describe(id: collection.id, hint: hint)
            reload()
        }
        Button("Rename…") {
            guard let name = Collections.askText(
                title: "Rename \(collection.name)",
                informative: "Briefs stay where they are.",
                value: collection.name,
                placeholder: "Project name",
                confirm: "Rename"
            ), !name.isEmpty else { return }
            Collections.rename(id: collection.id, to: name)
            reload()
        }
        Divider()
        Button("Delete project…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Delete the \(collection.name) project?"
            alert.informativeText = "Its \(store.count(of: collection.id)) brief"
                + "\(store.count(of: collection.id) == 1 ? "" : "s") stay on the board, unsorted. "
                + "No session is deleted."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Collections.delete(id: collection.id)
            reload()
        }
    }

    private func reload() {
        Task { await store.load(root: store.root) }
    }
}

private struct SessionRow: View {
    let item: SessionsStore.Item
    let store: SessionsStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(item.line == nil ? DeikoStyle.ink2 : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(BoardCard.stamp(item.date))
                    if !item.crops.isEmpty {
                        Text("·"); Text("\(item.crops.count) crop\(item.crops.count == 1 ? "" : "s")")
                    }
                    if let repo = item.repo { Text("·"); Text(repo) }
                }
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
            }
            Spacer()
            // `SessionMenu`'s own note says the board card and this row must
            // not drift apart. A lone "Open folder" here against a full menu
            // there was exactly that drift: the same object, two different
            // ideas of what you can do to it.
            Menu {
                SessionMenu(item: item, store: store)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(DeikoStyle.ink2)
            .tip("Copy, open, file or delete this brief")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { MainNav.shared.open(brief: item.id) }
        .tip("Click to open this brief")
        .contextMenu { SessionMenu(item: item, store: store) }
    }
}

// ── Shared pane furniture ───────────────────────────────────────────────────

/// Every pane opens the same way: a title, a line under it, and room. The
/// window has no toolbar, so this IS the header — and being one view rather
/// than four means a new section cannot invent its own.
struct PaneScroll<Content: View, Trailing: View>: View {
    let title: String
    let lede: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        title: String, lede: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.lede = lede
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: title, lede: lede) { trailing }
                content
            }
            .padding(.horizontal, 26)
            // Same reason as the sidebar's: there is no title bar to sit under,
            // so the pane has to leave the room one would have taken.
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The title block every pane opens with. `PaneScroll` scrolls it away with
/// the content; a pane whose chrome must stay put uses it directly, above a
/// scroll view of its own.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let lede: String
    @ViewBuilder var trailing: Trailing

    init(title: String, lede: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.lede = lede
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).deikoTitle(24)
                Text(lede)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeikoStyle.ink2)
            }
            Spacer()
            trailing
        }
        .padding(.bottom, 2)
    }
}

/// An empty state is an invitation, so it says what to do next and never
/// apologises for having nothing in it.
struct EmptyPane: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).deikoTitle(16)
            Text(line)
                .font(.system(size: 12.5))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DeikoStyle.wall, in: RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
    }
}
