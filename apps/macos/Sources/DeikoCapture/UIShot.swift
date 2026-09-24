import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// deiko-capture ui-shot --out /tmp/deiko-ui
//
// Renders the app's own windows to PNGs, light and dark, so a change to the
// design system can be LOOKED AT instead of argued about. Same reason
// `ink-demo` exists: the cheapest thing that fails visibly when the drawing
// is wrong.
//
// It renders the real views with real models, not a mock of them — a preview
// that drifts from the app is worse than no preview. The models are the
// default ones, so what comes out is each window's first paint: the state a
// person actually meets.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum UIShot {

    static func run(_ args: Args) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = args.string("out") ?? "/tmp/deiko-ui"
        titled = args.has("titled")

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
                    MainWindowView(openSessionDir: nil, sessionRoot: Sessions.defaultRoot),
                    size: NSSize(width: 980, height: 660), look: look,
                    to: "\(out)-\(section.rawValue)-\(name).png"
                )
            }
            shoot(orbCard(), size: NSSize(width: 400, height: 130), look: look, to: "\(out)-orb-\(name).png")
            shoot(orbReady(), size: NSSize(width: 400, height: 190), look: look, to: "\(out)-orbready-\(name).png")
            shoot(orbSent(), size: NSSize(width: 400, height: 70), look: look, to: "\(out)-orbsent-\(name).png")
            // The expanded panel, at the size the orb gives it. The most
            // consequential screen in the app — it is the last thing anybody
            // reads before a brief leaves the Mac — and it had no capture.
            shoot(reviewPanel(), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-\(name).png")
            shoot(reviewPanel(odds: true), size: NSSize(width: 620, height: 640), look: look,
                  to: "\(out)-review-odds-\(name).png")
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

        Emit.log("wrote \(out)-{welcome,orb,dashboard,board,personas,settings}-{light,dark}.png")
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
                onDelete: {}, onHeightChange: { _ in }
            )
        )
    }

    /// The card as it looks the moment before somebody throws the coin: the
    /// state that carries the verdict, the crop counts and the persona chip.
    private static func orbReady() -> some View {
        let model = ReviewModel()
        model.phase = .ready
        model.summary = "Make the Save button use the header indigo, and give it more padding."
        model.personaName = "QA ticket"
        // Posed as a hesitant answer on purpose: "Looks like" is the wording
        // that invites the correction, and it is the one worth looking at.
        model.collections = Collections.all()
        model.context = SessionContext(
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
                onDelete: {}, onHeightChange: { _ in }
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
                onDelete: {}, onHeightChange: { _ in }
            )
        )
    }

    /// The review panel as somebody meets it: rendered, placed, and about to
    /// be thrown. Posed from the newest real session on this Mac so the
    /// narration, the crops and the counts are the ones the app would draw.
    /// `odds`: posed in odds and ends instead, as `classify.mjs` writes it.
    private static func reviewPanel(odds: Bool = false) -> some View {
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
        // Posed unsure between two earlier tasks, so "Carries on from which?"
        // is in the shot: the brief is a new task and the row offers the
        // likely ones.
        let others = SessionsStore.shared.groups(of: items).map(\.id).filter { $0 != items.first?.task }
        model.context = odds ? SessionContext(decidedBy: "local", pile: "odds") : SessionContext(
            collection: Collections.all().first?.id,
            // Three, the most `classify.mjs` leaves: the widest the row gets.
            candidates: Array(others.prefix(3)),
            tier: "quick",
            confidence: .init(collection: 0.72, task: 0.4, tier: 0.91),
            decidedBy: "jev",
            model: "jev-1.13.0"
        )
        return ReviewView(model: model, onExtend: {}, onCollapse: {}, onDelete: {})
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
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
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
        // KEY, not merely visible. macOS draws accented controls — a tinted
        // progress bar, a focus ring — in grey when their window is not key,
        // so a shot of an inactive window reports a design bug that is not
        // there.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
