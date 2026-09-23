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

    /// A real window, briefly on screen. SwiftUI lays out against a window and
    /// a run loop; rendering a detached hosting view gives back an empty
    /// bitmap, which looks exactly like a broken design and is not one.
    private static func shoot<V: View>(_ view: V, size: NSSize, look: NSAppearance, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
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
