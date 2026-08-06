import AppKit
import FoveaHandoff

// ─────────────────────────────────────────────────────────────────────────────
// THE HANDOFF — paste the developer's prompt into the window the orb landed on
//
// Everything decided lives in `FoveaHandoff`; this file is the plumbing that
// cannot be tested: reading the window list, activating an app, synthesizing a
// paste. It should hold no judgement calls beyond the ones documented inline.
//
// If the paste or the Return misses, `prompt.txt` is still on disk beside the
// session and the orb says where. That is the fallback, and it is the reason
// nothing here reports partial success.
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

    /// Where a handoff narrates itself. `OrbController` points this at the
    /// app's log on first use.
    ///
    /// Not optional decoration: the first live fling failed with nothing on
    /// screen and nothing on disk, because the only trace hook lived in a test
    /// subcommand and the field run was therefore undiagnosable. A field run
    /// must never be quieter than a harness.
    static var trace: ((String) -> Void)?

    private static func note(_ message: String) { trace?(message) }

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

    /// Activate the target and paste the developer's prompt into it.
    ///
    /// Throws rather than reporting partial success: every failure here has the
    /// same remedy — the orb points at `prompt.txt` — and the same severity.
    /// Destinations that cannot open a local file path, so the crops have to
    /// travel as bytes.
    ///
    /// A browser chat runs the model somewhere else entirely. Handing it
    /// `/Users/…/h01-r008.png` is handing it a string it cannot follow — and
    /// the failure is the bad kind, because a model will often carry on as if
    /// it had looked rather than say it could not.
    ///
    /// A LIST, with all the staleness a list implies — but the asymmetry is
    /// what makes it safe here, and it is the opposite of the asymmetry that
    /// made the old terminal list dangerous. A browser missing from this set
    /// falls back to pasting paths, which is exactly what every destination got
    /// before this existed: no worse than yesterday. Guessing the other way is
    /// what would hurt, so nothing is added on a hunch.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
    ]

    static func needsAttachedImages(_ target: HandoffTarget) -> Bool {
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        return browserBundleIDs.contains(bundleID ?? "")
    }

    static func deliver(
        to target: HandoffTarget, text: String, images: [String] = []
    ) async throws {
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

        // IMAGES FIRST, TEXT LAST. A chat composer puts an attachment above the
        // message being written, so this is the order that produces "here are
        // two screenshots, and here is what I was saying" rather than the
        // reverse — and `attachedText` numbers the images in exactly this
        // order, so the order is load-bearing, not cosmetic.
        for (index, path) in images.enumerated() {
            note("pasting image \(index + 1)/\(images.count): \((path as NSString).lastPathComponent)")
            try pasteImage(at: path)
            // Longer than the text's beat, and for a different reason. A
            // browser composer does not merely accept an image, it UPLOADS it,
            // and a second paste landing mid-upload is how one of them goes
            // missing. This is a guess at a safe margin rather than a measured
            // figure — the fix if an image is dropped is to raise it.
            try await Task.sleep(for: .milliseconds(900))
        }

        note("pasting \(text.count) characters into \(target.appName)")
        try paste(text)

        // Let the destination process the paste before anything else. A large
        // multi-line paste needs a beat to land in the input before a Return
        // arrives, and 250ms was already measured as sufficient for the
        // slash-command this replaced (`mddocs/spikes/T4.6-handoff-keystroke.md`).
        try await Task.sleep(for: .milliseconds(250))

        // PASTE, WAIT, ONE RETURN. Four other sequences were tried against real
        // hosts: two Returns, Escape-then-Return, a pasted trailing newline, and
        // paste-only. This is the one that submits.
        //
        // MULTI-LINE PASTE RELIES ON BRACKETED PASTE. A single-line command
        // could not be split; this text can. A host that does not honour
        // bracketed paste will submit at each newline, which looks like the
        // prompt fragmenting itself — several messages arriving instead of
        // one, each a partial line. Claude Code's TUI and VS Code's chat input
        // are BOTH EXPECTED to honour it, but that is an assumption, not a
        // measurement: the live check against real hosts is a field
        // verification step, not something this file can run on its own. If
        // the fragmenting happens, this is where to look first.
        tap(keyCode: kReturn)
        note("done")
    }

    private static let kReturn: CGKeyCode = 36

    // ── Keystrokes ──────────────────────────────────────────────────────────

    /// Paste rather than per-character key events. `/` and `_` sit on
    /// different keys on different layouts, and typing them by keycode would
    /// produce the wrong characters on a non-US keyboard. Cmd+V is
    /// layout-independent, and the pasteboard is restored afterwards.
    private static func paste(_ text: String) throws {
        try pasteboardPaste(what: "command") { $0.setString(text, forType: .string) }
    }

    /// One crop, as image BYTES on the clipboard.
    ///
    /// PNG data rather than a file URL: a browser composer turns pasted image
    /// data into an attachment, which is the whole point of this path — the
    /// destination is a model that cannot reach this filesystem, so a reference
    /// of any kind is useless to it. The file URL rides along as a second
    /// flavour for destinations that prefer it; a pasteboard item may carry
    /// both, and the receiver picks.
    private static func pasteImage(at path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw HandoffError("Could not read the screenshot at \(path).")
        }
        try pasteboardPaste(what: "image") { pasteboard in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            item.setString(
                URL(fileURLWithPath: path).absoluteString, forType: .fileURL
            )
            return pasteboard.writeObjects([item])
        }
    }

    /// Save the developer's clipboard, put ours on it, Cmd+V, and schedule the
    /// restore. Shared by the text and image paths because every subtle part of
    /// it — what gets saved, which restore owns the true original, aborting
    /// before the keystroke — was hard-won and must not exist twice.
    private static func pasteboardPaste(
        what: String, write: (NSPasteboard) -> Bool
    ) throws {
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
        guard write(pasteboard) else {
            // Abort BEFORE any keystroke. The old code carried on: Cmd+V pasted
            // nothing into an emptied pasteboard and Return was posted anyway,
            // submitting whatever half-typed message was already in the input.
            restore(saved, to: pasteboard, ifStillAt: pasteboard.changeCount)
            throw HandoffError("Could not put the \(what) on the clipboard.")
        }
        let ours = pasteboard.changeCount
        note("pasteboard now holds \(what) (changeCount \(ours)); posting Cmd+V")

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
