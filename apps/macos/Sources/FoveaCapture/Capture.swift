import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// CROP CAPTURE — the Tier 1 base
//
// Taken for every referent, always. AX gives exact strings where it resolves;
// the crop gives everything else — layout, colour, spacing, custom-rendered
// content, and the thumbnail the review UI needs. Neither replaces the other.
//
// Coordinates in, as everywhere: top-left-origin global screen space.
// ─────────────────────────────────────────────────────────────────────────────

enum Capture {

    /// Default box around a point referent when AX gave us no usable rectangle.
    /// Wider than tall on purpose — the things developers point at (code lines,
    /// field rows, log lines, response keys) are horizontal.
    static let defaultPointSize = CGSize(width: 460, height: 220)

    /// Breathing room added around an AX element rect. A bare element frame is
    /// often a single word; the surrounding line is what makes it readable.
    static let axPadding: Double = 24

    /// An AX rect this large is a container that happens to sit under the
    /// cursor (a whole scroll area), not the thing pointed at. Fall back to the
    /// default box rather than screenshotting half the screen.
    static let maxAXRectScreenFraction: Double = 0.35

    /// How much bigger than the default box a TEXTLESS element's rect may be
    /// before we stop believing it describes what was pointed at.
    ///
    /// A text-bearing element is self-evidently the thing under the cursor, so
    /// its rect is trusted at any sane size. A textless container is not: it is
    /// just the nearest node the app was willing to answer with. Compass's
    /// `AXRow` (~1000x30) and a Chrome breadcrumb bar (932x80, 5% of screen)
    /// are worth keeping; a VS Code `AXGroup` measured 601x646 — 26% of the
    /// screen, 52 OCR lines — and that is a page, not a referent.
    static let maxTextlessRectMultiple: Double = 2.5

    // ── Choosing what to capture ────────────────────────────────────────────

    /// Region referents crop their own bounds. Point referents prefer the AX
    /// element's rectangle when it looks like a real element, and fall back to
    /// a fixed box.
    static func rect(
        for shape: Shape,
        snapshot: AXSnapshot,
        screenArea: Double
    ) -> (rect: Frame, fromAX: Bool) {
        if shape.kind == .region {
            return (padded(shape.bounds, by: 8), false)
        }

        let s = defaultPointSize

        if let element = snapshot.elements.first,
           let axFrame = element.frame,
           axFrame.width > 8, axFrame.height > 8,
           axFrame.width * axFrame.height < screenArea * maxAXRectScreenFraction,
           axFrame.contains(shape.origin) {

            // A text-bearing element IS the thing under the cursor, so trust
            // its rect at any sane size. A textless container is merely the
            // nearest node the app chose to answer with, so trust it only while
            // it stays near the default box: one VS Code `AXGroup` measured
            // 601x646 — 26% of the screen, 52 OCR lines — which is a page, not
            // a referent.
            let hasText = [
                element.value, element.title, element.elementDescription, element.selectedText
            ].contains { ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }

            if hasText
                || axFrame.width * axFrame.height <= s.width * s.height * maxTextlessRectMultiple {
                return (padded(axFrame, by: axPadding), true)
            }
        }

        return (
            Frame(
                x: shape.origin.x - s.width / 2,
                y: shape.origin.y - s.height / 2,
                width: s.width,
                height: s.height
            ),
            false
        )
    }

    private static func padded(_ f: Frame, by p: Double) -> Frame {
        Frame(x: f.x - p, y: f.y - p, width: f.width + p * 2, height: f.height + p * 2)
    }

    // ── Capturing ───────────────────────────────────────────────────────────

    /// Screenshot `rect`, optionally OCR'd, optionally written to disk.
    ///
    /// `runOCR` is passed in rather than decided here: OCR costs 50-200ms and is
    /// only worth paying when AX came back empty.
    static func crop(
        snapshot: AXSnapshot,
        outputPath: String?,
        runOCR: Bool,
        rectFromAX: Bool,
        rect: Frame
    ) async -> CropResult {
        let started = Clock.nowMs()

        guard let display = try? await display(containing: rect) else {
            return failed(rect: rect, fromAX: rectFromAX, started: started,
                          error: "no display contains the region")
        }

        let scale = backingScale(for: display.displayID)
        let clamped = clamp(rect, to: display.frameInScreenSpace)

        guard clamped.width >= 1, clamped.height >= 1 else {
            return failed(rect: rect, fromAX: rectFromAX, started: started,
                          error: "region is off-screen")
        }

        let image: CGImage
        do {
            image = try await screenshot(of: clamped, on: display, scale: scale)
        } catch {
            // Screen Recording is the likeliest cause and the message is worth
            // being specific about — it is a different permission from AX, and
            // it is granted to the launching process just the same.
            return failed(rect: clamped, fromAX: rectFromAX, started: started,
                          error: "capture failed: \(error.localizedDescription)")
        }

        let captureElapsed = Clock.nowMs() - started

        var ocrLines: [OCRLine] = []
        var ocrElapsed: Double?
        if runOCR {
            let ocrStarted = Clock.nowMs()
            ocrLines = OCR.recognize(image, in: clamped)
            ocrElapsed = Clock.nowMs() - ocrStarted
        }

        var writtenPath: String?
        var writeError: String?
        if let outputPath {
            if writePNG(image, to: outputPath) {
                writtenPath = outputPath
            } else {
                // Say so. `path: nil, error: nil` is the contract for "capture
                // ran in memory only" — a full disk or missing directory used
                // to masquerade as exactly that, and a session whose every
                // crop failed read as a legitimately crop-less recording.
                writeError = "could not write \(outputPath)"
            }
        }

        return CropResult(
            path: writtenPath,
            rect: clamped,
            rectFromAX: rectFromAX,
            ocr: ocrLines,
            captureElapsedMs: captureElapsed,
            ocrElapsedMs: ocrElapsed,
            error: writeError
        )
    }

    private static func failed(
        rect: Frame, fromAX: Bool, started: Double, error: String
    ) -> CropResult {
        CropResult(
            path: nil, rect: rect, rectFromAX: fromAX,
            ocr: [], captureElapsedMs: Clock.nowMs() - started,
            ocrElapsedMs: nil, error: error
        )
    }

    // ── ScreenCaptureKit ────────────────────────────────────────────────────

    /// Cached display list. `SCShareableContent` is a system query that costs
    /// well over 100ms, and it was being paid on every single crop — measurable
    /// as a flat ~208ms whether the region was 10×10 or 460×220, which is the
    /// signature of fixed overhead rather than work. The display layout only
    /// changes when a monitor is plugged in, so cache it and invalidate on the
    /// system's own reconfiguration signal.
    ///
    /// Locked because crops resolve on concurrent detached tasks — two early
    /// referents both missing the cache used to assign this array from two
    /// threads at once. The lock is never held across an await.
    nonisolated(unsafe) private static var cachedDisplays: [SCDisplay] = []

    /// Fovea itself, so the capture can leave our own drawing out of it.
    ///
    /// Every crop was photographing the overlay: the accent cursor ring sits on
    /// the pointer, and a region's teal capture pulse fires at the moment the
    /// lasso closes — which is exactly the moment the screenshot is taken. Both
    /// landed in the middle of the delivered image. `showsCursor = false` never
    /// covered it, because these are a real window, not the system pointer.
    ///
    /// Cached beside the displays and cleared by the same hook: it comes from
    /// the same `SCShareableContent` query, so fetching it costs nothing extra.
    nonisolated(unsafe) private static var cachedSelf: SCRunningApplication?
    private static let displayLock = NSLock()

    /// CGDisplayRegisterReconfigurationCallback fires on ANY arrangement
    /// change. Coordinate-coverage checks alone could not see a swap: two
    /// monitors trading places keeps every point covered while every cached
    /// `frameInScreenSpace` becomes wrong — and `sourceRect` computed from a
    /// stale origin crops unrelated screen content with `error: nil`.
    private static let reconfigurationHook: Void = {
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            displayLock.lock()
            cachedDisplays = []
            cachedSelf = nil
            displayLock.unlock()
        }, nil)
    }()

    /// Synchronous accessors: `NSLock` may not be taken directly in an async
    /// function, and these critical sections must never span an await anyway.
    private static func cachedDisplay(containing center: Point) -> SCDisplay? {
        displayLock.lock()
        defer { displayLock.unlock() }
        return cachedDisplays.first { $0.frameInScreenSpace.contains(center) }
    }

    private static func store(displays: [SCDisplay], selfApp: SCRunningApplication?) {
        displayLock.lock()
        defer { displayLock.unlock() }
        cachedDisplays = displays
        cachedSelf = selfApp
    }

    private static func ownApplication() -> SCRunningApplication? {
        displayLock.lock()
        defer { displayLock.unlock() }
        return cachedSelf
    }

    private static func display(containing rect: Frame) async throws -> SCDisplay {
        _ = reconfigurationHook
        let center = rect.center

        if let cached = cachedDisplay(containing: center) { return cached }

        // Cache miss: either first call, or the layout changed under us.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let me = getpid()
        store(
            displays: content.displays,
            selfApp: content.applications.first { $0.processID == me }
        )

        guard let display = content.displays.first(where: {
            $0.frameInScreenSpace.contains(center)
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return display
    }

    private static func screenshot(
        of rect: Frame, on display: SCDisplay, scale: Double
    ) async throws -> CGImage {
        // Capture ONLY the region, via sourceRect, rather than grabbing the
        // whole display and cropping. sourceRect is in points relative to the
        // display's top-left, which is the same space `rect` is already in.
        //
        // Fovea excluded from its own screenshots — by APPLICATION rather than
        // by window, which covers the overlay canvas, the capturing pill and
        // the orb together and keeps covering whatever is added next. The
        // fallback is deliberate: a crop with our ring in it is worth far more
        // than no crop, so an unresolved self reverts to the old filter rather
        // than throwing.
        let filter = ownApplication().map {
            SCContentFilter(display: display, excludingApplications: [$0], exceptingWindows: [])
        } ?? SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        let origin = display.frameInScreenSpace
        config.sourceRect = CGRect(
            x: rect.x - origin.x,
            y: rect.y - origin.y,
            width: rect.width,
            height: rect.height
        )
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            if id?.uint32Value == displayID { return Double(screen.backingScaleFactor) }
        }
        return NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
    }

    private static func clamp(_ rect: Frame, to bounds: Frame) -> Frame {
        let x = max(rect.minX, bounds.minX)
        let y = max(rect.minY, bounds.minY)
        let maxX = min(rect.maxX, bounds.maxX)
        let maxY = min(rect.maxY, bounds.maxY)
        return Frame(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    @discardableResult
    static func writePNG(_ image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    enum CaptureError: Error { case noDisplay }
}

// ─────────────────────────────────────────────────────────────────────────────

extension Frame {
    func contains(_ p: Point) -> Bool {
        minX <= p.x && p.x <= maxX && minY <= p.y && p.y <= maxY
    }
}

extension SCDisplay {
    /// SCDisplay.frame is already top-left-origin global screen space, the same
    /// space AX and CGEvent use. Named explicitly so nobody has to re-derive it.
    var frameInScreenSpace: Frame {
        Frame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }
}
