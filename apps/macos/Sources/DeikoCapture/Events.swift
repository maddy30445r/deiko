import AppKit
import DeikoHandoff
import Foundation

// The wire contract. Everything the Swift capture binary emits crosses into
// TypeScript as one JSON object per line (JSON Lines) on stdout. This file is
// the contract; there is no mirrored copy on the other side.
//
// Rules the rest of the system depends on:
//
//   1. Every event carries `t`: milliseconds on a monotonic clock shared by the
//      cursor sampler, the audio recorder and the crop writer. Wall-clock time
//      is recorded once (`Clock.epochWall`) so a session can be dated, but it is
//      never used to relate two streams to each other.
//
//   2. stdout is data only. Human-readable logging goes to stderr.
//
//   3. A referent is a shape, not a position. Pointing at a pixel and circling
//      an area are the same act at different granularity, so they share one
//      event type and differ only in `shape`.

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
        // Read `origin` into a local first. It is a lazy `static let`, so
        // `DispatchTime.now().uptimeNanoseconds &- origin` would evaluate the
        // left operand before the right initialises the static, making origin
        // later than now, and `&-` wraps to ~1.8e19.
        let start = origin
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- start) / 1_000_000.0
    }
}

enum EventType: String, Codable {
    case hello
    case probe
    case error
    /// The whole recording — opened by the first hold, closed by "Stop session".
    case sessionStart
    case sessionEnd
    /// One press-and-release of the hotkey. A session contains many.
    case holdStart
    case holdEnd
    case cursor
    case candidate
    /// One throw of the coin, with how it came out. See `FlingReport`.
    case fling
}

// MARK: - Candidates

/// Every cursor settle is logged as a candidate and never filtered at capture
/// time. Cursor data alone cannot tell a pointing act from a resting hand, but
/// cursor data plus narration can, so the recorder over-captures and records the
/// features the alignment engine judges later. A candidate that never binds to
/// speech never becomes a referent.
struct CandidateFeatures: Codable {
    /// How long the cursor stayed put. Longer reads as more deliberate.
    let dwellMs: Double

    /// Speed over the 200ms before the stop, px/s. A deceleration INTO the stop
    /// is a deliberate point; a slow drift that pauses is transit.
    let approachSpeed: Double

    /// Time since the frontmost app changed. The first settle after a switch is
    /// usually the cursor arriving, not pointing.
    let msSinceAppSwitch: Double?

    /// Time since the last scroll. A settle while content moves underneath is
    /// not a new pointing act — the cursor never moved, the page did.
    let msSinceScroll: Double?

    /// Time since speech was last heard. Nil when there is no audio at all.
    ///
    /// The strongest of the four, and the only one that says anything about
    /// intent: a cursor that stops while somebody is talking is almost always
    /// pointing at what they are talking about. It also gates capture: a settle
    /// further than a few seconds from any speech is never recorded.
    let msSinceVoice: Double?
}

struct CandidateEvent: Codable {
    let type: EventType
    let t: Double
    let position: Point
    let features: CandidateFeatures
    let app: AppIdentity?

    init(position: Point, features: CandidateFeatures, app: AppIdentity?) {
        self.type = .candidate
        self.t = Clock.nowMs()
        self.position = position
        self.features = features
        self.app = app
    }
}

/// Raw cursor sample, kept at full rate so the aligner can re-derive settles
/// with different thresholds without re-recording the session.
struct CursorEvent: Codable {
    let type: EventType
    let t: Double
    let x: Double
    let y: Double

    init(_ p: Point) {
        self.type = .cursor
        self.t = Clock.nowMs()
        self.x = p.x
        self.y = p.y
    }
}

// MARK: - Sessions and holds
//
// Two nested levels, and keeping them apart matters:
//
//   HOLD    one press-and-release of the hotkey. One utterance, one WAV, its own
//           `audioT0`. Word timings are offsets from that hold's t0, which is
//           why per-hold audio files exist.
//
//   SESSION everything from the first hold until "Stop session": one directory,
//           one referent stack, one plan. It is the unit the user thinks in.

/// One press-and-release of the hotkey.
struct HoldEvent: Codable {
    let type: EventType
    let t: Double
    let id: String
    /// Which hold of the hotkey this is, 1-based. The natural grouping for the
    /// referent stack, and part of every crop filename.
    let hold: Int
    let referentCount: Int?
    /// Where the narration was written.
    let audioPath: String?
    /// `Clock.nowMs()` at the first captured audio buffer. Every word timestamp
    /// the ASR returns is an offset from this, not from `t`: the mic takes a few
    /// milliseconds to start delivering, and that gap would become a constant
    /// skew in every binding.
    let audioT0: Double?

    static func start(id: String, hold: Int, audioPath: String?) -> HoldEvent {
        HoldEvent(
            type: .holdStart, t: Clock.nowMs(), id: id, hold: hold,
            referentCount: nil, audioPath: audioPath, audioT0: nil
        )
    }

    static func end(
        id: String, hold: Int, referentCount: Int, audioT0: Double?
    ) -> HoldEvent {
        HoldEvent(
            type: .holdEnd, t: Clock.nowMs(), id: id, hold: hold,
            referentCount: referentCount,
            audioPath: nil, audioT0: audioT0
        )
    }
}

/// The recording as a whole. Exactly one `sessionStart` and one `sessionEnd`
/// per `events.jsonl`, first line and last. `epochWall` on the start is the
/// session's ONE wall-clock reading — everything else stays monotonic.
struct SessionEvent: Codable {
    let type: EventType
    let t: Double
    let id: String
    let epochWall: String?
    /// Totals across every hold, present only on `sessionEnd`.
    let holdCount: Int?
    let referentCount: Int?

    static func start(id: String) -> SessionEvent {
        SessionEvent(
            type: .sessionStart, t: Clock.nowMs(), id: id,
            epochWall: ISO8601DateFormatter().string(from: Date()),
            holdCount: nil, referentCount: nil
        )
    }

    static func end(id: String, holdCount: Int, referentCount: Int) -> SessionEvent {
        SessionEvent(
            type: .sessionEnd, t: Clock.nowMs(), id: id,
            epochWall: nil, holdCount: holdCount, referentCount: referentCount
        )
    }
}

// MARK: - Geometry

/// All geometry is in top-left-origin global screen coordinates: the space the
/// Accessibility API speaks and `CGEvent.location` reports. Never convert from
/// Cocoa's bottom-left space; a wrong flip hit-tests a mirrored point and still
/// returns an element, which fails silently.
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
    /// cells on the same visual line are not shuffled by a pixel or two of
    /// vertical jitter.
    static func readingOrder(_ a: Frame, _ b: Frame, rowTolerance: Double = 8) -> Bool {
        if abs(a.minY - b.minY) > rowTolerance { return a.minY < b.minY }
        return a.minX < b.minX
    }

    /// Smallest frame containing both. Used to grow a mark's crop from the
    /// stroke's own bounds to include what sits at its anchor points.
    func union(_ other: Frame) -> Frame {
        let minX = min(self.minX, other.minX)
        let minY = min(self.minY, other.minY)
        return Frame(
            x: minX, y: minY,
            width: max(self.maxX, other.maxX) - minX,
            height: max(self.maxY, other.maxY) - minY
        )
    }
}

/// What the user indicated. A point is a cursor settle; a region is a freehand
/// path drawn while the hotkey is held.
enum ShapeKind: String, Codable {
    case point
    case region
}

/// Which gesture drew a mark, and its badge number. Present only on referents
/// minted by a modifier stroke; a plain settle carries nil. `kind` is
/// `StrokeKind.rawValue` (point/lasso/connector/trace/emphasis), a string on the
/// wire so non-Swift readers need no enum.
struct MarkInfo: Codable {
    let kind: String
    let number: Int
}

/// The indicated area. `path` is the raw freehand polygon in screen coords
/// (absent for points). `bounds` is its bounding box, which is what gets
/// cropped.
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

// MARK: - Accessibility payloads

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

    /// Every attribute name this element exposes. Shows what an app actually
    /// offers, and is how per-app quirks get discovered.
    let attributeNames: [String]

    /// Web content only: the element's DOM `id` and classes, as Chrome
    /// exposes them (`AXDOMIdentifier`, `AXDOMClassList`). Labels for filing
    /// ("the chart card"); nil everywhere else.
    var domIdentifier: String? = nil
    var domClassList: [String]? = nil
}

/// The result of resolving whatever occupies a shape.
struct AXSnapshot: Codable {
    /// True when AX handed back any element at all. False marks an app whose
    /// tree is empty (typically Electron).
    let resolved: Bool

    /// For a point: the single element hit, with ancestors.
    /// For a region: every unique element inside the drawn path, in reading
    /// order. Empty when nothing resolved.
    let elements: [AXElement]

    /// Region only: how many grid samples were hit-tested, and how many
    /// distinct elements they collapsed into. The ratio is the granularity
    /// measure: 60 samples → 1 element means the tree is too coarse to ground a
    /// region.
    let samplesTested: Int?
    let uniqueElements: Int?

    /// True when elements only appeared after `AXManualAccessibility` was set
    /// on the owning app: the difference between "works" and "works once
    /// poked".
    let manualAccessibilityApplied: Bool

    /// Wall time spent inside AX calls. Every attribute read is a Mach IPC
    /// round-trip.
    let elapsedMs: Double

    let error: String?
}

// MARK: - Crop and OCR

// The crop is taken for every referent, not as a fallback: the review UI shows a
// thumbnail per step, how something looks is something no accessibility tree can
// express, and it is local and cheap. OCR is the conditional half: it runs only
// when AX returned no usable text, because Vision costs 50-200ms and AX text is
// exact where it exists.

/// One line of recognised text, positioned in global screen coordinates so it
/// can be related to the shape and to AX element frames.
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
    /// Whether `rect` came from an AX element frame rather than a default box.
    /// A failed AX text hit still pays here: the element's rectangle is a far
    /// better crop than a fixed box around the cursor.
    let rectFromAX: Bool
    let ocr: [OCRLine]
    let captureElapsedMs: Double
    let ocrElapsedMs: Double?
    let error: String?
}

/// One probe of one shape, with its context. The raw material of a referent.
struct ProbeEvent: Codable {
    let type: EventType
    let t: Double
    let shape: Shape
    /// For regions: when the drag actually began and ended, on the session
    /// clock. The recorder knows this (it saw `drawKeyDown`); reconstructing it
    /// from frozen cursor samples cannot tell "cursor frozen mid-drag" from
    /// "cursor parked here before pressing". Nil for plain settles; a marked tap
    /// carries the measured stroke interval too.
    let span: TimeSpan?
    let app: AppIdentity?
    let windowTitle: String?
    let snapshot: AXSnapshot
    let crop: CropResult?
    /// Present only for modifier-stroke referents. See MarkInfo.
    let mark: MarkInfo?
    /// Connector/trace only: what the stroke STARTED on. The main `snapshot`
    /// is the release end — the more deliberate of the two.
    let startSnapshot: AXSnapshot?

    /// Host and path of the page under the pointer — see `PageURL.trim`,
    /// which drops the query — and the window's open document. Labels for
    /// filing; nil when the app offers neither.
    let pageURL: String?
    let document: String?

    init(
        shape: Shape,
        app: AppIdentity?,
        windowTitle: String?,
        snapshot: AXSnapshot,
        crop: CropResult? = nil,
        mark: MarkInfo? = nil,
        startSnapshot: AXSnapshot? = nil,
        pageURL: String? = nil,
        document: String? = nil
    ) {
        self.init(
            t: Clock.nowMs(),
            shape: shape,
            span: nil,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop,
            mark: mark,
            startSnapshot: startSnapshot,
            pageURL: pageURL,
            document: document
        )
    }

    private init(
        t: Double,
        shape: Shape,
        span: TimeSpan?,
        app: AppIdentity?,
        windowTitle: String?,
        snapshot: AXSnapshot,
        crop: CropResult?,
        mark: MarkInfo? = nil,
        startSnapshot: AXSnapshot? = nil,
        pageURL: String? = nil,
        document: String? = nil
    ) {
        self.type = .probe
        self.t = t
        self.shape = shape
        self.span = span
        self.app = app
        self.windowTitle = windowTitle
        self.snapshot = snapshot
        self.crop = crop
        self.mark = mark
        self.startSnapshot = startSnapshot
        self.pageURL = pageURL
        self.document = document
    }

    /// Attach a crop to an already-built probe. Capture is async and AX is not,
    /// so the two are produced in separate steps and joined here.
    ///
    /// `t` is carried over deliberately: it must stay the moment the user
    /// pointed, not the moment the screenshot finished, or every referent shifts
    /// later by the capture duration and corrupts alignment.
    func with(crop: CropResult?) -> ProbeEvent {
        ProbeEvent(
            t: t,
            shape: shape,
            span: span,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop,
            mark: mark,
            startSnapshot: startSnapshot,
            pageURL: pageURL,
            document: document
        )
    }

    /// Attach the drag span the recorder measured. Same t-preservation rule.
    func with(span: TimeSpan) -> ProbeEvent {
        ProbeEvent(
            t: t,
            shape: shape,
            span: span,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop,
            mark: mark,
            startSnapshot: startSnapshot,
            pageURL: pageURL,
            document: document
        )
    }
}

/// An interval on the session clock, in milliseconds.
struct TimeSpan: Codable {
    let start: Double
    let end: Double
}

/// One line per fling, carrying the outcome rather than narrating the attempt,
/// so success rate and failure reasons can be answered with grep. The prose
/// trace remains for diagnosis.
struct FlingEvent: Codable {
    let type: EventType
    let t: Double
    let report: FlingReport

    init(_ report: FlingReport) {
        self.type = .fling
        self.t = Clock.nowMs()
        self.report = report
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
        self.binary = "deiko-capture"
        self.version = DeikoVersion.current
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

enum DeikoVersion {
    /// Read from the bundle rather than hardcoded, so the product has one
    /// version and it is the one macOS shows. `VERSION` at the repo root is the
    /// source; `make bundle` stamps it into `CFBundleShortVersionString`.
    ///
    /// The fallback covers the SwiftPM binary run straight out of `.build`, which
    /// has no bundle to read.
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0-dev"

    /// The build, for telling two shipped copies of the same version apart.
    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}

// MARK: - Emission

enum Emit {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // No .prettyPrinted: one event must be exactly one line.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// An `ErrorEvent` that also reaches the person it is about.
    ///
    /// `Emit.event(ErrorEvent)` writes a line to `launch.jsonl` that nobody
    /// reads, which is right for diagnostics. Failures that leave the app looking
    /// healthy while ignoring the user (no session directory, no hotkey monitor,
    /// no microphone) must also say why, so this shows the hint, which is already
    /// the fix in the user's words.
    static func problem(_ message: String, hint: String) {
        event(ErrorEvent(message, hint: hint))
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Deiko can't start a session"
            alert.informativeText = hint
            alert.addButton(withTitle: "OK")
            // In front: this fires while somebody is in another app, and an
            // accessory app's alert otherwise opens behind it.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// One JSON object, one line, on stdout — flushed immediately so a Node
    /// parent reading line-by-line sees events live rather than all at exit.
    static func event<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else {
            log("failed to encode event")
            return
        }
        // Locked: crop resolution runs on detached tasks, so two multi-KB
        // ProbeEvents can hit this concurrently, and concurrently with
        // `redirectToFile` swinging the handle on the main actor. Without the
        // lock, lines interleave mid-JSON (the loaders silently drop unparseable
        // lines) or a write lands on a closed descriptor.
        sinkLock.lock()
        defer { sinkLock.unlock() }
        if let sink {
            sink.write(Data("\(line)\n".utf8))
        } else {
            print(line)
            fflush(stdout)
        }
    }

    /// Human-facing output. Goes to the same sink as `event()` when one is set,
    /// and to stderr otherwise: a Finder-launched app has no stderr, so the
    /// menu-bar app's logs would otherwise go nowhere.
    ///
    /// Wrapped as JSON so a line of prose cannot break a reader parsing the file
    /// as JSON Lines; the same file carries both.
    static func log(_ message: String) {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        guard let sink else {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return
        }
        let line = (try? encoder.encode(LogLine(message: message)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"type":"log","message":"<unencodable>"}"#
        sink.write(Data("\(line)\n".utf8))
    }

    private struct LogLine: Encodable {
        let type = "log"
        let t = Date().timeIntervalSince1970
        let message: String
    }

    /// Send events to a file instead of stdout. An app launched from Finder has
    /// no terminal, so the JSON Lines stream needs somewhere to go; redirecting
    /// keeps `event()` a one-argument call everywhere.
    ///
    /// Called more than once per process: the menu-bar app opens on a
    /// diagnostics log, swings to the session's `events.jsonl` when a session
    /// starts, and swings back when it stops. The previous handle is closed:
    /// dropping it open leaks a descriptor per session and leaves the last
    /// writes unflushed.
    nonisolated(unsafe) private static var sink: FileHandle?
    private static let sinkLock = NSLock()

    static func redirectToFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Append rather than truncate: the diagnostics log survives across
        // launches. Rotated at 5MB with one generation kept, enough to hold the
        // crash just before a restart.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if (size ?? 0) > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let next = try? FileHandle(forWritingTo: url) else {
            // Keep the current sink: swapping to nil would close the one
            // destination that still works and discard every later event,
            // including the error describing this failure.
            log("✗ could not open \(path) — events continue to the previous destination")
            return
        }
        next.seekToEndOfFile()
        sinkLock.lock()
        defer { sinkLock.unlock() }
        try? sink?.close()
        sink = next
    }
}
