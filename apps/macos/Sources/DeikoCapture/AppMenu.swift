import AppKit

/// The main menu. AppKit routes ⌘C/⌘V/⌘A/⌘M/⌘W through its key equivalents, so it is installed
/// once at launch even though it only shows while a window makes Deiko a regular app.
@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Deiko")
        app.addItem(withTitle: "About Deiko", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        // Nil target: the app delegate (`MenuBar`) answers it through the responder chain.
        app.addItem(withTitle: "Settings…", action: #selector(MenuBar.showSettings(_:)), keyEquivalent: ",")
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

/// Keeps Deiko in the Dock while a real window is open. A count, not a flag, so closing
/// one window never strands the other.
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
    /// Compact unified title bar. macOS 26 rounds window corners by title-bar height; this
    /// one's 40pt stays clear of content laid out 44pt down.
    func useRoundedTitleBar(_ id: String) {
        toolbar = NSToolbar(identifier: id)
        toolbarStyle = .unifiedCompact
        titlebarSeparatorStyle = .none
    }
}
