import AppKit
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE HANDOFF — put the brief's slash command into the window the orb landed on
//
// Everything decided lives in `FoveaHandoff`; this file is the plumbing that
// cannot be tested: reading the window list, activating an app, synthesizing a
// paste. It should hold no judgement calls beyond the ones documented inline.
//
// The order is send FIRST, keystroke SECOND, always. If the keystroke misses —
// wrong window focused, an editor that swallowed the paste — the brief is
// already pending in the outbox, so the fallback is exactly the old flow: type
// the command yourself. The reverse order could have an agent fetch a brief
// that is not there yet.
//
// This does not violate "nothing leaves until Good to go" — the fling IS the
// approval, a deliberate gesture at a named target. What it must never become
// is automatic on session end.
// ─────────────────────────────────────────────────────────────────────────────

/// A target plus where its window sits, so the orb can outline what the user
/// is about to commit to. The bounds are CG-global (top-left origin).
struct ResolvedTarget {
    let target: HandoffTarget
    let windowBounds: CGRect
}

@MainActor
enum Handoff {

    /// The slash command that pulls the pending brief — **host-dependent, and
    /// that is the whole story of why the first live handoff did nothing.**
    ///
    /// The CLI/TUI names MCP prompts `/mcp__<server>__<prompt>`; the VS Code
    /// extension names the same prompt `/<server>:<prompt>`. Pasting the wrong
    /// form leaves an *unresolved* command in the input, and Claude Code will
    /// not submit one — which looks exactly like a failed Return keystroke, and
    /// sent this investigation chasing TCC grants, event sources and
    /// autocomplete popups before the developer recognised the name.
    ///
    /// Overridden wholesale by `handoff-test --command`; nil otherwise.
    static var commandOverride: String?

    /// ASK a connected client; only guess when nobody has been connected.
    ///
    /// The guess is the thing this replaces. It read the target window's bundle
    /// id against a hand-kept list of terminal emulators — a list that is stale
    /// the day a new terminal ships, and whose wrong answers are SILENT, because
    /// Claude Code will not submit an unresolved slash command and the text just
    /// sits in the input looking like a dropped keystroke. That cost an hour
    /// once (`mddocs/spikes/T4.6-handoff-keystroke.md`).
    ///
    /// A client the user explicitly connected can simply be asked. The fallback
    /// stays for an unconnected target, where guessing beats refusing.
    static func command(for target: HandoffTarget) -> String {
        if let commandOverride { return commandOverride }
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        if let connector = Connectors.matching(bundleID: bundleID) {
            return connector.commandForm
        }
        // VERIFIED for the VS Code extension on 2026-07-31; the CLI form is
        // what the repo has always documented but is unverified since.
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "io.alacritty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "org.tabby", "co.zeit.hyper",
        ]
        return terminals.contains(bundleID ?? "") ? "/mcp__fovea__brief" : "/fovea:brief"
    }

    /// Diagnostic tap for `handoff-test`. Nil in the app — the shipped path
    /// stays silent — but the test subcommand hangs a logger here so the SAME
    /// code that failed in the field can narrate itself. A separate
    /// instrumented copy of `deliver` would be the copy that works.
    static var trace: ((String) -> Void)?

    private static func note(_ message: String) { trace?(message) }

    /// How to make the destination ACT on the command once it is in the input.
    ///
    /// This is a real variable, not a knob: measured behaviour differs by host.
    /// A synthetic Return reaches VS Code (it inserts a newline in an editor
    /// pane) but does not submit the Claude Code chat input after a paste —
    /// the slash-command autocomplete is open and eats it. `handoff-test
    /// --seq` exists to find which sequence wins where.
    enum Submit: String {
        /// Paste, then one Return. Works in TextEdit; does not submit VS Code.
        case returnKey = "return"
        /// Paste, then two Returns — the first dismisses/accepts the
        /// autocomplete, the second submits.
        case returnTwice = "return-twice"
        /// Paste, Escape to dismiss the autocomplete, then Return.
        case escapeReturn = "escape-return"
        /// Paste text that already ends in a newline, and post nothing. Some
        /// inputs treat a pasted newline as a submit.
        case pastedNewline = "pasted-newline"
        /// Paste only — leave the command typed for the developer to send.
        /// The honest fallback if nothing else works.
        case none = "none"
    }

    /// The default sequence. Set from the spike's findings.
    static var submit: Submit = .returnKey

    /// The app owning the frontmost window under a point, for the orb to name
    /// while aiming.
    ///
    /// The window list rather than an AX hit-test, deliberately: this runs on
    /// every mouse-move of a fling, and `AXProbe`'s point probe can sleep 300ms
    /// poking Electron apps. The question here is only "whose window is this" —
    /// the window list answers it in microseconds with no accessibility calls.
    static func targetUnder(point: CGPoint, excluding orbWindow: NSWindow?) -> ResolvedTarget? {
        // CGWindowList coordinates are CG global (top-left origin), same space
        // as `CGEvent.location` — no flip needed.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let orbNumber = orbWindow.map { CGWindowID($0.windowNumber) }

        for info in windows {
            // Layer 0 is normal windows. Anything above is overlays, menus, and
            // Fovea's own surfaces; anything below is desktop furniture.
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            guard rect.contains(point) else { continue }
            if let orbNumber, (info[kCGWindowNumber as String] as? CGWindowID) == orbNumber {
                continue
            }
            let pid = (info[kCGWindowOwnerPID as String] as? Int32)
            let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                ?? info[kCGWindowOwnerName as String] as? String
            // The FIRST window containing the point decides — the list is
            // front-to-back, so a covered window never becomes the target. If
            // that front window refuses to resolve (it is Fovea's, or
            // nameless), the fling is aiming at nothing, not at whatever shows
            // through underneath.
            return HandoffTarget.resolve(
                pid: pid, appName: name, ownPid: ProcessInfo.processInfo.processIdentifier
            ).map { ResolvedTarget(target: $0, windowBounds: rect) }
        }
        return nil
    }

    /// Activate the target and type the slash command into it.
    ///
    /// Throws rather than reporting partial success: the caller has already
    /// sent the brief, so every failure here has the same remedy — the orb says
    /// "type the command yourself" — and the same severity.
    static func deliver(to target: HandoffTarget) async throws {
        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            throw HandoffError("\(target.appName) is no longer running.")
        }
        note("activating \(target.appName) (pid \(target.pid)); isActive=\(app.isActive)")
        app.activate()

        // Give the window server time to move focus. Polling `isActive` rather
        // than sleeping a fixed amount: activation is usually ~50ms but can
        // stall behind a space switch, and a paste into the old window is the
        // worst outcome this function can produce.
        var polls = 0
        for _ in 0..<40 where !app.isActive {
            polls += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        note("activation settled after \(polls * 50)ms; isActive=\(app.isActive)")
        guard app.isActive else {
            throw HandoffError("Could not bring \(target.appName) forward.")
        }

        // A moment more for the app to route key focus to its front window —
        // `isActive` says the app owns the menu bar, not that its text field
        // is first responder yet.
        try await Task.sleep(for: .milliseconds(150))

        // Click where the fling was RELEASED, so focus is the widget the user
        // aimed at — not whatever had it last. Activation alone restores the
        // app's previous focus, which during the first live fling was some
        // widget other than the chat input: the paste went to VS Code and
        // landed nowhere visible. The click is the half of drag-and-drop that
        // a real drop performs and a fling otherwise skips.
        if let drop = target.dropPoint {
            let point = CGPoint(x: drop.x, y: drop.y)

            // Re-resolve the pixel before clicking. Up to 2.15s passes between
            // the release and this line, and the window under it can change:
            // a dialog dismisses, a panel collapses, a Space reflows. Without
            // this the click can land on a DIFFERENT app, which then takes
            // focus and receives the paste and the Return — while the orb had
            // named the original. `HandoffTarget` calls that name "the safety
            // property"; this is what keeps it true all the way to the click.
            let now = targetUnder(point: point, excluding: nil)
            guard let now, now.target.pid == target.pid else {
                throw HandoffError(
                    "\(target.appName) is no longer under the point you dropped on"
                        + (now.map { " (\($0.target.appName) is)" } ?? "")
                        + "."
                )
            }
            note("clicking drop point (\(Int(drop.x)), \(Int(drop.y))) — still \(target.appName)")
            guard click(at: point) else {
                throw HandoffError("Could not synthesize the click at the drop point.")
            }
            // Let the click settle — a web view (VS Code's chat) moves focus on
            // the mouse-up, and pasting before that lands in the old widget.
            try await Task.sleep(for: .milliseconds(150))
        }

        let strategy = Handoff.submit
        let command = Handoff.command(for: target)
        note("command for \(target.appName): \(command)")
        try paste(strategy == .pastedNewline ? command + "\n" : command)

        // Let the destination process the paste before anything else. Claude
        // Code's input needs a beat to take the text and settle its
        // slash-command autocomplete; a key in the same instant lands on the
        // wrong state.
        try await Task.sleep(for: .milliseconds(250))

        note("submit strategy: \(strategy.rawValue)")
        switch strategy {
        case .none, .pastedNewline:
            break
        case .returnKey:
            tap(keyCode: kReturn)
        case .returnTwice:
            tap(keyCode: kReturn)
            try await Task.sleep(for: .milliseconds(200))
            tap(keyCode: kReturn)
        case .escapeReturn:
            tap(keyCode: kEscape)
            try await Task.sleep(for: .milliseconds(150))
            tap(keyCode: kReturn)
        }
        note("done")
    }

    private static let kReturn: CGKeyCode = 36
    private static let kEscape: CGKeyCode = 53

    // ── Keystrokes ──────────────────────────────────────────────────────────

    /// Paste rather than per-character key events. `/` and `_` sit on
    /// different keys on different layouts, and typing them by keycode would
    /// produce the wrong characters on a non-US keyboard. Cmd+V is
    /// layout-independent, and the pasteboard is restored afterwards.
    private static func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general

        // EVERY representation, not just the string. `clearContents()` destroys
        // whatever was there regardless of what we bothered to read, so saving
        // only `.string` meant an image or a file promise was wiped with nothing
        // kept to put back — and, because the restore was skipped when there was
        // no string, wiped *permanently*. Reading only the plain-text flavour
        // also silently downgraded copied rich text.
        let saved = pendingRestore?.items ?? pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        // A restore already in flight owns the TRUE original. Reading the
        // pasteboard again here would "save" our own command from the previous
        // paste and hand that back as the user's clipboard, permanently.
        pendingRestore?.work.cancel()

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // Abort BEFORE any keystroke. The old code carried on: Cmd+V pasted
            // nothing into an emptied pasteboard and Return was posted anyway,
            // submitting whatever half-typed message was already in the input.
            restore(saved, to: pasteboard, ifStillAt: pasteboard.changeCount)
            throw HandoffError("Could not put the command on the clipboard.")
        }
        let ours = pasteboard.changeCount
        note("pasteboard now holds command (changeCount \(ours)); posting Cmd+V")

        guard tap(keyCode: 9, flags: .maskCommand) else { // 9 = V
            restore(saved, to: pasteboard, ifStillAt: ours)
            throw HandoffError("Could not synthesize the paste keystroke.")
        }
        note("Cmd+V posted")

        // Restore after the destination has read the pasteboard — ALWAYS
        // scheduled, even with nothing to put back, so the command never
        // becomes the user's clipboard by default.
        //
        // The delay is a MITIGATION, not a fix. Reading a pasteboard does not
        // bump `changeCount`, so nothing here can observe whether the paste has
        // actually happened; restoring too early hands the destination the
        // user's previous clipboard — which is how a password ends up pasted
        // into an editor. Three seconds is far past any observed paste (this
        // same function already budgets 2s for activation on a loaded Electron
        // app) at the cost of the clipboard being unavailable that long.
        let work = DispatchWorkItem {
            restore(saved, to: pasteboard, ifStillAt: ours)
            pendingRestore = nil
        }
        pendingRestore = (items: saved, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// The user's clipboard, held between a paste and its restore. Keyed on
    /// nothing — there is one system pasteboard, so there is one of these.
    private static var pendingRestore: (items: [[NSPasteboard.PasteboardType: Data]], work: DispatchWorkItem)?

    /// Put the user's clipboard back, but only if ours is still the thing on
    /// it. If anything else has written in the meantime — the user copied
    /// something, another tool ran — that write is newer than our save and
    /// stomping it would destroy the more recent intent.
    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard,
        ifStillAt ours: Int
    ) {
        guard pasteboard.changeCount == ours else { return }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.writeObjects(saved.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        })
    }

    /// `handoff-test --key return` only — a bare Return for probing what a
    /// submit takes when the command is already typed.
    static func pressReturnForTesting() { tap(keyCode: kReturn) }

    /// One key press-and-release at the session event tap level — the same
    /// level Fovea's own hotkey tap listens at, so the destination receives it
    /// exactly as it would a real key.
    @discardableResult
    private static func tap(keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        // A REAL event source, not nil. Cmd+V worked with nil because Electron
        // serves it from the native menu accelerator, which reads the event at
        // the app level; a plain Return has to travel into the Chromium
        // renderer, and that path drops events whose source is not a proper
        // HID-state source. Measured: paste landed in VS Code, Return did not.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        // Key-up in the same instant as key-down reads as a zero-length press.
        // Real hardware holds a key for tens of milliseconds and some input
        // layers debounce on that.
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// One left click at a CG-global point — the focus half of a drop.
    private static func click(at point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
                  mouseEventSource: source, mouseType: .leftMouseDown,
                  mouseCursorPosition: point, mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source, mouseType: .leftMouseUp,
                  mouseCursorPosition: point, mouseButton: .left
              )
        else { return false }
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}

struct HandoffError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
