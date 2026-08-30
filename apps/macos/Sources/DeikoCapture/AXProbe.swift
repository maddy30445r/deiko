import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import DeikoGrounding

// ─────────────────────────────────────────────────────────────────────────────
// AX RESOLUTION — the grounding layer
//
// Cost model drives every decision in this file: an AXUIElement is a handle
// into ANOTHER PROCESS, and every attribute read is a synchronous Mach IPC
// round-trip. So:
//
//   • Region capture hit-tests a grid FIRST (1 cheap call per sample), dedupes
//     with CFEqual, and only then reads the full attribute set on the few
//     unique elements that survive. 60 samples collapsing to 4 elements costs
//     60 + 4×N calls, not 60×N.
//   • Every element we touch gets a messaging timeout, or one wedged app
//     freezes capture.
//   • We copy values out immediately. Handles go stale; referents must not.
//
// Coordinates are top-left-origin global screen space throughout — AX's space,
// and what CGEvent reports. No Cocoa flip anywhere in this file, deliberately.
// ─────────────────────────────────────────────────────────────────────────────

enum AXProbe {

    /// Per-element IPC budget. A hung app costs us 250ms, not the session.
    static let messagingTimeout: Float = 0.25

    /// Attributes we read on every resolved element, in priority order.
    static let textAttributes = [
        kAXValueAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXSelectedTextAttribute,
    ]

    /// Apps we've already poked with AXManualAccessibility this run.
    ///
    /// Locked: the 60Hz sampler pokes on app switch from the main actor while
    /// detached crop tasks poke from `probePoint`'s ungrounded retry — two
    /// unsynchronised inserts into one Set is CoW buffer corruption. Trivially
    /// reachable by pointing at something in VS Code and Cmd-Tabbing while the
    /// crop still resolves.
    nonisolated(unsafe) private static var pokedPids: Set<pid_t> = []
    private static let pokedPidsLock = NSLock()

    // ── Permission ──────────────────────────────────────────────────────────

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts once if untrusted. The prompt names the *launching* process
    /// (your terminal), not this binary — TCC grants attach to the parent.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        // Spelled literally rather than via `kAXTrustedCheckOptionPrompt`: the
        // SDK declares that constant as a mutable global, which Swift 6 strict
        // concurrency rejects. The string value is stable API.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // ── Cursor ──────────────────────────────────────────────────────────────

    /// Area of the LARGEST single display, in points. Used to reject AX
    /// rectangles that are really whole-window containers rather than the thing
    /// pointed at.
    ///
    /// Summing all displays would be wrong: the guard is "is this rect an
    /// implausibly large share of a screen", and on a three-monitor setup a
    /// summed total makes a rect covering an entire display look small enough
    /// to pass. The threshold has to mean the same thing regardless of how many
    /// monitors are plugged in.
    static func screenArea() -> Double {
        NSScreen.screens
            .map { $0.frame.width * $0.frame.height }
            .max() ?? 0
    }

    /// Cursor position already in AX coordinate space. Using CGEvent rather
    /// than NSEvent.mouseLocation avoids the bottom-left→top-left flip entirely,
    /// which is the failure mode that returns a mirrored element and no error.
    static func cursorLocation() -> Point {
        guard let loc = CGEvent(source: nil)?.location else {
            return Point(x: 0, y: 0)
        }
        return Point(x: loc.x, y: loc.y)
    }

    // ── Public entry points ─────────────────────────────────────────────────

    /// "What is under this pixel." One hit-test plus ancestors.
    static func probePoint(
        _ p: Point, allowManualRetry: Bool = true, descend: Bool = true
    ) -> ProbeEvent {
        let started = Clock.nowMs()
        let shape = Shape.point(p)

        guard var hit = hitTest(p, descend: descend) else {
            return ProbeEvent(
                shape: shape,
                app: nil,
                windowTitle: nil,
                snapshot: AXSnapshot(
                    resolved: false,
                    elements: [],
                    samplesTested: nil,
                    uniqueElements: nil,
                    manualAccessibilityApplied: false,
                    elapsedMs: Clock.nowMs() - started,
                    error: "no element at position"
                )
            )
        }

        var pid = pidOf(hit)
        var poked = false
        var element = describe(hit, withAncestors: true)

        // The Electron path. Chromium only mirrors its internal tree into the
        // native AX API when it thinks assistive tech is listening; poking
        // AXManualAccessibility flips that bridge on. The tree takes a moment
        // to build, hence the sleep before re-probing.
        if allowManualRetry, looksUngrounded(element), let ownerPid = pid {
            poked = enableManualAccessibility(pid: ownerPid)
            if poked {
                usleep(300_000)
                if let retry = hitTest(p, descend: descend) {
                    hit = retry
                    pid = pidOf(hit) ?? ownerPid
                    element = describe(hit, withAncestors: true)
                }
            }
        }

        let neighbours = neighbourhood(around: p, excluding: hit, descend: descend)

        // Order matters: the brief shows the first dozen strings, so whatever
        // leads had better be what the user meant. The aimed-at element leads
        // when it grounds something; when it does not — a bare `AXGroup`, a
        // disclosure triangle — the neighbourhood leads and the hit goes last,
        // still recorded, because its role is how we know the probe landed on
        // furniture rather than on nothing.
        let elements = groundsContent(element)
            ? [element] + neighbours
            : neighbours + [element]

        return ProbeEvent(
            shape: shape,
            app: pid.map(appIdentity(pid:)),
            windowTitle: windowTitle(for: hit),
            snapshot: AXSnapshot(
                resolved: true,
                elements: elements,
                samplesTested: nil,
                uniqueElements: nil,
                manualAccessibilityApplied: poked,
                elapsedMs: Clock.nowMs() - started,
                error: nil
            )
        )
    }

    /// How far a point looks around itself for context. Wide and short because
    /// text is: a line of a Compass document, a row of a table, a line of code.
    /// Taller would reach into unrelated rows; narrower would miss the field
    /// name sitting to the left of the value you pointed at.
    private static let neighbourhoodWidth: Double = 200
    private static let neighbourhoodHeight: Double = 44

    /// The elements immediately around a point.
    ///
    /// A point used to resolve to exactly one element — whatever
    /// `AXUIElementCopyElementAtPosition` chose to answer with — and measurement
    /// showed how thin that is. Session 20260728-230442, MongoDB Compass: the
    /// twelve points averaged 4.6ms and returned one element each, seven of them
    /// a childless `AXGroup` carrying no text at all. The four LASSOS in the same
    /// session, in the same app, seconds apart, spent ~60ms and returned 8–20
    /// real text elements. The content was in the tree the whole time; the
    /// hit-test just does not reach it.
    ///
    /// So a point now samples a small box the way a region samples a large one,
    /// through exactly the same machinery. This is not a heuristic bolted on —
    /// it is the region path, run over a smaller shape.
    private static func neighbourhood(
        around p: Point, excluding hit: AXUIElement, descend: Bool
    ) -> [AXElement] {
        let box = Shape(
            kind: .region,
            origin: p,
            bounds: Frame(
                x: p.x - neighbourhoodWidth / 2,
                y: p.y - neighbourhoodHeight / 2,
                width: neighbourhoodWidth,
                height: neighbourhoodHeight
            ),
            // No polygon: for a rectangle `Shape.contains` falls through to the
            // bounds test, which is what we want here.
            path: nil
        )

        // A tighter element cap than a region's 40. Descent is per-element and
        // each one carries its own 120ms deadline, so the cap is what bounds the
        // worst case — and a 200×44 box that resolves to more than a dozen
        // distinct nodes is dense enough that another six add nothing.
        let hits = collect(
            samples: gridSamples(in: box, maxSamples: 40, minStride: 12),
            maxElements: 12,
            descend: descend,
            // Tighter than a region's: a lasso is an explicit "spend time on
            // this", a settle is not, and points outnumber regions 3:1.
            budgetMs: 200
        )

        // Same application only. The box is OUR invention, not the user's — it
        // reaches 100pt either side of where they actually pointed, and
        // `AXUIElementCopyElementAtPosition` is system-wide, so a point near a
        // window edge would otherwise pull a neighbouring app's text in and
        // present it as this referent's grounding. A lasso does not need this
        // guard: crossing a boundary there is a thing the user drew.
        let ownerPid = pidOf(hit)
        return hits
            .filter { !CFEqual($0.element, hit) }
            .filter { ownerPid == nil || pidOf($0.element) == ownerPid }
            .map { describe($0.element, withAncestors: false) }
            .filter { carriesMeaning($0) }
            .sorted { a, b in
                guard let fa = a.frame, let fb = b.frame else { return a.frame != nil }
                return Frame.readingOrder(fa, fb)
            }
    }

    /// "What is inside this shape." AX has no rect query, so we sample a grid
    /// inside the drawn path and collapse the hits.
    ///
    /// The samples→unique ratio this reports is the granularity measurement:
    /// an app where 60 samples collapse into 1 AXGroup technically "supports
    /// AX" but cannot ground a circled region, and that distinction is invisible
    /// from point probing alone.
    static func probeRegion(
        _ shape: Shape,
        maxSamples: Int = 120,
        minStride: Double = 12,
        maxElements: Int = 40,
        allowManualRetry: Bool = true,
        descend: Bool = true
    ) -> ProbeEvent {
        let started = Clock.nowMs()

        var samples = gridSamples(in: shape, maxSamples: maxSamples, minStride: minStride)
        guard !samples.isEmpty else {
            return ProbeEvent(
                shape: shape,
                app: nil,
                windowTitle: nil,
                snapshot: AXSnapshot(
                    resolved: false,
                    elements: [],
                    samplesTested: 0,
                    uniqueElements: 0,
                    manualAccessibilityApplied: false,
                    elapsedMs: Clock.nowMs() - started,
                    error: "region has no interior samples"
                )
            )
        }

        var hits = collect(samples: samples, maxElements: maxElements, descend: descend)

        // Same Electron bridge as the point path. We judge "ungrounded" on a
        // cheap describe of the first hit rather than the whole set, so we
        // don't pay for full attribute reads before deciding to retry.
        var poked = false
        let firstPid = hits.first.flatMap { pidOf($0.element) }
        if allowManualRetry,
           let firstPid,
           hits.count <= 1 || looksUngrounded(describe(hits[0].element, withAncestors: false)) {
            poked = enableManualAccessibility(pid: firstPid)
            if poked {
                usleep(300_000)
                samples = gridSamples(in: shape, maxSamples: maxSamples, minStride: minStride)
                hits = collect(samples: samples, maxElements: maxElements, descend: descend)
            }
        }

        let described = hits.map { describe($0.element, withAncestors: false) }

        // Drop containers that carry nothing. Circling one Compass document
        // resolved 24 elements of which 16 were empty `AXGroup`s — they inflate
        // the payload sent to the model and overstate what was actually
        // captured. `uniqueElements` below still reports the pre-filter count,
        // so the samples→elements granularity signal is preserved.
        let elements = described
            .filter { carriesMeaning($0) }
            .sorted { a, b in
                guard let fa = a.frame, let fb = b.frame else { return a.frame != nil }
                return Frame.readingOrder(fa, fb)
            }

        let pid = hits.first.flatMap { pidOf($0.element) }
        return ProbeEvent(
            shape: shape,
            app: pid.map(appIdentity(pid:)),
            windowTitle: hits.first.flatMap { windowTitle(for: $0.element) },
            snapshot: AXSnapshot(
                resolved: !elements.isEmpty,
                elements: elements,
                samplesTested: samples.count,
                // PRE-filter count, deliberately. This feeds the granularity
                // measurement (how many distinct nodes a circled area resolves
                // to); using the filtered count instead would make an app that
                // exposes lots of empty containers look identical to one whose
                // tree is genuinely too coarse to ground a region.
                uniqueElements: described.count,
                manualAccessibilityApplied: poked,
                elapsedMs: Clock.nowMs() - started,
                error: elements.isEmpty ? "no elements resolved in region" : nil
            )
        )
    }

    // ── Hit-testing ─────────────────────────────────────────────────────────

    private static func hitTest(_ p: Point, descend: Bool = true) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(p.x), Float(p.y), &element
        )
        guard err == .success, let element else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        guard descend else { return element }
        return refine(element, at: p)
    }

    /// `AXUIElementCopyElementAtPosition` returns whatever node the app decides
    /// to answer with, and Chromium often answers with a container — Compass and
    /// Chrome both hand back an empty `AXGroup`/`AXWebArea` even once the bridge
    /// is on. The leaf text nodes are in the tree; hit-testing just doesn't
    /// reach them.
    ///
    /// So walk down: at each level pick the smallest child whose frame contains
    /// the point, and remember the deepest one that actually carried text.
    ///
    /// Bounded by a wall-clock DEADLINE, not just by shape. Depth and per-level
    /// caps bound each axis but not their product: 8 levels × 160 children ×
    /// five IPC round-trips per child (two for the frame, three for the text)
    /// is ~2500 synchronous calls into another process — seconds, on a probe
    /// that has a few hundred milliseconds to spend. The caps stop pathological
    /// trees; the deadline is what actually keeps us inside the budget.
    static func refine(
        _ element: AXUIElement,
        at p: Point,
        maxDepth: Int = 8,
        maxChildrenPerLevel: Int = 160,
        budgetMs: Double = 120
    ) -> AXUIElement {
        let deadline = Clock.nowMs() + budgetMs
        // If the hit already names CONTENT, the app answered properly — don't
        // pay for a descent that can only make the referent less specific.
        //
        // The test used to be "has any text", and that is how three referents in
        // one session came back as `Caret Right Icon`: the hit-tested `AXImage`
        // had alt text, so the descent stopped on a disclosure triangle while
        // the row it decorated sat one level down. Furniture no longer counts as
        // the app having answered.
        if groundsContent(element) { return element }

        var current = element
        var deepestWithText: AXUIElement?

        for _ in 0..<maxDepth {
            if Clock.nowMs() > deadline { break }
            guard let children = childrenOf(current), !children.isEmpty else { break }

            var best: AXUIElement?
            var bestArea = Double.greatestFiniteMagnitude

            for child in children.prefix(maxChildrenPerLevel) {
                // Checked inside the scan too: one wide level can exhaust the
                // budget on its own.
                if Clock.nowMs() > deadline { break }
                guard let f = frame(of: child), f.contains(p) else { continue }
                // Smallest containing child = most specific. Overlapping
                // siblings are common in web content; area is the tiebreak.
                let area = f.width * f.height
                if area < bestArea {
                    bestArea = area
                    best = child
                }
            }

            guard let next = best else { break }
            current = next

            if groundsContent(next) {
                deepestWithText = next
                // Keep going: a text-bearing container may still have a more
                // specific text child under the cursor.
            }
        }

        return deepestWithText ?? current
    }

    private static func childrenOf(_ el: AXUIElement) -> [AXUIElement]? {
        guard let ref = copyAttr(el, kAXChildrenAttribute as String) else { return nil }
        return ref as? [AXUIElement]
    }

    /// Grid of sample points that fall INSIDE the drawn path — not merely
    /// inside its bounding box. That difference is what makes a lasso mean
    /// "these three rows" instead of "this rectangle".
    private static func gridSamples(in shape: Shape, maxSamples: Int, minStride: Double) -> [Point] {
        let b = shape.bounds
        guard b.width > 0, b.height > 0 else { return [shape.origin] }

        // Stride chosen so a large region doesn't blow the sample budget, but
        // a small one still gets dense coverage.
        let area = b.width * b.height
        let stride = max(minStride, (area / Double(maxSamples)).squareRoot())

        var points: [Point] = []
        var y = b.minY + stride / 2
        while y < b.maxY {
            var x = b.minX + stride / 2
            while x < b.maxX {
                let p = Point(x: x, y: y)
                if shape.contains(p) { points.append(p) }
                x += stride
            }
            y += stride
        }
        return points.isEmpty ? [shape.origin] : points
    }

    /// Hit-test every sample, keeping only distinct elements. CFEqual is the
    /// correct identity test for AXUIElement — pointer comparison is not, since
    /// separate copies can reference the same UI node.
    ///
    /// Descent is deliberately OFF during sampling and applied afterwards to the
    /// survivors only. Descending at every sample would multiply the most
    /// expensive operation by the sample count; doing it after dedupe pays for
    /// it once per distinct element. Each survivor keeps the sample point that
    /// found it, since descent needs a point to aim at.
    ///
    /// `budgetMs` bounds the DESCENT phase as a whole. Each `refine` carries its
    /// own 120ms deadline, so without this the worst case is the element cap
    /// times that — 4.8s for a region, and the session's stop waits on these
    /// tasks. It has never been observed (a region measures 58–67ms in total),
    /// but "never observed" is not a bound, and a pathological tree on a stop
    /// gesture is exactly when the user is watching.
    private static func collect(
        samples: [Point], maxElements: Int, descend: Bool, budgetMs: Double = 400
    ) -> [(element: AXUIElement, at: Point)] {
        var unique: [(element: AXUIElement, at: Point)] = []
        for p in samples {
            guard let el = hitTest(p, descend: false) else { continue }
            if unique.contains(where: { CFEqual($0.element, el) }) { continue }
            unique.append((el, p))
            if unique.count >= maxElements { break }
        }

        guard descend else { return unique }

        let deadline = Clock.nowMs() + budgetMs
        var refined: [(element: AXUIElement, at: Point)] = []
        for (el, p) in unique {
            // Out of time: keep the remaining elements UNREFINED rather than
            // dropping them. A container is worse grounding than its leaf, but
            // both beat a referent that silently lost half its neighbourhood.
            guard Clock.nowMs() < deadline else {
                if !refined.contains(where: { CFEqual($0.element, el) }) {
                    refined.append((el, p))
                }
                continue
            }
            let deep = refine(el, at: p)
            // Descent can collapse two containers onto the same leaf, so dedupe
            // again afterwards.
            if refined.contains(where: { CFEqual($0.element, deep) }) { continue }
            refined.append((deep, p))
        }
        return refined
    }

    // ── Describing an element (the expensive part) ───────────────────────────

    private static func describe(_ el: AXUIElement, withAncestors: Bool) -> AXElement {
        let names = attributeNames(of: el)

        // Only ask for attributes the element advertises. Every skipped read is
        // a saved IPC round-trip, which is the whole budget for region capture.
        func text(_ attr: String) -> String? {
            guard names.contains(attr) else { return nil }
            return stringify(copyAttr(el, attr))
        }

        return AXElement(
            role: stringify(copyAttr(el, kAXRoleAttribute as String)),
            subrole: stringify(copyAttr(el, kAXSubroleAttribute as String)),
            title: text(kAXTitleAttribute as String),
            value: text(kAXValueAttribute as String),
            elementDescription: text(kAXDescriptionAttribute as String),
            selectedText: text(kAXSelectedTextAttribute as String),
            frame: frame(of: el),
            ancestors: withAncestors ? ancestors(of: el, levels: 3) : [],
            attributeNames: names
        )
    }

    private static func ancestors(of el: AXUIElement, levels: Int) -> [Ancestor] {
        var result: [Ancestor] = []
        var current = el
        for _ in 0..<levels {
            guard let parentRef = copyAttr(current, kAXParentAttribute as String),
                  CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { break }
            let parent = parentRef as! AXUIElement
            result.append(
                Ancestor(
                    role: stringify(copyAttr(parent, kAXRoleAttribute as String)),
                    subrole: stringify(copyAttr(parent, kAXSubroleAttribute as String)),
                    title: stringify(copyAttr(parent, kAXTitleAttribute as String))
                )
            )
            current = parent
        }
        return result
    }

    /// The enclosing window's title — free, high-value context. For an editor it
    /// carries the active file and the workspace/repo folder; for a browser, the
    /// page; for Postman, the request.
    ///
    /// Asks the element directly via `kAXWindowAttribute` rather than walking up
    /// the parent chain. The walk used to work and then silently stopped: once
    /// hit-test descent started returning deep leaves, the window sat further
    /// than 12 levels above them and every probe came back with no title —
    /// 30 of 30 in a real session. A one-hop attribute read has no depth to be
    /// wrong about, and costs one IPC instead of twelve.
    private static func windowTitle(for el: AXUIElement) -> String? {
        for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
            guard let ref = copyAttr(el, attribute as String),
                  CFGetTypeID(ref) == AXUIElementGetTypeID() else { continue }
            let window = ref as! AXUIElement
            if let title = stringify(copyAttr(window, kAXTitleAttribute as String)) {
                return title
            }
        }

        // Fall back to the parent walk for apps that don't advertise the
        // attribute, now deep enough to survive a descended leaf.
        var current = el
        for _ in 0..<40 {
            if stringify(copyAttr(current, kAXRoleAttribute as String)) == (kAXWindowRole as String) {
                return stringify(copyAttr(current, kAXTitleAttribute as String))
            }
            guard let parentRef = copyAttr(current, kAXParentAttribute as String),
                  CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
            current = parentRef as! AXUIElement
        }
        return nil
    }

    // ── Electron bridge ─────────────────────────────────────────────────────

    /// Turn the bridge on for the frontmost app BEFORE anything is pointed at,
    /// so no referent pays the ~300ms tree-build we measured on first hit.
    ///
    /// Called at hotkey-down and on app switch during a session — never at
    /// launch, and never for apps the user isn't currently in. Poking builds an
    /// accessibility tree the app then maintains, which costs that app memory
    /// and a little CPU; doing it to every running app because we might one day
    /// be pointed at it is not ours to spend.
    @discardableResult
    static func prePokeFrontmost() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        enableManualAccessibility(pid: pid)
        return pid
    }

    /// Chromium's private opt-in. Set on the APPLICATION element, not the hit
    /// element. Returns whether we actually issued it (false if already poked).
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        pokedPidsLock.lock()
        let alreadyPoked = !pokedPids.insert(pid).inserted
        pokedPidsLock.unlock()
        if alreadyPoked { return false }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }

    /// `DeikoGrounding.groundsContent` for an already-described element.
    ///
    /// The judgement lives in its own target because it is pure and this file
    /// is not: asking the question at all needs a live accessibility tree and a
    /// running app to point at. See `Grounding.swift` for why "has any text" was
    /// the wrong test.
    static func groundsContent(_ e: AXElement) -> Bool {
        DeikoGrounding.groundsContent(
            role: e.role,
            value: e.value,
            title: e.title,
            description: e.elementDescription,
            selectedText: e.selectedText
        )
    }

    /// The same question against a live element, for the descent — five IPC
    /// reads instead of `hasText`'s three, paid only on elements we are already
    /// considering. The extra one is the role, which is the whole point: it is
    /// what separates a caret's alt text from a cell's contents.
    private static func groundsContent(_ el: AXUIElement) -> Bool {
        func read(_ attr: String) -> String? {
            stringify(copyAttr(el, attr))
        }
        return DeikoGrounding.groundsContent(
            role: read(kAXRoleAttribute as String),
            value: read(kAXValueAttribute as String),
            title: read(kAXTitleAttribute as String),
            description: read(kAXDescriptionAttribute as String),
            selectedText: read(kAXSelectedTextAttribute as String)
        )
    }

    /// Whether an element is worth putting in front of the model at all.
    /// Text is the obvious case; a control with no text still matters because
    /// "the Save button" is a real referent even when its label is an icon.
    static func carriesMeaning(_ e: AXElement) -> Bool {
        let hasText = [e.value, e.title, e.elementDescription, e.selectedText]
            .contains { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
        if hasText { return true }

        switch e.role {
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
             "AXTextField", "AXTextArea", "AXSlider", "AXLink", "AXMenuItem",
             "AXImage", "AXDisclosureTriangle":
            return true
        default:
            return false
        }
    }

    /// Heuristic for "AX answered, but told us nothing useful" — the shape of
    /// an un-bridged Electron window, which hands back a bare container with no
    /// text at all. This is what triggers the manual-accessibility retry.
    static func looksUngrounded(_ e: AXElement) -> Bool {
        let hasText = [e.value, e.title, e.elementDescription, e.selectedText]
            .contains { ($0?.isEmpty == false) }
        if hasText { return false }

        switch e.role {
        case nil, "AXUnknown", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup":
            return true
        default:
            return false
        }
    }

    // ── Low-level attribute plumbing ────────────────────────────────────────

    private static func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return err == .success ? value : nil
    }

    private static func attributeNames(of el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success,
              let names = names as? [String] else { return [] }
        return names
    }

    private static func pidOf(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return pid
    }

    private static func appIdentity(pid: pid_t) -> AppIdentity {
        let running = NSRunningApplication(processIdentifier: pid)
        return AppIdentity(
            pid: pid,
            bundleId: running?.bundleIdentifier,
            name: running?.localizedName
        )
    }

    private static func frame(of el: AXUIElement) -> Frame? {
        guard let posRef = copyAttr(el, kAXPositionAttribute as String),
              let sizeRef = copyAttr(el, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        return Frame(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// AX values arrive as several unrelated CF types. Text roles give CFString;
    /// geometry gives an opaque AXValue; checkboxes give CFNumber/CFBoolean.
    ///
    /// TWO KINDS OF CAST LIVE HERE AND THE DIFFERENCE IS THE COMPILER'S, NOT A
    /// PREFERENCE. A cast to a CoreFoundation type (`AXUIElement`, `AXValue`)
    /// cannot fail — Swift rejects `as?` on one as "will always succeed" — so
    /// those stay forced, guarded by the `CFGetTypeID` check above them. The
    /// bridged Foundation casts (`String`, `Bool`, `NSNumber`) genuinely can
    /// fail, and this runs against the accessibility tree of every third-party
    /// app on the machine, where the type ID and the bridge have been known to
    /// disagree. Those return nil rather than trapping: an attribute Deiko
    /// cannot read is a missing label, not a reason to take the app down.
    private static func stringify(_ ref: CFTypeRef?) -> String? {
        guard let ref else { return nil }

        let typeID = CFGetTypeID(ref)
        if typeID == CFStringGetTypeID() {
            guard let s = ref as? String else { return nil }
            return s.isEmpty ? nil : s
        }
        if typeID == CFBooleanGetTypeID() {
            guard let b = ref as? Bool else { return nil }
            return b ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            guard let n = ref as? NSNumber else { return nil }
            return "\(n)"
        }
        if typeID == AXValueGetTypeID() {
            let v = ref as! AXValue
            switch AXValueGetType(v) {
            case .cgPoint:
                var p = CGPoint.zero
                AXValueGetValue(v, .cgPoint, &p)
                return "(\(p.x), \(p.y))"
            case .cgSize:
                var s = CGSize.zero
                AXValueGetValue(v, .cgSize, &s)
                return "(\(s.width)×\(s.height))"
            case .cgRect:
                var r = CGRect.zero
                AXValueGetValue(v, .cgRect, &r)
                return "(\(r.origin.x), \(r.origin.y), \(r.width)×\(r.height))"
            case .cfRange:
                var range = CFRange()
                AXValueGetValue(v, .cfRange, &range)
                return "range(\(range.location), \(range.length))"
            default:
                return nil
            }
        }
        if typeID == AXUIElementGetTypeID() {
            return "<AXUIElement>"
        }
        return nil
    }
}
