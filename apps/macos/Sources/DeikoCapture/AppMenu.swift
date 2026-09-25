import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// THE MENU BAR MENU — Deiko, Edit, Window
//
// Deiko lives in the menu bar and had no main menu at all. That cost more than
// a menu: AppKit routes ⌘C / ⌘V / ⌘A through the Edit menu's key equivalents,
// so a licence key could not be pasted into its field, and ⌘M / ⌘W had nothing
// to call. The menu is installed once at launch; it only shows while the board
// window has made Deiko a regular app (see `MainWindowController`), but its key
// equivalents work either way.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Deiko")
        app.addItem(withTitle: "About Deiko", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Deiko", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Deiko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(window))

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A DOCK TILE WHILE A REAL WINDOW IS OPEN. The board and the welcome window
/// each hold it while open; the last to close hands Deiko back to the menu
/// bar. A count, not a flag, so closing one never strands the other.
@MainActor
enum DockPresence {
    private static var holders = 0

    static func acquire() {
        holders += 1
        NSApp.setActivationPolicy(.regular)
    }

    static func release() {
        holders = max(0, holders - 1)
        if holders == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension NSWindow {
    /// The compact unified title bar: macOS 26 rounds a window's corners by
    /// its title bar, and this one's 40pt stays clear of content laid out
    /// 44pt down. Empty — nothing lives in it.
    func useRoundedTitleBar(_ id: String) {
        toolbar = NSToolbar(identifier: id)
        toolbarStyle = .unifiedCompact
        titlebarSeparatorStyle = .none
    }
}
