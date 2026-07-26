import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
    nonisolated(unsafe) private static var pokedPids: Set<pid_t> = []

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
    static func probePoint(_ p: Point, allowManualRetry: Bool = true) -> ProbeEvent {
        let started = Clock.nowMs()
        let shape = Shape.point(p)

        guard var hit = hitTest(p) else {
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
                if let retry = hitTest(p) {
                    hit = retry
                    pid = pidOf(hit) ?? ownerPid
                    element = describe(hit, withAncestors: true)
                }
            }
        }

        return ProbeEvent(
            shape: shape,
            app: pid.map(appIdentity(pid:)),
            windowTitle: windowTitle(for: hit),
            snapshot: AXSnapshot(
                resolved: true,
                elements: [element],
                samplesTested: nil,
                uniqueElements: nil,
                manualAccessibilityApplied: poked,
                elapsedMs: Clock.nowMs() - started,
                error: nil
            )
        )
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
        allowManualRetry: Bool = true
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

        var hits = collect(samples: samples, maxElements: maxElements)

        // Same Electron bridge as the point path. We judge "ungrounded" on a
        // cheap describe of the first hit rather than the whole set, so we
        // don't pay for full attribute reads before deciding to retry.
        var poked = false
        let firstPid = hits.first.flatMap { pidOf($0) }
        if allowManualRetry,
           let firstPid,
           hits.count <= 1 || looksUngrounded(describe(hits[0], withAncestors: false)) {
            poked = enableManualAccessibility(pid: firstPid)
            if poked {
                usleep(300_000)
                samples = gridSamples(in: shape, maxSamples: maxSamples, minStride: minStride)
                hits = collect(samples: samples, maxElements: maxElements)
            }
        }

        let elements = hits
            .map { describe($0, withAncestors: false) }
            .sorted { a, b in
                guard let fa = a.frame, let fb = b.frame else { return a.frame != nil }
                return Frame.readingOrder(fa, fb)
            }

        let pid = hits.first.flatMap { pidOf($0) }
        return ProbeEvent(
            shape: shape,
            app: pid.map(appIdentity(pid:)),
            windowTitle: hits.first.flatMap { windowTitle(for: $0) },
            snapshot: AXSnapshot(
                resolved: !elements.isEmpty,
                elements: elements,
                samplesTested: samples.count,
                uniqueElements: elements.count,
                manualAccessibilityApplied: poked,
                elapsedMs: Clock.nowMs() - started,
                error: elements.isEmpty ? "no elements resolved in region" : nil
            )
        )
    }

    // ── Hit-testing ─────────────────────────────────────────────────────────

    private static func hitTest(_ p: Point) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(p.x), Float(p.y), &element
        )
        guard err == .success, let element else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
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
    private static func collect(samples: [Point], maxElements: Int) -> [AXUIElement] {
        var unique: [AXUIElement] = []
        for p in samples {
            guard let el = hitTest(p) else { continue }
            if unique.contains(where: { CFEqual($0, el) }) { continue }
            unique.append(el)
            if unique.count >= maxElements { break }
        }
        return unique
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

    /// Walks up to the enclosing window. Done from the hit element rather than
    /// via the app's focused window, because the element we pointed at may not
    /// live in the focused window at all.
    private static func windowTitle(for el: AXUIElement) -> String? {
        var current = el
        for _ in 0..<12 {
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

    /// Chromium's private opt-in. Set on the APPLICATION element, not the hit
    /// element. Returns whether we actually issued it (false if already poked).
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        if pokedPids.contains(pid) { return false }
        pokedPids.insert(pid)

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
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
    private static func stringify(_ ref: CFTypeRef?) -> String? {
        guard let ref else { return nil }

        let typeID = CFGetTypeID(ref)
        if typeID == CFStringGetTypeID() {
            let s = ref as! String
            return s.isEmpty ? nil : s
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            return "\(ref as! NSNumber)"
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
