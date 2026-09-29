import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// Crop capture, taken for every referent. AX gives exact strings where it
// resolves; the crop gives layout, colour, custom-rendered content and the
// review thumbnail. Neither replaces the other. Coordinates are top-left-origin
// global screen space.

enum Capture {

    /// Default box around a point referent when AX gave no usable rectangle.
    /// Wider than tall on purpose: the things developers point at (code lines,
    /// field rows, log lines, response keys) are horizontal.
    static let defaultPointSize = CGSize(width: 460, height: 220)

    /// Breathing room added around an AX element rect. A bare element frame is
    /// often a single word; the surrounding line is what makes it readable.
    static let axPadding: Double = 24

    /// An AX rect this large is a container that happens to sit under the
    /// cursor (a whole scroll area), not the thing pointed at. Fall back to the
    /// default box rather than screenshotting half the screen.
    static let maxAXRectScreenFraction: Double = 0.35

    /// How much bigger than the default box a textless element's rect may be
    /// before it stops being trusted as what was pointed at. A text-bearing
    /// element is self-evidently the thing under the cursor; a textless container
    /// is just the nearest node the app answered with.
    static let maxTextlessRectMultiple: Double = 2.5

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

            // A text-bearing element is the thing under the cursor, so its rect
            // is trusted at any sane size. A textless container is merely the
            // nearest node the app answered with, so it is trusted only while it
            // stays near the default box.
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

    static func padded(_ f: Frame, by p: Double) -> Frame {
        Frame(x: f.x - p, y: f.y - p, width: f.width + p * 2, height: f.height + p * 2)
    }

    /// A mark's crop extent: the stroke's bounds unioned with the guarded AX
    /// frame at each anchor locus. The raw stroke bbox is not enough, since a
    /// sweep from box A to box B bounds only the line between them.
    /// `Capture.rect` supplies the guards and the default-box floor.
    static func markRect(
        strokeBounds: Frame,
        loci: [(point: Point, snapshot: AXSnapshot)],
        screenArea: Double
    ) -> Frame {
        var rect = padded(strokeBounds, by: 8)
        for locus in loci {
            let (r, _) = Capture.rect(
                for: Shape.point(locus.point),
                snapshot: locus.snapshot,
                screenArea: screenArea
            )
            rect = rect.union(r)
        }
        return rect
    }

    /// Screenshot `rect`, optionally OCR'd, optionally written to disk.
    ///
    /// `runOCR` is passed in rather than decided here: OCR costs 50-200ms and
    /// only pays off when AX came back empty.
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
            // Screen Recording is the likeliest cause; it is a separate
            // permission from AX.
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
                // Say so: `path: nil, error: nil` means the capture ran in
                // memory only, and a full disk must not masquerade as that.
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

    /// Cached display list: `SCShareableContent` is a system query costing
    /// 100ms or more, and the layout only changes when a monitor is plugged in.
    /// Invalidated on the system's reconfiguration signal.
    ///
    /// Locked because crops resolve on concurrent detached tasks. The lock is
    /// never held across an await.
    nonisolated(unsafe) private static var cachedDisplays: [SCDisplay] = []

    /// Deiko itself, so the capture can leave its own drawing (cursor ring,
    /// capture pulse) out of the image. `showsCursor = false` does not cover
    /// these: they are real windows.
    ///
    /// Cached beside the displays and cleared by the same hook; it comes from the
    /// same `SCShareableContent` query.
    nonisolated(unsafe) private static var cachedSelf: SCRunningApplication?
    private static let displayLock = NSLock()

    /// `CGDisplayRegisterReconfigurationCallback` fires on any arrangement
    /// change. Coordinate checks alone cannot see two monitors swapping places,
    /// which leaves every cached `frameInScreenSpace` wrong and `sourceRect`
    /// cropping unrelated screen content.
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
        // A warm display cache is not enough on its own: `cachedSelf` comes
        // from the same query, and if the first one missed Deiko the cache would
        // short-circuit every later attempt. So the first miss on `cachedSelf`
        // refuses the hit and pays for one more query. Once (`selfLookupTried`),
        // not on every crop.
        guard cachedSelf != nil || selfLookupTried else { return nil }
        return cachedDisplays.first { $0.frameInScreenSpace.contains(center) }
    }

    /// Whether the self-lookup has been attempted at all. See `cachedDisplay`.
    nonisolated(unsafe) private static var selfLookupTried = false

    private static func store(displays: [SCDisplay], selfApp: SCRunningApplication?) {
        displayLock.lock()
        defer { displayLock.unlock() }
        cachedDisplays = displays
        selfLookupTried = true
        // Never overwrite a good answer with nil: one query that misses us
        // would pin `cachedSelf` to nil and put the overlay back in every crop.
        if let selfApp { cachedSelf = selfApp }
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

        // Cache miss: either first call, or the layout changed since.
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
        // Capture only the region via sourceRect (points relative to the
        // display's top-left, the space `rect` is already in) rather than the
        // whole display.
        //
        // Deiko is excluded by application rather than by window, which covers
        // the overlay canvas, capturing pill and orb together. If self is
        // unresolved, fall back to the plain filter: a crop with the ring in it
        // beats no crop.
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
