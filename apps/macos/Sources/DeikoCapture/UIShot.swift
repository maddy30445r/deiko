import AppKit
import SwiftUI
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// deiko-capture ui-shot --out /tmp/deiko-ui [--root <dir>]
//
// Renders the app's own windows to PNGs, light and dark, so a change to the
// design system can be LOOKED AT instead of argued about. Same reason
// `ink-demo` exists: the cheapest thing that fails visibly when the drawing
// is wrong.
//
// It renders the real views with real models, not a mock of them — a preview
// that drifts from the app is worse than no preview. The models are the
// default ones, so what comes out is each window's first paint: the state a
// person actually meets. `--root` reads another board — a re-sorted copy, say
// — instead of the real one; only ever read, never written.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum UIShot {

    static func run(_ args: Args) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = args.string("out") ?? "/tmp/deiko-ui"
        titled = args.has("titled")
        let root = args.string("root") ?? Sessions.defaultRoot
        // Never read or write the real seen-markers: a shot must not use up
        // somebody's one showing of "Added to … · Undo".
        SessionsStore.seenDefaults = nil
        let store = SessionsStore.shared
        Task { await store.load(root: root) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // One filing still announcing — the newest — as the board looks the
        // first time it is opened after Deiko filed it.
        store.seen = Set(store.items.filter(\.filedByDeiko).dropFirst().map(\.id))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let look = NSAppearance(named: appearance) else { continue }
            shoot(WelcomeView(model: WelcomeModel()),
                  size: NSSize(width: 540, height: 720), look: look, to: "\(out)-welcome-\(name).png")
            // The app window, one shot per section — the sidebar is part of
            // each, which is the point: a section that only looks right on its
            // own is a section that does not belong in this window.
            for section in MainSection.allCases {
                MainNav.shared.section = section
                shoot(
                    MainWindowView(openSessionDir: nil, sessionRoot: root),
                    size: NSSize(width: 980, height: 660), look: look,
                    to: "\(out)-\(section.rawValue)-\(name).png"
                )
            }
            // Settings runs past the first paint; this is all of it.
            MainNav.shared.section = .settings
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 1500), look: look,
                to: "\(out)-settings-full-\(name).png"
            )
            // THE WHOLE BOARD, tall enough to run the timeline back past this
            // week into the months, set-aside briefs and all.
            MainNav.shared.section = .board
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 2900), look: look,
                to: "\(out)-board-full-\(name).png"
            )
            // Every day's set-aside briefs, unfolded.
            UIShotPose.unfolded = Set(BoardTimeline.sections(store.items, date: \.date, now: Date()).map(\.title))
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 2900), look: look,
                to: "\(out)-board-fold-\(name).png"
            )
            UIShotPose.unfolded = []
            // A brief held over the second card, and the board opened on the
            // biggest piece of work — neither reachable by a still first paint.
            UIShotPose.dropTarget = store.items.dropFirst().first?.id
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 660), look: look,
                to: "\(out)-board-drop-\(name).png"
            )
            UIShotPose.dropTarget = nil
            MainNav.shared.work = store.workCounts.max { $0.value < $1.value }?.key
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 1000), look: look,
                to: "\(out)-board-work-\(name).png"
            )
            // The same work with every note shown, then with its full history.
            UIShotPose.notesExpanded = true
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 1200), look: look,
                to: "\(out)-board-work-all-\(name).png"
            )
            UIShotPose.notesExpanded = false
            UIShotPose.historyOpen = true
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 1500), look: look,
                to: "\(out)-board-work-history-\(name).png"
            )
            UIShotPose.historyOpen = false
            // A work no agent has written back on yet.
            MainNav.shared.work = store.workCounts.filter { $0.value >= 2 }.keys.sorted().first { task in
                !store.items.contains { $0.task == task
                    && FileManager.default.fileExists(atPath: ($0.dir as NSString).appendingPathComponent("outcome.md")) }
            }
            shoot(
                MainWindowView(openSessionDir: nil, sessionRoot: root),
                size: NSSize(width: 980, height: 800), look: look,
                to: "\(out)-board-work-empty-\(name).png"
            )
            MainNav.shared.work = nil
            // ONE BRIEF: one that came back with notes and screenshots, one in
            // no task, one set aside, and the first with the sent brief open.
            let fileExists = { (item: SessionsStore.Item) in
                FileManager.default.fileExists(atPath: (item.dir as NSString).appendingPathComponent("outcome.md"))
            }
            let briefs: [(String, String?)] = [
                ("brief", (store.items.first { !$0.crops.isEmpty && fileExists($0) } ?? store.items.first { !$0.crops.isEmpty })?.id),
                ("brief-alone", store.items.first { !$0.setAside && (store.workCounts[$0.task] ?? 0) < 2 && !$0.crops.isEmpty }?.id),
                ("brief-scrap", store.items.first(where: \.setAside)?.id),
            ]
            for (pose, id) in briefs {
                guard let id else { continue }
                MainNav.shared.brief = id
                shoot(
                    MainWindowView(openSessionDir: nil, sessionRoot: root),
                    size: NSSize(width: 980, height: 1500), look: look,
                    to: "\(out)-board-\(pose)-\(name).png"
                )
            }
            if let first = briefs[0].1 {
                MainNav.shared.brief = first
                UIShotPose.promptOpen = true
                shoot(
                    MainWindowView(openSessionDir: nil, sessionRoot: root),
                    size: NSSize(width: 980, height: 2200), look: look,
                    to: "\(out)-board-brief-sent-\(name).png"
                )
                UIShotPose.promptOpen = false
            }
            MainNav.shared.brief = nil
            shoot(orbCard(), size: NSSize(width: 400, height: 130), look: look, to: "\(out)-orb-\(name).png")
            shoot(orbReady(), size: NSSize(width: 400, height: 190), look: look, to: "\(out)-orbready-\(name).png")
            shoot(orbReady(notice: true), size: NSSize(width: 400, height: 250), look: look,
                  to: "\(out)-orbnotice-\(name).png")
            shoot(orbSent(), size: NSSize(width: 400, height: 70), look: look, to: "\(out)-orbsent-\(name).png")
            // The expanded panel, at the size the orb gives it. The most
            // consequential screen in the app — it is the last thing anybody
            // reads before a brief leaves the Mac — and it had no capture.
            shoot(reviewPanel(), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-\(name).png")
            shoot(reviewPanel(odds: true), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-odds-\(name).png")
            shoot(reviewPanel(related: true), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-related-\(name).png")
            shoot(reviewPanel(joined: true), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-joined-\(name).png")
        }
        // The status item, at the size it is actually drawn — 1x and 2x — so a
        // mark that looks wrong in the menu bar can be looked at without
        // squinting at a 16pt corner of somebody's screen.
        for (state, image) in [
            ("ready", DeikoStyle.menuBarIcon(recording: false, blocked: false)),
            ("recording", DeikoStyle.menuBarIcon(recording: true, blocked: false)),
            ("blocked", DeikoStyle.menuBarIcon(recording: false, blocked: true)),
        ] {
            for scale in [1, 8] {
                let size = NSSize(width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(out)-menubar-\(state)-\(scale)x.png"))
            }
        }

        Emit.log("wrote \(out)-{welcome,orb,orbready,orbnotice,orbsent,review,review-odds,review-related,review-joined,dashboard,board,board-full,board-fold,board-drop,board-work,board-brief,board-brief-alone,board-brief-scrap,board-brief-sent,personas,settings,settings-full}-{light,dark}.png")
    }

    /// The collapsed card, mid-session: the state the orb spends most of its
    /// life in, and the one that carries the title line and the crop chip.
    private static func orbCard() -> some View {
        let model = ReviewModel()
        model.phase = .working("Reading what you pointed at…")
        return OrbRootView(
            model: model,
            state: OrbState(),
            actions: OrbActions(
                onPress: {}, onDrag: { _ in }, onRelease: {}, onDismiss: {},
                onExtend: {}, onSetMode: { _ in }, onOpenSettings: {},
                onDelete: {}, onSend: {}, onHeightChange: { _ in }
            )
        )
    }

    /// The card as it looks the moment before somebody throws the coin: the
    /// state that carries the verdict, the crop counts and the persona chip.
    /// `notice`: the first card an own-key user sees after sorting reached them.
    private static func orbReady(notice: Bool = false) -> some View {
        let model = ReviewModel()
        model.phase = .ready
        model.sortingNotice = notice
        model.summary = "Make the Save button use the header indigo, and give it more padding."
        model.personaName = "QA ticket"
        // Posed as a hesitant answer on purpose: "Looks like" is the wording
        // that invites the correction, and it is the one worth looking at.
        // Unfiled with "Sort briefs into tasks" off, as a brief then is —
        // `-DEIKO_SORT_BRIEFS NO` poses that without touching the setting.
        model.collections = Collections.all()
        model.context = !Credentials.sortsBriefs ? nil : SessionContext(
            collection: Collections.all().first?.id,
            // A task with more than one brief, so the card's placement line
            // reads "Carries on from" the way a joined brief's does.
            task: SessionsStore.shared.groups(of: SessionsStore.shared.items).first { $0.items.count > 1 }?.id,
            tier: "quick",
            confidence: .init(collection: 0.72, task: 0.88, tier: 0.91),
            decidedBy: "jev",
            model: "jev-1.13.0"
        )
        return OrbRootView(
            model: model,
            state: OrbState(),
            actions: OrbActions(
                onPress: {}, onDrag: { _ in }, onRelease: {}, onDismiss: {},
                onExtend: {}, onSetMode: { _ in }, onOpenSettings: {},
                onDelete: {}, onSend: {}, onHeightChange: { _ in }
            )
        )
    }

    /// The pill after a throw that went before the filing finished — the
    /// one sent state with a second line.
    private static func orbSent() -> some View {
        let model = ReviewModel()
        model.phase = .sent
        model.handedTo = "Claude Code"
        model.sentUnfiled = true
        return OrbRootView(
            model: model,
            state: OrbState(),
            actions: OrbActions(
                onPress: {}, onDrag: { _ in }, onRelease: {}, onDismiss: {},
                onExtend: {}, onSetMode: { _ in }, onOpenSettings: {},
                onDelete: {}, onSend: {}, onHeightChange: { _ in }
            )
        )
    }

    /// The review panel as somebody meets it: rendered, placed, and about to
    /// be thrown. Posed from the newest real session on this Mac so the
    /// narration, the crops and the counts are the ones the app would draw.
    /// `odds`: posed in odds and ends instead, as `classify.mjs` writes it.
    /// `related`: posed linked to an earlier task instead of unsure between a
    /// few, as `classify.mjs` writes a related-but-separate brief.
    private static func reviewPanel(odds: Bool = false, related: Bool = false, joined: Bool = false) -> some View {
        let model = ReviewModel()
        model.phase = .ready
        model.summary = "Make the Save button use the header indigo, and give it more padding."
        model.personaName = "QA ticket"
        model.collections = Collections.all()
        let items = SessionsStore.shared.items
        if let newest = items.first {
            model.digest = try? BriefPipeline.digest(sessionDir: newest.dir)
            model.narration = model.digest?.summary.narration ?? ""
        }
        // Posed unsure between two earlier tasks, so "Which one?" is in the
        // shot: the brief is a new task and the row offers the likely ones.
        let others = SessionsStore.shared.groups(of: items).map(\.id).filter { $0 != items.first?.task }
        model.context = odds ? SessionContext(decidedBy: "local", pile: "odds") : joined ? SessionContext(
            collection: Collections.all().first?.id,
            // Joined by Deiko on its own, so "Same work?" asks. A task with
            // more than one brief, so the row reads "carries on from".
            task: SessionsStore.shared.groups(of: items).first { $0.items.count > 1 }?.id,
            tier: "quick",
            confidence: .init(collection: 0.9, task: 0.8, tier: 0.9),
            decidedBy: "jev",
            model: "jev-1.13.0"
        ) : related ? SessionContext(
            collection: Collections.all().first?.id,
            // No `task`: still its own, unjoined task — the posed model never
            // carries a `sessionDir` (no pose here does; see the type comment
            // above), so `ownTask` reads nil and a non-nil id here would
            // never equal it, hiding the "Related to" row the shot exists to
            // check. Nil is also the truer shape: `classify.mjs` only writes
            // `task` for a join, and this poses the OTHER v3 case — a related
            // link on a brief that stayed its own task.
            tier: "medium",
            confidence: .init(collection: 0.9, task: nil, tier: 0.7),
            decidedBy: "jev",
            model: "jev-1.13.0",
            related: others.first
        ) : !Credentials.sortsBriefs ? nil : SessionContext(
            collection: Collections.all().first?.id,
            // Three, the most `classify.mjs` leaves: the widest the row gets.
            candidates: Array(others.prefix(3)),
            tier: "quick",
            confidence: .init(collection: 0.72, task: 0.4, tier: 0.91),
            decidedBy: "jev",
            model: "jev-1.13.0"
        )
        return ReviewView(model: model, onExtend: {}, onCollapse: {}, onDelete: {}, sendTo: "Claude Code")
            .frame(width: 620, height: 640)
            .background(DeikoStyle.card)
    }

    /// A real window, briefly on screen. SwiftUI lays out against a window and
    /// a run loop; rendering a detached hosting view gives back an empty
    /// bitmap, which looks exactly like a broken design and is not one.
    /// `--titled`: build the shot window the way `MainWindowController` builds
    /// the real one — titled, full-size content, transparent hidden title bar
    /// — instead of borderless. The two are not the same picture: the real
    /// style hands the content a title-bar safe area, and a design reviewed
    /// only in the borderless shot never saw it.
    static var titled = false

    private static func shoot<V: View>(_ view: V, size: NSSize, look: NSAppearance, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ShotWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false
        )
        if titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.appearance = look
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        // OFF SCREEN AND NEVER ACTIVATED: a run of shots used to throw a
        // window in front of whatever somebody was working in, forty times.
        // `ShotWindow` still answers "key", because macOS draws accented
        // controls — a tinted progress bar, a focus ring — in grey in a
        // window that is not, and the shot would report a bug that is not
        // there. `cacheDisplay` draws the view itself, wherever it sits.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}

/// A window that draws as the key window without being made one, and stays
/// where it is put — off every screen (see `UIShot.shoot`).
private final class ShotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// States `ui-shot` poses that no click can reach in a still picture: the
/// board opened on one piece of work, a card with a brief held over it, and
/// the set-aside folds opened.
@MainActor
enum UIShotPose {
    static var dropTarget: String?
    /// The brief view with "The brief as your agent got it" open.
    static var promptOpen = false
    /// Days whose set-aside briefs are shown, by heading.
    static var unfolded: Set<String> = []
    /// The work panel with every note shown, and with its full history open.
    static var notesExpanded = false
    static var historyOpen = false
}
