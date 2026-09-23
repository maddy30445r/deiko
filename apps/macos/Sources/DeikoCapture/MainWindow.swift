import AppKit
import SwiftUI
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
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    /// Handed in rather than read from a global: "Delete all past sessions"
    /// must be able to spare the session being recorded right now, and this
    /// window has no recorder of its own.
    var openSessionDir: (() -> String?)?
    var sessionRoot: String = Sessions.defaultRoot

    func present(_ section: MainSection = .dashboard) {
        MainNav.shared.section = section
        // Every time, not only on the first open.
        Task { await SessionsStore.shared.load(root: sessionRoot) }
        if let window {
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
        .help("\(section.title) (⌘\(String(describing: shortcut.character)))")
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
            if let line, line.count > 12 { return line }
            if let app = apps.first { return "Something in \(app)" }
            return crops.isEmpty ? "A session with nothing saved" : "\(crops.count) screenshots, no words"
        }
        let crops: [String]
        let apps: [String]
        let repo: String?
        /// Where this brief sits in what Deiko remembers — see `Context.swift`.
        /// All three come from the same detached pass that reads the manifest,
        /// so the memory costs the board one more small decode per session.
        let collection: String?
        let continues: String?
        /// The first line an agent wrote back about what it did, if one did.
        let outcome: String?
    }

    @Published private(set) var items: [Item] = []
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

    /// File a brief somewhere else, from the board rather than the card.
    /// Marked as the developer's decision, which the classifier never
    /// overwrites.
    func move(_ item: Item, to collection: String?) {
        var context = SessionContext.read(sessionDir: item.dir) ?? SessionContext()
        context.collection = collection
        context.decidedBy = "you"
        try? context.write(sessionDir: item.dir)
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let was = item.collection { counts[was, default: 1] -= 1 } else { unsortedCount -= 1 }
        if let now = collection { counts[now, default: 0] += 1 } else { unsortedCount += 1 }
        items[index] = Item(
            id: item.id, dir: item.dir, date: item.date, line: item.line,
            crops: item.crops, apps: item.apps, repo: item.repo,
            collection: collection, continues: item.continues, outcome: item.outcome
        )
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

    /// Forget one session, on disk and here. The confirmation lives with the
    /// caller — this is the part that cannot be undone.
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
        // Manifests are small but there can be hundreds; read them off the main
        // actor so opening the window never stutters.
        let read = await Task.detached(priority: .userInitiated) { () -> [Item] in
            names.compactMap { name in
                let dir = (root as NSString).appendingPathComponent(name)
                guard let date = Sessions.stamp(name) else { return nil }
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
                ))?
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(
                        of: "^#+\\s*", with: "", options: .regularExpression) }
                    .first { !$0.isEmpty }
                return Item(
                    id: name,
                    dir: dir,
                    date: date,
                    line: (narration?.isEmpty == false) ? narration : nil,
                    crops: digest?.cropPaths ?? [],
                    apps: digest?.summary.apps ?? [],
                    repo: digest?.summary.repoHints.first,
                    collection: context?.collection,
                    continues: context?.continues,
                    outcome: outcome
                )
            }
        }.value
        items = read
        collections = Collections.all()
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
    }

    /// The same text the fling would paste. Read from disk, because the review
    /// window may have rewritten it since.
    private func copy(_ item: SessionsStore.Item) {
        guard let prompt = try? BriefPipeline.prompt(sessionDir: item.dir) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.text, forType: .string)
        copied = item.id
        Task {
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
    @State private var query = ""
    @State private var filter: Filter = .all
    @FocusState private var searching: Bool

    /// Which slice of the board is on screen. Unsorted is its own answer
    /// rather than an empty collection: "nothing filed this yet" is a thing
    /// somebody looks for on purpose.
    private enum Filter: Equatable {
        case all, unsorted, collection(String)
    }

    private var shown: [SessionsStore.Item] {
        let inFilter = sessions.items.filter { item in
            switch filter {
            case .all: return true
            case .unsorted: return item.collection == nil
            case .collection(let id): return item.collection == id
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return inFilter }
        return inFilter.filter {
            ($0.line ?? "").lowercased().contains(q)
                || ($0.repo ?? "").lowercased().contains(q)
                || $0.apps.contains { $0.lowercased().contains(q) }
        }
    }

    /// The chips, in the order they are useful: everything, then the projects
    /// with the most in them, then whatever has not been filed.
    @ViewBuilder private var chips: some View {
        if !sessions.collections.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip("All", count: sessions.items.count, filter: .all)
                    ForEach(sessions.collections.sorted { sessions.count(of: $0.id) > sessions.count(of: $1.id) }) { collection in
                        chip(collection.name, count: sessions.count(of: collection.id),
                             filter: .collection(collection.id))
                            .contextMenu { CollectionMenu(collection: collection, store: sessions) }
                    }
                    if sessions.unsortedCount > 0 {
                        chip("Unsorted", count: sessions.unsortedCount, filter: .unsorted)
                    }
                }
                .padding(.vertical, 1)
            }
            .padding(.bottom, 2)
        }
    }

    private func chip(_ name: String, count: Int, filter target: Filter) -> some View {
        ChipButton(name: name, count: count, on: filter == target) {
            filter = filter == target ? .all : target
        }
    }

    var body: some View {
        PaneScroll(title: "Board", lede: "Every brief you have thrown, still on this Mac.", trailing: {
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
        }) {
            chips
            if shown.isEmpty {
                EmptyPane(
                    title: sessions.items.isEmpty ? "The board is empty" : "Nothing here yet",
                    line: sessions.items.isEmpty
                        ? "Briefs pin themselves here as you record them. Nothing is uploaded — this is the folder in your Documents."
                        : "Try another collection, an app name, or a word you said."
                )
            } else {
                // `.top`, because the default is `.center`: cards of unequal
                // height were being centred in their row, which staggered the
                // top edge and read as a rendering fault rather than masonry.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(shown) { item in BoardCard(item: item, store: sessions) }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// One filter chip. The selected one is the wash chip the system already has
/// (DESIGN.md §Chips); the rest are hairline outlines, so the row reads as one
/// thing with one answer chosen rather than as a bank of buttons.
private struct ChipButton: View {
    let name: String
    let count: Int
    let on: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Text(name).font(.system(size: 11, weight: .medium))
                // The count is the quiet half of the chip in both states —
                // it is the reason to click, never the label.
                Text("\(count)")
                    .font(.system(size: 11))
                    .opacity(0.65)
            }
            .foregroundStyle(on ? DeikoStyle.mark : DeikoStyle.ink2)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background {
                if on {
                    Capsule().fill(DeikoStyle.accentSoft)
                } else {
                    Capsule()
                        .fill(hovering ? DeikoStyle.accentSoft.opacity(0.5) : .clear)
                        .overlay(Capsule().strokeBorder(DeikoStyle.hairline, lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .deikoFocusRing(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct BoardCard: View {
    let item: SessionsStore.Item
    let store: SessionsStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let first = item.crops.first {
                CropThumbnail(path: first, height: 74)
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
                .help("Copy, open, file or delete this brief")
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
            // NOT AN ARROW. A glyph standing in for a word is an icon system
            // this app does not have; the sentence says it and reads aloud.
            if let continues = item.continues,
               let earlier = store.items.first(where: { $0.id == continues }) {
                (Text("Carries on from ").font(.system(size: 11))
                    + Text(earlier.title).font(.system(size: 11, weight: .medium)))
                    .foregroundStyle(DeikoStyle.ink2)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Self.stamp(item.date))
                if !item.crops.isEmpty {
                    Text("·")
                    Text("\(item.crops.count) crop\(item.crops.count == 1 ? "" : "s")")
                }
                if let repo = item.repo { Text("·"); Text(repo) }
            }
            .font(.system(size: 11))
            .foregroundStyle(DeikoStyle.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                .fill(DeikoStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .strokeBorder(hovering ? DeikoStyle.accent : DeikoStyle.hairline, lineWidth: 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: hovering ? 16 : 10, x: 0, y: hovering ? 9 : 5)
        )
        .offset(y: hovering ? -1 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: item.dir)) }
        // Kept beside the button: somebody who already reaches for a
        // right-click should not have to learn a new way to do it.
        .contextMenu { SessionMenu(item: item, store: store) }
        .help("Double-click to open this session's folder · ⋯ for everything else")
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

/// Every verb a recorded session has, in one place, so the board card and the
/// dashboard row cannot drift apart.
struct SessionMenu: View {
    let item: SessionsStore.Item
    let store: SessionsStore

    var body: some View {
        Button("Copy the brief") {
            guard let prompt = try? BriefPipeline.prompt(sessionDir: item.dir) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt.text, forType: .string)
        }
        Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: item.dir)) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.dir)])
        }
        Divider()
        Menu("Move to") {
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
            Button("New collection…") { newCollection() }
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
        alert.informativeText = "\(item.title)\n\nRemoves the brief and its "
            + "\(item.crops.count) screenshot\(item.crops.count == 1 ? "" : "s"). This cannot be undone."
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
                informative: "One line. Deiko reads it when it decides where a new brief belongs — \"the Cloudflare site, not the app\".",
                value: collection.hint,
                placeholder: "the Cloudflare site, not the app",
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
        Button("Delete collection…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Delete the \(collection.name) collection?"
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
            .help("Copy, open, file or delete this brief")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
