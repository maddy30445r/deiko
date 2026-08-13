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

    /// Hosts whose chat panel gets the input-strip treatment when the drop's
    /// click secured no usable focus. The same list discipline as
    /// `browserBundleIDs`: this decides HOW focus is secured, never WHETHER
    /// delivery happens, and a host missing from it just gets the generic
    /// click path — no worse than yesterday.
    ///
    /// It exists because the generic path measurably cannot reach a VS Code
    /// chat: the webview exposes no text-input roles to Accessibility in its
    /// resting state, a click on the transcript leaves DOM focus on a
    /// non-editable group, and the extension's documented Cmd+Esc chord was
    /// posted in the field and observably changed nothing. What HAS worked
    /// since the first live fling is a click that lands on the input box
    /// itself — which lives in the panel's bottom strip.
    private static let chatPanelHosts: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// The focus signatures a paste is known to reach. A concrete text role
    /// is the composer itself; AXWebArea is Chromium reporting "the webview
    /// has DOM focus" — the measured signature of every fling that worked
    /// into a chat webview (the composer holds DOM focus behind it).
    private static func focusReachesAPaste(_ role: String?) -> Bool {
        isTextEditable(role) || role == "AXWebArea"
    }

    static func deliver(
        to target: HandoffTarget, text: String, images: [String]
    ) async throws {
        // Read every crop BEFORE anything is activated, clicked or pasted.
        //
        // A session directory belongs to the developer and can be moved or
        // deleted between the render and the fling. Discovering that halfway
        // through the loop would leave images already sitting in the composer
        // with no text under them and no Return — a partial send, which this
        // file's header says it never reports. Failing here costs nothing: the
        // target has not been touched yet.
        let payloads: [(name: String, data: Data)] = try images.map { path in
            guard let data = FileManager.default.contents(atPath: path) else {
                throw HandoffError(
                    "The screenshot at \(path) is no longer there, so nothing was sent."
                )
            }
            return ((path as NSString).lastPathComponent, data)
        }

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
            // THE CLICK CUTS BOTH WAYS, so focus is verified around it, not
            // assumed. It exists because activation alone restores focus to
            // whatever had it last — the first live fling pasted into a widget
            // nobody was looking at. But the field also produced the OPPOSITE
            // failure: the caret was already blinking in the chat input, the
            // drop landed on the panel's transcript a few hundred points away,
            // and the click BLURRED the input — focus ended on a non-editable
            // AXGroup and the paste vanished. No CGEvent reports where a paste
            // will land; Accessibility can say what holds focus. So: read
            // focus BEFORE the one click, read it after, and repair what the
            // readings show. ONE click — a review caught this block briefly
            // coexisting with the older click above it, which fired two clicks
            // ~150ms apart at the same pixel: inside the double-click window,
            // so hosts read them as a word-select, and the paste then REPLACED
            // the selected text. The `before` reading also has to precede the
            // only click, or the blur it exists to catch has already happened.
            let before = focusedElement()
            note("focus before click: \(before.map(describe) ?? "nothing focused")")
            note("clicking drop point (\(Int(drop.x)), \(Int(drop.y))) — still \(target.appName)")
            guard click(at: point) else {
                throw HandoffError("Could not synthesize the click at the drop point.")
            }
            // Let the click settle — a web view (VS Code's chat) moves focus on
            // the mouse-up, and pasting before that lands in the old widget.
            try await Task.sleep(for: .milliseconds(150))
            var after = focusedElement()
            note("focus after click: \(after.map(describe) ?? "nothing focused")")

            // A click on a window that was not KEY can be spent making it key
            // and never reach a widget — focus lands somewhere unrelated. One
            // more click lands on a window that is key by then. Only when a
            // REAL frame excludes the point (or nothing is focused at all): a
            // zero-size frame is a Monaco caret textarea that may be exactly
            // right, and an empty rect contains nothing, so judging it here
            // would spend a pointless click on a focus that was already good.
            let excludesPoint = after?.frame.map {
                $0.width > 0 && $0.height > 0 && !$0.contains(point)
            } ?? (after == nil)
            if excludesPoint {
                note("focus is not the widget under the drop point — clicking again")
                _ = click(at: point)
                try await Task.sleep(for: .milliseconds(150))
                after = focusedElement()
                note("focus after second click: \(after.map(describe) ?? "nothing focused")")
            }

            // The blur repair. The field produced a drop on the chat panel's
            // TRANSCRIPT while the caret sat in its composer: the click
            // blurred the input the user was aiming beside. When something
            // text-editable was focused before the click, the click demoted
            // focus to something that is not, and the two overlap (the input
            // sits inside the panel that took the click), put focus back.
            // AX-refocus first (no side effects); its own click second.
            var repairedFocus = false
            if let before, isTextEditable(before.role), let beforeFrame = before.frame,
               !isTextEditable(after?.role),
               let afterFrame = after?.frame,
               // Midpoint containment, NOT intersects: a focused Monaco
               // composer manifests as a ZERO-WIDTH caret textarea, and an
               // empty rect intersects nothing — the repair would never fire
               // for exactly the input it exists to restore.
               afterFrame.contains(CGPoint(x: beforeFrame.midX, y: beforeFrame.midY)) {
                note("the click blurred the text input it was aimed near — restoring focus")
                AXUIElementSetAttributeValue(
                    before.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
                )
                try await Task.sleep(for: .milliseconds(100))
                after = focusedElement()
                if !isTextEditable(after?.role) {
                    _ = click(at: CGPoint(x: beforeFrame.midX, y: beforeFrame.midY))
                    try await Task.sleep(for: .milliseconds(150))
                    after = focusedElement()
                }
                repairedFocus = isTextEditable(after?.role)
                note("focus after restore: \(after.map(describe) ?? "nothing focused")")
            }

            // Two repair paths, chosen by what is KNOWN about the host.
            //
            // Chat-panel hosts (VS Code family): the webview is measurably
            // opaque — every field hunt found nothing, because the composer
            // exists in AX only once focused. Hunting is 700ms of proven
            // futility there, so these hosts go straight to the input-strip
            // click, and refuse honestly if even that secures nothing.
            //
            // Everyone else: the composer hunt. A native host's input DOES
            // live in its AX tree, and Chromium exposes one once poked — the
            // same AXManualAccessibility poke capture relies on. The poked
            // tree takes ~300ms to build (AXProbe's retry sleeps exactly
            // that), so the search waits, and retries once. No refusal on
            // the generic path: an unverifiable focus proceeds exactly as it
            // did before any of this existed — no worse than yesterday.
            var container: (element: AXUIElement, frame: CGRect?)?
            if !focusReachesAPaste(after?.role) {
                let bundleID = NSRunningApplication(
                    processIdentifier: target.pid
                )?.bundleIdentifier

                if let bundleID, chatPanelHosts.contains(bundleID) {
                    container = dropContainer(near: point)
                    // The input-strip click. A chat's input box lives in the
                    // bottom strip of its panel — the one place a click has
                    // ALWAYS reached the composer, back to the first live
                    // fling. One click, ~55pt above the panel's bottom edge,
                    // then read the signature. No second guesses: a miss
                    // here could be sitting on a control row, and a blind
                    // paste-and-Return after a misclick can activate
                    // whatever the click opened; the refusal below is the
                    // net. The height gate skips panels too short to have a
                    // strip — and degenerate geometry AX failed to read.
                    // ponytail: 55pt is a fixed offset measured against
                    // today's VS Code layout; zoom or a taller control row
                    // moves the input and the refusal catches the miss.
                    if let panel = container?.frame, panel.height > 120 {
                        let strip = CGPoint(x: panel.midX, y: panel.maxY - 55)
                        note("clicking the panel's input strip at (\(Int(strip.x)), \(Int(strip.y)))")
                        _ = click(at: strip)
                        try await Task.sleep(for: .milliseconds(200))
                        after = focusedElement()
                        repairedFocus = repairedFocus || focusReachesAPaste(after?.role)
                        note("focus after input-strip click: \(after.map(describe) ?? "nothing focused")")
                    }
                    if !focusReachesAPaste(after?.role) {
                        throw HandoffError(
                            "The chat's input box never took focus — pasting would have gone nowhere you could see. Nothing was sent; the prompt is still on disk beside the session. Click into the chat input once, then throw again."
                        )
                    }
                } else {
                    AXProbe.enableManualAccessibility(pid: target.pid)
                    try await Task.sleep(for: .milliseconds(400))
                    container = dropContainer(near: point)
                    var found = container.flatMap { composer(in: $0.element) }
                    if found == nil {
                        try await Task.sleep(for: .milliseconds(300))
                        container = dropContainer(near: point)
                        found = container.flatMap { composer(in: $0.element) }
                    }
                    if let found {
                        note("composer found at (\(Int(found.frame.midX)), \(Int(found.frame.midY))) — focusing it")
                        AXUIElementSetAttributeValue(
                            found.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
                        )
                        try await Task.sleep(for: .milliseconds(100))
                        after = focusedElement()
                        if !focusReachesAPaste(after?.role) {
                            _ = click(at: CGPoint(x: found.frame.midX, y: found.frame.midY))
                            try await Task.sleep(for: .milliseconds(150))
                            after = focusedElement()
                        }
                        repairedFocus = repairedFocus || focusReachesAPaste(after?.role)
                        note("focus after composer hunt: \(after.map(describe) ?? "nothing focused")")
                    } else {
                        note("no composer found under the drop — proceeding with the click's focus")
                    }
                }
            }

            // THE FILE GUARD. When focus ends on something text-editable that
            // is NOT under the drop point and NOT inside the panel the drop
            // landed in, pasting would write the prompt into a text area the
            // user never aimed at — the measured failure was 4k characters
            // into an open source file, via a click that bounced focus to the
            // editor's caret. An honest refusal beats that; the rendered
            // prompt stays on disk beside the session either way.
            //
            // Geometry by MIDPOINT, not intersection — a Monaco caret
            // textarea is zero-width and an empty rect intersects nothing.
            // Deliberately narrow: unknown or non-editable focus (a
            // browser's coarse web area) proceeds exactly as before, so no
            // working host regresses; focus this code placed itself
            // (`repairedFocus`) is trusted.
            if let landing = after, !repairedFocus, isTextEditable(landing.role),
               let landingFrame = landing.frame,
               !landingFrame.contains(point) {
                // Only REAL panel geometry may judge — an unreadable frame
                // must not masquerade as a panel that contains nothing and
                // refuse a delivery that was actually correct.
                let panel = ((container ?? dropContainer(near: point))?.frame)
                    .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                let landingMid = CGPoint(x: landingFrame.midX, y: landingFrame.midY)
                let outsidePanel = panel.map { !$0.contains(landingMid) }
                    // No panel geometry to judge by — fall back to identity:
                    // focus never moved off the pre-click element at all.
                    ?? (before.map { CFEqual(landing.element, $0.element) } ?? false)
                if outsidePanel {
                    throw HandoffError(
                        "The drop landed on \(target.appName), but keyboard focus ended in a text area far from where you aimed — pasting would have written the prompt there. Nothing was sent; the prompt is still on disk beside the session. Try dropping on the chat's input box itself."
                    )
                }
            }
        }

        // IMAGES FIRST, TEXT LAST. A chat composer puts an attachment above the
        // message being written, so this is the order that produces "here are
        // two screenshots, and here is what I was saying" rather than the
        // reverse — and `attachedText` numbers the images in exactly this
        // order, so the order is load-bearing, not cosmetic.
        for (index, payload) in payloads.enumerated() {
            note("pasting image \(index + 1)/\(payloads.count): \(payload.name)")
            try pasteImage(payload.data)
            // `pasteboardRestoreDelay`, not a smaller number, and the reason is
            // the one this file already worked out for the restore: nothing can
            // observe that a paste has landed, because reading a pasteboard
            // does not bump `changeCount`. The next image's `clearContents()`
            // is the same hazard as an early restore — if the composer has not
            // consumed this one yet, it is simply gone.
            //
            // And a lost image here is not a visibly missing attachment. The
            // numbering in `attachedText` counts every crop, so image 2 going
            // missing silently relabels 3 as 2 — every caption after the gap
            // now names the wrong picture, which is worse than sending none.
            // Slow and right beats fast and quietly wrong.
            try await Task.sleep(for: .seconds(pasteboardRestoreDelay))
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
        try pasteboardPaste(what: "prompt") { pasteboard in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            // Transient for the same reason a crop is: this text is the
            // developer's narration plus strings read off their screen, and a
            // clipboard manager that archives it has taken a copy of session
            // content nobody offered it.
            item.setString("", forType: transientType)
            return pasteboard.writeObjects([item])
        }
    }

    /// One crop, as image BYTES on the clipboard.
    ///
    /// The destination is a model that cannot reach this filesystem, so a
    /// reference of any kind is useless to it — the pixels have to travel.
    private static func pasteImage(_ data: Data) throws {
        try pasteboardPaste(what: "screenshot") { pasteboard in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            // PNG BYTES ONLY — no `.fileURL` flavour riding along.
            //
            // It was there "for destinations that prefer it", and no such
            // destination exists: this path is reached only for a browser, and
            // a browser preferring the URL flavour inserts
            // `file:///Users/…/h01-r002.png` as TEXT and attaches nothing —
            // putting back the dead link this whole feature removes, under
            // numbered captions naming attachments that never arrived.
            item.setString("", forType: transientType)
            return pasteboard.writeObjects([item])
        }
    }

    /// `org.nspasteboard.TransientType` — the convention clipboard managers
    /// watch to leave an item out of their history.
    ///
    /// Not decoration. A crop is a photograph of the developer's screen, and
    /// `redact.mjs` is explicit that redaction cannot touch pixels: text gets
    /// scrubbed, an image cannot be. Putting raw crops on the system pasteboard
    /// hands them to every clipboard manager running — and some of those sync
    /// their history to a cloud account. That is screen content leaving the Mac
    /// by a route nobody chose, which is the one thing this product promises
    /// does not happen.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

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

        // BOTH failure exits clear `pendingRestore` as well as restoring.
        //
        // They used to only restore. The record stayed behind holding the
        // developer's clipboard and a work item that had already been
        // cancelled, so nothing would ever nil it — and the next paste, however
        // much later, read its `saved` in preference to the live pasteboard and
        // put a stale clipboard back three seconds after pasting. Copy a
        // password in between and that is what gets restored over it.
        pasteboard.clearContents()
        guard write(pasteboard) else {
            // Abort BEFORE any keystroke. The old code carried on: Cmd+V pasted
            // nothing into an emptied pasteboard and Return was posted anyway,
            // submitting whatever half-typed message was already in the input.
            restore(saved, to: pasteboard, ifStillAt: pasteboard.changeCount)
            pendingRestore = nil
            throw HandoffError("Could not put the \(what) on the clipboard.")
        }
        let ours = pasteboard.changeCount
        note("pasteboard now holds \(what) (changeCount \(ours)); posting Cmd+V")

        guard tap(keyCode: 9, flags: .maskCommand) else { // 9 = V
            restore(saved, to: pasteboard, ifStillAt: ours)
            pendingRestore = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay, execute: work)
    }

    /// How long to assume a destination needs to read the pasteboard.
    ///
    /// One number, used twice, because both uses are the same unanswerable
    /// question: reading a pasteboard does not bump `changeCount`, so nothing
    /// can observe that a paste landed. Restoring early hands the destination
    /// the developer's previous clipboard; overwriting early for the next image
    /// simply loses that image. Two constants would eventually disagree and
    /// only one of them would be right.
    private static let pasteboardRestoreDelay: TimeInterval = 3.0

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

    /// Roles a paste can land in. Deliberately the concrete input roles, not
    /// AXWebArea: a coarse web area MIGHT route a paste correctly, and the
    /// callers treat "not editable" as "try to do better, then proceed
    /// anyway" — never as a reason to refuse a host that works today.
    private static let textEditableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox",
    ]

    private static func isTextEditable(_ role: String?) -> Bool {
        role.map { textEditableRoles.contains($0) } ?? false
    }

    /// Every AX round-trip is Mach IPC into the TARGET app's main thread — a
    /// stuck modal or a debugger-paused process would otherwise block Fovea's
    /// own main actor for the OS default. Same ceiling AXProbe uses, applied
    /// to every element this file mints, because the timeout does not
    /// propagate across separately-obtained refs.
    private static let axTimeout: Float = 0.25

    private static func withTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }

    private static func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
        return ref as? String
    }

    /// Top-left global coordinates — the same space the drop point lives in.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// What holds keyboard focus right now, per Accessibility. Nil when AX
    /// answers nothing (an app with no AX support, or focus genuinely
    /// nowhere). The frame can be nil for a real element that exposes no
    /// geometry; callers treat that as "cannot confirm".
    private static func focusedElement() -> (element: AXUIElement, role: String, frame: CGRect?)? {
        let systemWide = withTimeout(AXUIElementCreateSystemWide())
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
              ) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = withTimeout(focusedRef as! AXUIElement)
        return (element, role(of: element) ?? "?", frame(of: element))
    }

    private static func describe(_ focus: (element: AXUIElement, role: String, frame: CGRect?)) -> String {
        guard let f = focus.frame else { return "\(focus.role) (no frame)" }
        return "\(focus.role) at (\(Int(f.origin.x)), \(Int(f.origin.y))) \(Int(f.width))×\(Int(f.height))"
    }

    /// The panel the drop landed in: ascend from the element under the point
    /// while the ancestor still contains it, is not the window, and stays
    /// narrower than ~70% of a screen — the panel, never the whole window,
    /// which is what keeps a code editor's text area out of both the
    /// composer search and the file guard's notion of "where you aimed".
    private static func dropContainer(near point: CGPoint) -> (element: AXUIElement, frame: CGRect?)? {
        let systemWide = withTimeout(AXUIElementCreateSystemWide())
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                  systemWide, Float(point.x), Float(point.y), &hitRef
              ) == .success,
              let start = hitRef.map(withTimeout)
        else { return nil }

        let widthCap = 0.7 * (NSScreen.screens.map { $0.frame.width }.max() ?? 1920)
        var container = start
        var cursor = start
        for _ in 0..<8 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      cursor, kAXParentAttribute as CFString, &parentRef
                  ) == .success,
                  let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID()
            else { break }
            let parent = withTimeout(parentRef as! AXUIElement)
            guard let f = frame(of: parent), f.contains(point),
                  role(of: parent) != "AXWindow", f.width < widthCap
            else { break }
            container = parent
            cursor = parent
        }
        // Nil frame stays nil — a `.zero` stand-in reads as "a panel that
        // contains nothing" and once turned a correct delivery into a refusal.
        return (container, frame(of: container))
    }

    /// The text input belonging to a panel — a chat's composer sits at the
    /// BOTTOM, under a transcript that eats stray clicks, so the lowest
    /// editable descendant is the input meant. NO minimum size: a focused
    /// Monaco composer manifests as a zero-width caret textarea, and a size
    /// filter here is how the first hunt missed it.
    ///
    /// ponytail: bounded DFS, 400-node budget, depth 12 — a panel that hides
    /// its composer deeper than that fails safe to the caller's file guard.
    private static func composer(in container: AXUIElement) -> (element: AXUIElement, frame: CGRect)? {
        var budget = 400
        var best: (element: AXUIElement, frame: CGRect)?
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 12 else { return }
            budget -= 1
            if isTextEditable(role(of: element)), let f = frame(of: element) {
                if best == nil || f.minY > best!.frame.minY { best = (element, f) }
            }
            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                      element, kAXChildrenAttribute as CFString, &kidsRef
                  ) == .success,
                  let kids = kidsRef as? [AXUIElement]
            else { return }
            for kid in kids { walk(withTimeout(kid), depth: depth + 1) }
        }
        walk(container, depth: 0)
        return best
    }

    /// One left click at a CG-global point — the focus half of a drop.
    ///
    /// `clickState` is pinned to 1 on both halves: the focus ladder can
    /// legitimately click the same neighbourhood twice inside the system
    /// double-click interval (the key-window retry, the input-strip), and a
    /// receiver that derives clickCount from the event would read that as a
    /// word-select — after which a paste REPLACES the selection. Each of
    /// these is a deliberate single click and says so.
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
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
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
