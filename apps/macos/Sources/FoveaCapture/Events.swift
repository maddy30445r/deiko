import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE WIRE CONTRACT
//
// Everything the Swift capture binary emits crosses into TypeScript as one JSON
// object per line (JSON Lines) on stdout. `packages/protocol` mirrors these
// types. Change a field here and you change it there — that is the whole reason
// they live in one small file.
//
// Three rules the rest of the system depends on:
//
//   1. Every event carries `t`: milliseconds on a MONOTONIC clock shared by the
//      cursor sampler, the audio recorder, and the crop writer. Wall-clock time
//      is recorded exactly once (`Clock.epochWall`) so a session can be dated,
//      but it is never used to relate two streams to each other.
//
//   2. stdout is data only. Human-readable logging goes to stderr, always.
//
//   3. A referent is a SHAPE, not a position. Pointing at a pixel and circling
//      an area are the same act at different granularity, so they share one
//      event type and differ only in `shape`. Everything downstream — referent
//      stack, alignment, plan generation — sees one kind of thing.
// ─────────────────────────────────────────────────────────────────────────────

/// Monotonic session clock. `DispatchTime.uptimeNanoseconds` is backed by
/// `mach_absolute_time`, so it never jumps when NTP corrects the wall clock or
/// when the user crosses a timezone mid-session.
enum Clock {
    /// Captured at process start; every `nowMs()` is relative to this.
    static let origin = DispatchTime.now().uptimeNanoseconds
    static let epochWall = Date()

    /// Force the lazy statics to initialise now. Call once at process start.
    static func bootstrap() {
        _ = origin
        _ = epochWall
    }

    static func nowMs() -> Double {
        // `origin` is read into a local FIRST, deliberately. It is a lazy
        // `static let`, so writing `DispatchTime.now().uptimeNanoseconds &- origin`
        // evaluates the left operand before the right one initialises the
        // static — making origin LATER than now, and `&-` wraps to ~1.8e19.
        let start = origin
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- start) / 1_000_000.0
    }
}

enum EventType: String, Codable {
    case hello
    case probe
    case error
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometry
//
// All coordinates are TOP-LEFT-ORIGIN global screen coordinates — the space the
// Accessibility API speaks, and the space `CGEvent.location` reports the cursor
// in. We never convert from Cocoa's bottom-left space, because a wrong flip
// hit-tests a mirrored point and still returns *an* element, which fails
// silently and costs a day.
// ─────────────────────────────────────────────────────────────────────────────

struct Point: Codable {
    let x: Double
    let y: Double
}

struct Frame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    var center: Point { Point(x: x + width / 2, y: y + height / 2) }

    /// Reading order: top-to-bottom, then left-to-right, with a row tolerance so
    /// that cells on the same visual line don't get shuffled by a pixel or two
    /// of vertical jitter. Used to order the elements inside a region so the
    /// assembled text reads the way a human would read it.
    static func readingOrder(_ a: Frame, _ b: Frame, rowTolerance: Double = 8) -> Bool {
        if abs(a.minY - b.minY) > rowTolerance { return a.minY < b.minY }
        return a.minX < b.minX
    }
}

/// What the user indicated. A point is a cursor settle; a region is a freehand
/// path drawn while the hotkey is held.
enum ShapeKind: String, Codable {
    case point
    case region
}

/// The indicated area. `path` is the raw freehand polygon in screen coords
/// (absent for points). `bounds` is its bounding box — what gets cropped — and
/// the path is retained so the crop can be masked to the exact drawn area
/// rather than the rectangle containing it.
struct Shape: Codable {
    let kind: ShapeKind
    let origin: Point
    let bounds: Frame
    let path: [Point]?

    static func point(_ p: Point) -> Shape {
        Shape(
            kind: .point,
            origin: p,
            bounds: Frame(x: p.x, y: p.y, width: 0, height: 0),
            path: nil
        )
    }

    static func region(path: [Point]) -> Shape {
        let xs = path.map(\.x)
        let ys = path.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let bounds = Frame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return Shape(kind: .region, origin: bounds.center, bounds: bounds, path: path)
    }

    /// Even-odd point-in-polygon test. Used to reject grid samples that fall in
    /// the bounding box but outside the drawn loop — the difference between
    /// "what you circled" and "the rectangle around what you circled".
    func contains(_ p: Point) -> Bool {
        guard kind == .region, let path, path.count >= 3 else {
            return bounds.minX <= p.x && p.x <= bounds.maxX
                && bounds.minY <= p.y && p.y <= bounds.maxY
        }
        var inside = false
        var j = path.count - 1
        for i in 0..<path.count {
            let a = path[i], b = path[j]
            if (a.y > p.y) != (b.y > p.y) {
                let denom = b.y - a.y
                if denom != 0, p.x < (b.x - a.x) * (p.y - a.y) / denom + a.x {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Accessibility payloads
// ─────────────────────────────────────────────────────────────────────────────

/// Which app owns the element. The referent stack needs this to resolve "that
/// key we showed earlier" — an element is meaningless without knowing which app
/// and window it lived in.
struct AppIdentity: Codable {
    let pid: Int32
    let bundleId: String?
    let name: String?
}

/// One rung of the ancestor chain. A leaf `AXStaticText` reading "pending" is
/// useless alone; its parents are what tell you it was a cell in the "bookings"
/// collection view.
struct Ancestor: Codable {
    let role: String?
    let subrole: String?
    let title: String?
}

/// One resolved UI element. Values are COPIED, never a live `AXUIElement` —
/// handles go stale within milliseconds, and a referent has to outlive the
/// session it was captured in.
struct AXElement: Codable {
    let role: String?
    let subrole: String?
    let title: String?
    /// `kAXValueAttribute` stringified — the text content for most text roles.
    let value: String?
    let elementDescription: String?
    let selectedText: String?
    let frame: Frame?

    /// Up to 3 levels of parent, nearest first.
    let ancestors: [Ancestor]

    /// Every attribute name this element exposes. The most useful field in the
    /// spike: it shows what an app actually offers versus what we thought to
    /// ask for, and it is how per-app quirks get discovered.
    let attributeNames: [String]
}

/// The result of resolving whatever occupies a shape.
struct AXSnapshot: Codable {
    /// True when AX handed back any element at all. False is the interesting
    /// case — it is the Electron failure this spike exists to measure.
    let resolved: Bool

    /// For a point: the single element hit, with ancestors.
    /// For a region: every unique element inside the drawn path, in reading
    /// order. Empty when nothing resolved.
    let elements: [AXElement]

    /// Region only: how many grid samples were hit-tested, and how many
    /// distinct elements they collapsed into. The ratio IS the granularity
    /// measurement — 60 samples → 1 element means the tree is too coarse to
    /// ground a region, even though AX technically "works" in that app.
    let samplesTested: Int?
    let uniqueElements: Int?

    /// True when elements only appeared after we set `AXManualAccessibility` on
    /// the owning app. Distinguishing "works" from "works once poked" is the
    /// finding that decides whether the AX-grounding pitch survives.
    let manualAccessibilityApplied: Bool

    /// Wall time spent inside AX calls. Every attribute read is a Mach IPC
    /// round-trip, so this is the number that tells us whether region capture
    /// fits the latency budget.
    let elapsedMs: Double

    let error: String?
}

// ─────────────────────────────────────────────────────────────────────────────
// Crop + OCR — the Tier 1 base
//
// The crop is taken for EVERY referent, not as a fallback. Three reasons it is
// never optional: the review UI shows a thumbnail per plan step; the highest
// frequency use case (frontend visual loop) is entirely about how something
// LOOKS, which no accessibility tree can express; and it is local and cheap.
//
// OCR is the conditional half — it runs only when AX returned no usable text,
// because Vision costs 50-200ms and AX text is exact where it exists.
// ─────────────────────────────────────────────────────────────────────────────

/// One line of recognised text, positioned in global screen coordinates so it
/// can be related to the shape and to AX element frames — not dumped as a blob.
struct OCRLine: Codable {
    let text: String
    let confidence: Double
    let frame: Frame
}

struct CropResult: Codable {
    /// Where the PNG was written. Nil when capture ran in memory only.
    let path: String?
    /// The region actually captured, in global screen coordinates.
    let rect: Frame
    /// True when the image was clipped to the freehand path rather than left as
    /// the bounding rectangle.
    let masked: Bool
    /// Backing scale of the display it came from (2.0 on Retina).
    let scale: Double
    /// Whether `rect` came from an AX element frame rather than a default box.
    /// This is where a "failed" AX hit still pays: Compass gives no text but it
    /// does give the row's rectangle, which is a far better crop than a fixed
    /// box around the cursor.
    let rectFromAX: Bool
    let ocr: [OCRLine]
    let captureElapsedMs: Double
    let ocrElapsedMs: Double?
    let error: String?
}

/// One probe of one shape, with its context. This is the raw material of a
/// referent — T1.3 will wrap it, not replace it.
struct ProbeEvent: Codable {
    let type: EventType
    let t: Double
    let shape: Shape
    let app: AppIdentity?
    let windowTitle: String?
    let snapshot: AXSnapshot
    let crop: CropResult?

    init(
        shape: Shape,
        app: AppIdentity?,
        windowTitle: String?,
        snapshot: AXSnapshot,
        crop: CropResult? = nil
    ) {
        self.init(
            t: Clock.nowMs(),
            shape: shape,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop
        )
    }

    private init(
        t: Double,
        shape: Shape,
        app: AppIdentity?,
        windowTitle: String?,
        snapshot: AXSnapshot,
        crop: CropResult?
    ) {
        self.type = .probe
        self.t = t
        self.shape = shape
        self.app = app
        self.windowTitle = windowTitle
        self.snapshot = snapshot
        self.crop = crop
    }

    /// Attach a crop to an already-built probe. Capture is async and AX is not,
    /// so the two are produced in separate steps and joined here.
    ///
    /// `t` is carried over deliberately: it must stay the moment the user
    /// POINTED, not the moment the screenshot finished. Re-stamping it here
    /// would shift every referent later by the capture duration and quietly
    /// corrupt the alignment measurement.
    func with(crop: CropResult?) -> ProbeEvent {
        ProbeEvent(
            t: t,
            shape: shape,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop
        )
    }
}

struct HelloEvent: Codable {
    let type: EventType
    let t: Double
    let binary: String
    let version: String
    let pid: Int32
    let epochWall: String
    /// Whether this process is trusted for Accessibility. Node checks this to
    /// tell the user to grant permission before anything else can work.
    let axTrusted: Bool

    init(axTrusted: Bool) {
        self.type = .hello
        self.t = Clock.nowMs()
        self.binary = "fovea-capture"
        self.version = FoveaVersion.current
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.epochWall = ISO8601DateFormatter().string(from: Clock.epochWall)
        self.axTrusted = axTrusted
    }
}

struct ErrorEvent: Codable {
    let type: EventType
    let t: Double
    let message: String
    let hint: String?

    init(_ message: String, hint: String? = nil) {
        self.type = .error
        self.t = Clock.nowMs()
        self.message = message
        self.hint = hint
    }
}

enum FoveaVersion {
    static let current = "0.0.1"
}

// ─────────────────────────────────────────────────────────────────────────────
// Emission
// ─────────────────────────────────────────────────────────────────────────────

enum Emit {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // No .prettyPrinted: one event must be exactly one line.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// One JSON object, one line, on stdout — flushed immediately so a Node
    /// parent reading line-by-line sees events live rather than all at exit.
    static func event<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else {
            log("failed to encode event")
            return
        }
        print(line)
        fflush(stdout)
    }

    /// Human-facing output. stderr only — stdout is reserved for the contract.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
