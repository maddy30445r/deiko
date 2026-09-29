import AppKit
import DeikoHandoff

// The handoff: pastes the developer's prompt into the window the orb landed on.
// Everything decided lives in `DeikoHandoff`; this file is the untestable
// plumbing (reading the window list, activating an app, synthesizing a paste)
// and holds no judgement calls beyond the ones documented inline.
//
// If the paste or the Return misses, `prompt.txt` is still on disk beside the
// session and the orb says where. That is the fallback, and the reason nothing
// here reports partial success.
//
// The fling is the approval: a deliberate gesture at a named target. It must
// never become automatic on session end.

/// A target plus where its window sits, so the orb can outline what the user
/// is about to commit to. The bounds are CG-global (top-left origin).
struct ResolvedTarget {
    let target: HandoffTarget
    let windowBounds: CGRect
}

@MainActor
enum Handoff {

    /// Where a handoff narrates itself. `OrbController` points this at the app's
    /// log on first use, so a field run is never quieter than a test harness.
    static var trace: ((String) -> Void)?

    private static func note(_ message: String) { trace?(message) }

    /// The record for the fling in flight, filled in as it goes. Same pattern as
    /// `Diagnostics.lastFailure`: threading it through every early return and
    /// `throw` would mean each new exit had to remember to carry it. Reset at the
    /// top of `deliver`; read by `Orb` when the call comes back or throws.
    @MainActor static var lastReport = FlingReport(outcome: .refused)

    /// Nil until a fling has actually happened this launch. `lastReport` is
    /// seeded before every attempt, so its existence cannot signal that;
    /// `elapsedMs` being stamped by the `defer` does.
    @MainActor static var lastFlingLine: String? {
        lastReport.elapsedMs > 0 ? lastReport.diagnosticLine : nil
    }

    /// The app owning the frontmost window under a point, for the orb to name
    /// while aiming.
    ///
    /// Uses the window list rather than an AX hit-test: this runs on every
    /// mouse-move of a fling, and `AXProbe`'s point probe can sleep 300ms poking
    /// Electron apps.
    static func targetUnder(point: CGPoint, excluding orbWindow: NSWindow?) -> ResolvedTarget? {
        // CGWindowList coordinates are CG global (top-left origin), the same
        // space as `CGEvent.location`: no flip needed.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let orbNumber = orbWindow.map { CGWindowID($0.windowNumber) }

        for info in windows {
            // Layer 0 is normal windows. Anything above is overlays, menus, and
            // Deiko's own surfaces; anything below is desktop furniture.
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
            // The first window containing the point decides: the list is
            // front-to-back, so a covered window never becomes the target. If
            // that window refuses to resolve (it is Deiko's, or nameless), the
            // fling aims at nothing rather than whatever shows through.
            return HandoffTarget.resolve(
                pid: pid, appName: name, ownPid: ProcessInfo.processInfo.processIdentifier
            ).map { ResolvedTarget(target: $0, windowBounds: rect) }
        }
        return nil
    }

    /// Destinations that cannot open a local file path, so the crops have to
    /// travel as bytes. A browser chat runs the model elsewhere: handing it
    /// `/Users/…/h01-r008.png` is a string it cannot follow, and a model will
    /// often carry on as if it had looked.
    ///
    /// A list, so liable to go stale, but a browser missing from it just falls
    /// back to pasting paths. Nothing is added on a hunch.
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
    /// click secured no usable focus. Same list discipline as
    /// `browserBundleIDs`: this decides how focus is secured, never whether
    /// delivery happens, and a host missing from it gets the generic click path.
    ///
    /// The generic path cannot reach a VS Code chat: the webview exposes no
    /// text-input roles to Accessibility in its resting state, and a click on
    /// the transcript leaves DOM focus on a non-editable group. A click on the
    /// input box itself, which lives in the panel's bottom strip, does work.
    private static let chatPanelHosts: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// The focus signatures a paste is known to reach. A concrete text role is
    /// the composer itself; AXWebArea is Chromium reporting that the webview has
    /// DOM focus (the composer holds it behind).
    private static func focusReachesAPaste(_ role: String?) -> Bool {
        isTextEditable(role) || role == "AXWebArea"
    }

    /// Activate the target and paste the developer's prompt into it.
    ///
    /// Throws rather than reporting partial success: every failure here has the
    /// same remedy (the orb points at `prompt.txt`) and the same severity.
    static func deliver(
        to target: HandoffTarget, text: String, images: [String],
        persona: String? = nil, personaFile: String? = nil
    ) async throws {
        lastReport = FlingReport(
            outcome: .refused,
            appName: target.appName,
            pid: target.pid,
            bundleID: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        )
        let startedAt = Date()
        defer { lastReport.elapsedMs = Date().timeIntervalSince(startedAt) * 1000 }

        // Read every crop before anything is activated, clicked or pasted. A
        // session directory can be moved or deleted between the render and the
        // fling, and discovering that halfway through would leave images in the
        // composer with no text and no Return: a partial send. Failing here
        // costs nothing.
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
        // than sleeping a fixed time: activation is usually ~50ms but can stall
        // behind a space switch, and a paste into the old window is the worst
        // outcome here.
        var polls = 0
        for _ in 0..<40 where !app.isActive {
            polls += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        note("activation settled after \(polls * 50)ms; isActive=\(app.isActive)")
        guard app.isActive else {
            throw HandoffError("Could not bring \(target.appName) forward.", reason: "no-activate")
        }

        // A moment more for the app to route key focus to its front window:
        // `isActive` says the app owns the menu bar, not that its text field is
        // first responder.
        try await Task.sleep(for: .milliseconds(150))

        // Wake the AX tree before any focus is read, for every host. Electron
        // builds its accessibility tree lazily: until AXManualAccessibility is
        // set, a system-wide focused-element read returns nothing for a VS Code
        // window, so focus cannot be verified and a correct click looks like a
        // miss.
        //
        // Then wait for the tree to answer rather than sleeping a fixed time,
        // which is a guess about another app's tree-build time. The poll is
        // unconditional: an already-awake tree answers on the first iteration
        // and costs nothing, and that stops a stale poke record from
        // reintroducing the bug. It never throws: an app that genuinely has
        // nothing focused waits out the deadline and proceeds, and the
        // chat-panel refusal below is still the net.
        let pokeIssued = AXProbe.enableManualAccessibility(pid: target.pid)
        lastReport.pokeIssued = pokeIssued
        let treeAnsweredMs = await awaitTree(pid: target.pid, deadlineMs: 2000)
        lastReport.treeAnsweredMs = treeAnsweredMs
        note(
            treeAnsweredMs.map {
                "accessibility tree answered after \(Int($0))ms (poke \(pokeIssued ? "issued" : "reused"))"
            } ?? "accessibility tree never answered within 2000ms — proceeding blind "
                + "(poke \(pokeIssued ? "issued" : "reused"))"
        )

        // Click where the fling was released, so focus is the widget the user
        // aimed at. Activation alone restores the app's previous focus, which
        // may be a different widget than the chat input. This is the half of
        // drag-and-drop that a real drop performs.
        if let drop = target.dropPoint {
            let point = CGPoint(x: drop.x, y: drop.y)

            // Re-resolve the pixel before clicking. Up to 2.15s passes between
            // the release and this line, and the window under the point can
            // change (a dialog dismisses, a panel collapses, a Space reflows).
            // Without this the click can land on a different app, which then
            // takes the paste and the Return while the orb named the original.
            // `HandoffTarget` calls that name "the safety property"; this keeps
            // it true through to the click.
            let now = targetUnder(point: point, excluding: nil)
            guard let now, now.target.pid == target.pid else {
                throw HandoffError(
                    "\(target.appName) is no longer under the point you dropped on"
                        + (now.map { " (\($0.target.appName) is)" } ?? "")
                        + "."
                , reason: "moved")
            }
            // The click cuts both ways, so focus is verified around it rather
            // than assumed. Activation alone restores focus to whatever had it
            // last, but a click can also blur an input that already had the caret
            // (a drop on the panel's transcript blurs the composer beside it). No
            // CGEvent reports where a paste will land; Accessibility can say what
            // holds focus. So: read focus before the one click, read it after,
            // and repair what the readings show. Exactly one click, and the
            // `before` reading must precede it: two clicks ~150ms apart at the
            // same pixel fall inside the double-click window, so hosts read a
            // word-select and the paste replaces the selection.
            let before = focusedElement()
            lastReport.focusBefore = before.map(describe) ?? "nothing focused"
            note("focus before click: \(before.map(describe) ?? "nothing focused")")
            note("clicking drop point (\(Int(drop.x)), \(Int(drop.y))) — still \(target.appName)")
            guard click(at: point) else {
                throw HandoffError("Could not synthesize the click at the drop point.")
            }
            // Let the click settle: a web view (VS Code's chat) moves focus on
            // mouse-up, and pasting before that lands in the old widget.
            try await Task.sleep(for: .milliseconds(150))
            var after = focusedElement()
            note("focus after click: \(after.map(describe) ?? "nothing focused")")

            // A click on a window that was not key can be spent making it key and
            // never reach a widget; one more click lands on a window that is key
            // by then. Only when a real frame excludes the point (or nothing is
            // focused): a zero-size frame is a Monaco caret textarea that may be
            // exactly right, and an empty rect contains nothing.
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

            // The blur repair. When something text-editable was focused before
            // the click, the click demoted focus to something that is not, and
            // the two overlap (the input sits inside the panel that took the
            // click), put focus back: AX-refocus first (no side effects), its own
            // click second.
            var repairedFocus = false
            if let before, isTextEditable(before.role), let beforeFrame = before.frame,
               !isTextEditable(after?.role),
               let afterFrame = after?.frame,
               // Midpoint containment, not intersects: a focused Monaco
               // composer is a zero-width caret textarea, and an empty rect
               // intersects nothing.
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

            // Two repair paths, chosen by what is known about the host.
            //
            // Chat-panel hosts (VS Code family): the webview is opaque to AX
            // until the composer is focused, so hunting for it is futile. These
            // go straight to the input-strip click and refuse honestly if even
            // that secures nothing.
            //
            // Everyone else: the composer hunt. A native host's input lives in
            // its AX tree, and Chromium exposes one once poked; the poked tree
            // takes ~300ms to build, so the search waits and retries once. No
            // refusal on this path: unverifiable focus proceeds as it would
            // without any of this.
            var container: (element: AXUIElement, frame: CGRect?)?
            if !focusReachesAPaste(after?.role) {
                let bundleID = NSRunningApplication(
                    processIdentifier: target.pid
                )?.bundleIdentifier

                if let bundleID, chatPanelHosts.contains(bundleID) {
                    container = dropContainer(near: point)
                    // The input-strip click. A chat's input box lives in the
                    // bottom strip of its panel. Click there, read the focus
                    // signature, and try a second offset only on a verified miss:
                    // the read between attempts is what makes a retry safe, since
                    // a blind paste-and-Return after a misclick can activate
                    // whatever the click opened. The height gate skips panels too
                    // short to have a strip, and degenerate geometry AX failed to
                    // read. If neither offset takes focus, the refusal below is
                    // the net.
                    // Fixed offsets, not a model of the panel layout: zoom or a
                    // taller control row can move the input, and the refusal
                    // catches a miss.
                    if let panel = container?.frame, panel.height > 120 {
                        for offset in [55.0, 30.0] {
                            let strip = CGPoint(x: panel.midX, y: panel.maxY - offset)
                            note("clicking the panel's input strip at (\(Int(strip.x)), \(Int(strip.y)))")
                            _ = click(at: strip)
                            try await Task.sleep(for: .milliseconds(200))
                            after = focusedElement()
                            repairedFocus = repairedFocus || focusReachesAPaste(after?.role)
                            note("focus after input-strip click: \(after.map(describe) ?? "nothing focused")")
                            if focusReachesAPaste(after?.role) { break }
                        }
                    }
                    if !focusReachesAPaste(after?.role) {
                        throw HandoffError(
                            "The chat's input box never took focus — pasting would have gone nowhere you could see. Nothing was sent; the prompt is still on disk beside the session. Click into the chat input once, then throw again."
                        , reason: "no-focus")
                    }
                } else {
                    // The AX poke and its settle happen earlier, ahead of the
                    // first focus read.
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

            // The file guard. When focus ends on something text-editable that is
            // not under the drop point and not inside the panel the drop landed
            // in, pasting would write the prompt into a text area the user never
            // aimed at (for example an open source file). An honest refusal beats
            // that; the rendered prompt stays on disk either way.
            //
            // Geometry by midpoint, not intersection: a Monaco caret textarea is
            // zero-width. Deliberately narrow: unknown or non-editable focus (a
            // browser's coarse web area) proceeds, so no working host regresses;
            // focus this code placed itself (`repairedFocus`) is trusted.
            if let landing = after, !repairedFocus, isTextEditable(landing.role),
               let landingFrame = landing.frame,
               !landingFrame.contains(point) {
                // Only real panel geometry may judge: an unreadable frame must
                // not masquerade as a panel that contains nothing and refuse a
                // correct delivery.
                let panel = ((container ?? dropContainer(near: point))?.frame)
                    .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
                let landingMid = CGPoint(x: landingFrame.midX, y: landingFrame.midY)
                let outsidePanel = panel.map { !$0.contains(landingMid) }
                    // No panel geometry to judge by: fall back to identity
                    // (focus never moved off the pre-click element).
                    ?? (before.map { CFEqual(landing.element, $0.element) } ?? false)
                if outsidePanel {
                    throw HandoffError(
                        "The drop landed on \(target.appName), but keyboard focus ended in a text area far from where you aimed — pasting would have written the prompt there. Nothing was sent; the prompt is still on disk beside the session. Try dropping on the chat's input box itself."
                    , reason: "focus-elsewhere")
                }
            }
        }

        // Images first, text last. A chat composer puts an attachment above the
        // message being written, and `attachedText` numbers the images in exactly
        // this order, so the order is load-bearing.
        //
        // The target is re-checked before every keystroke, not once at the top.
        // Several images take seconds of sleeps, and keystrokes land in whatever
        // has focus as if the user had typed them: switching apps mid-sequence
        // would send a screenshot, then the prompt, then a Return to the wrong
        // app. Refusing mid-sequence is a partial send, so it is thrown rather
        // than noted.
        func stillFocused(_ step: String) throws {
            guard app.isActive else {
                throw HandoffError(
                    "\(target.appName) lost focus before \(step) — stopped so nothing went to the wrong app."
                )
            }
        }

        for (index, payload) in payloads.enumerated() {
            try stillFocused("image \(index + 1) was pasted")
            note("pasting image \(index + 1)/\(payloads.count): \(payload.name)")
            try pasteImage(payload.data)
            // `pasteboardRestoreDelay`, not a smaller number: nothing can observe
            // that a paste has landed (reading a pasteboard does not bump
            // `changeCount`), so the next image's `clearContents()` is the same
            // hazard as an early restore. A lost image also relabels every later
            // caption in `attachedText`, which is worse than sending none.
            try await Task.sleep(for: .seconds(pasteboardRestoreDelay))
        }

        // The persona goes in first, as its own paste. A browser chat cannot
        // open the file `text` would otherwise name, so the instructions travel
        // as content, and both major composers fold a long paste into an
        // attachment tile of its own: the persona as an attachment, the brief as
        // the message. A chat that ignores the file paste is left with the short
        // text below.
        //
        // Whether the file landed is deliberately not detected: finding the tile
        // means driving AXProbe's region sampler on every browser handoff, which
        // is a lot of machinery to remove four lines of text that agree with the
        // file. Either outcome loses no instruction, which is what makes not
        // knowing acceptable.
        //
        // Same delay as between images, for the same reason.
        if let personaFile, FileManager.default.fileExists(atPath: personaFile) {
            let name = (personaFile as NSString).lastPathComponent
            try stillFocused("the persona file was pasted")
            note("pasting \(name) into \(target.appName)")
            try pasteFile(personaFile)
            try await Task.sleep(for: .seconds(pasteboardRestoreDelay))
        }

        if let persona, !persona.isEmpty {
            try stillFocused("the persona was pasted")
            note("pasting the persona (\(persona.count) characters) into \(target.appName)")
            try paste(persona)
            try await Task.sleep(for: .seconds(pasteboardRestoreDelay))
        }

        try stillFocused("the prompt was pasted")
        note("pasting \(text.count) characters into \(target.appName)")
        try paste(text)

        // Let the destination process the paste before anything else: a large
        // multi-line paste needs a beat to land in the input before a Return
        // arrives.
        try await Task.sleep(for: .milliseconds(250))

        // Paste, wait, one Return. Other sequences (two Returns,
        // Escape-then-Return, a pasted trailing newline, paste-only) do not
        // submit.
        //
        // Multi-line paste relies on bracketed paste. A host that does not honour
        // it submits at each newline, so the prompt arrives fragmented across
        // several messages. If that happens, look here first.
        //
        // The Return cannot be taken back: a paste into the wrong app is a mess,
        // a Return there is a message sent. It is checked last of all, after the
        // delay the paste needed to land.
        try stillFocused("Return was pressed")
        tap(keyCode: kReturn)
        note("done")
    }

    private static let kReturn: CGKeyCode = 36

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
            // clipboard manager that archives it would take a copy of session
            // content nobody offered it.
            item.setString("", forType: transientType)
            return pasteboard.writeObjects([item])
        }
    }

    /// A file on the clipboard, the way Finder's Copy puts it there. Chrome
    /// turns this into a real `File` in the page's paste event, so a chat that
    /// handles document pastes attaches the persona as a document instead of
    /// receiving it as prose. Some chats ignore it (nothing is inserted), which
    /// is why the short text still follows.
    ///
    /// No text flavour rides along, deliberately: when both were on the
    /// pasteboard, browsers preferred the URL and inserted `file:///Users/…` as
    /// dead text. A file URL alone either becomes a file or becomes nothing.
    private static func pasteFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        try pasteboardPaste(what: "the persona file") { pasteboard in
            pasteboard.writeObjects([url as NSURL])
        }
    }

    /// One crop, as image bytes on the clipboard. The destination is a model
    /// that cannot reach this filesystem, so a reference of any kind is useless
    /// to it.
    private static func pasteImage(_ data: Data) throws {
        try pasteboardPaste(what: "screenshot") { pasteboard in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            // PNG bytes only, with no `.fileURL` flavour: this path is reached
            // only for a browser, and a browser preferring the URL flavour
            // inserts `file:///Users/…/h01-r002.png` as text and attaches
            // nothing.
            item.setString("", forType: transientType)
            return pasteboard.writeObjects([item])
        }
    }

    /// `org.nspasteboard.TransientType`: the convention clipboard managers
    /// watch to leave an item out of their history. A crop is a photograph of
    /// the developer's screen and redaction cannot touch pixels, so raw crops on
    /// the system pasteboard would go to every clipboard manager running, some
    /// of which sync their history to a cloud account. That would be screen
    /// content leaving the Mac by a route nobody chose.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Save the developer's clipboard, put ours on it, Cmd+V, and schedule the
    /// restore. Shared by the text and image paths so the subtle parts (what
    /// gets saved, which restore owns the true original, aborting before the
    /// keystroke) exist once.
    private static func pasteboardPaste(
        what: String, write: (NSPasteboard) -> Bool
    ) throws {
        let pasteboard = NSPasteboard.general

        // Save every representation, not just the string: `clearContents()`
        // destroys whatever was there, so an image or file promise would
        // otherwise be wiped with nothing to put back, and copied rich text
        // would be downgraded.
        let saved = pendingRestore?.items ?? pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        // A restore already in flight owns the true original. Reading the
        // pasteboard again here would save the previous paste's command
        // and hand it back as the user's clipboard.
        pendingRestore?.work.cancel()

        // Both failure exits clear `pendingRestore` as well as restoring. A
        // stale record would make the next paste read its `saved` in preference
        // to the live pasteboard and put an old clipboard back three seconds
        // after pasting, over whatever was copied in between.
        pasteboard.clearContents()
        guard write(pasteboard) else {
            // Abort before any keystroke: Cmd+V would paste nothing into an
            // emptied pasteboard and Return would submit whatever half-typed
            // message was already in the input.
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

        // Restore after the destination has read the pasteboard. Always
        // scheduled, even with nothing to put back, so the command never
        // becomes the user's clipboard by default.
        //
        // The delay is a mitigation, not a fix: reading a pasteboard does not
        // bump `changeCount`, so nothing here can observe whether the paste has
        // happened, and restoring too early hands the destination the user's
        // previous clipboard. Three seconds is far past any observed paste, at
        // the cost of the clipboard being unavailable that long.
        let work = DispatchWorkItem {
            restore(saved, to: pasteboard, ifStillAt: ours)
            pendingRestore = nil
        }
        pendingRestore = (items: saved, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay, execute: work)
    }

    /// How long to assume a destination needs to read the pasteboard. One
    /// number, used twice, because both uses are the same unanswerable
    /// question: nothing can observe that a paste landed. Restoring early hands
    /// the destination the previous clipboard; overwriting early for the next
    /// image loses that image.
    private static let pasteboardRestoreDelay: TimeInterval = 3.0

    /// The user's clipboard, held between a paste and its restore. There is one
    /// system pasteboard, so one of these.
    private static var pendingRestore: (items: [[NSPasteboard.PasteboardType: Data]], work: DispatchWorkItem)?

    /// Put the user's clipboard back, but only if ours is still on it: anything
    /// written in the meantime is newer than the saved copy, and overwriting it
    /// would destroy the more recent intent.
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

    /// One key press-and-release at the session event tap level, so the
    /// destination receives it exactly as it would a real key.
    @discardableResult
    private static func tap(keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        // A real event source, not nil. Cmd+V works with nil because Electron
        // serves it from the native menu accelerator; a plain Return has to
        // travel into the Chromium renderer, which drops events whose source is
        // not a proper HID-state source.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        // Key-up in the same instant as key-down reads as a zero-length press,
        // and some input layers debounce on that.
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Roles a paste can land in. Deliberately the concrete input roles, not
    /// AXWebArea: a coarse web area might route a paste correctly, and callers
    /// treat "not editable" as "try to do better, then proceed", never as a
    /// reason to refuse a host that works.
    private static let textEditableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox",
    ]

    private static func isTextEditable(_ role: String?) -> Bool {
        role.map { textEditableRoles.contains($0) } ?? false
    }

    /// Every AX round-trip is Mach IPC into the target app's main thread, so a
    /// stuck modal or a debugger-paused process would block Deiko's main actor
    /// for the OS default. Same ceiling as AXProbe, applied to every element
    /// minted here because the timeout does not propagate across
    /// separately-obtained refs.
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

    /// Polls until the system-wide focused element belongs to `pid`, or the
    /// deadline passes. Returns elapsed milliseconds, or nil if it never did.
    ///
    /// The deadline is generous because the warm path costs one poll and being
    /// short is the bug. `AXProbe.messagingTimeout` bounds each AX call, so a
    /// hung target cannot stretch an iteration past it.
    private static func awaitTree(pid: pid_t, deadlineMs: Double) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < deadlineMs {
            var focusedPid: pid_t = 0
            if let focus = focusedElement(),
               AXUIElementGetPid(focus.element, &focusedPid) == .success,
               FlingReport.treeIsReady(focusedPid: focusedPid, targetPid: pid) {
                return Date().timeIntervalSince(start) * 1000
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// What holds keyboard focus right now, per Accessibility. Nil when AX
    /// answers nothing (an app with no AX support, or focus genuinely nowhere).
    /// The frame can be nil for a real element that exposes no geometry; callers
    /// treat that as "cannot confirm".
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
    /// narrower than ~70% of a screen. That keeps a code editor's text area out
    /// of both the composer search and the file guard's notion of where you
    /// aimed.
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
        // Nil frame stays nil: a `.zero` stand-in reads as a panel that contains
        // nothing.
        return (container, frame(of: container))
    }

    /// The text input belonging to a panel. A chat's composer sits at the
    /// bottom, under a transcript that eats stray clicks, so the lowest editable
    /// descendant is the input meant. No minimum size: a focused Monaco composer
    /// is a zero-width caret textarea.
    ///
    /// Bounded DFS (400-node budget, depth 12); a panel that hides its composer
    /// deeper fails safe to the caller's file guard.
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

    /// One left click at a CG-global point: the focus half of a drop.
    ///
    /// `clickState` is pinned to 1 on both halves: the focus ladder can click
    /// the same neighbourhood twice inside the system double-click interval, and
    /// a receiver that derives clickCount from the event would read a
    /// word-select, after which a paste replaces the selection.
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
    /// A short, path-free name for the refusal, for `FlingReport.diagnosticLine`.
    /// `message` cannot be used there: it names the session's `prompt.txt`, and
    /// diagnostics get pasted into group chats.
    let reason: String
    init(_ message: String, reason: String = "other") {
        self.message = message
        self.reason = reason
    }
    var errorDescription: String? { message }
}
