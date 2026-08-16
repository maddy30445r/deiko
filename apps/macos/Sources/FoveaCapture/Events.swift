import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE WIRE CONTRACT
//
// Everything the Swift capture binary emits crosses into TypeScript as one JSON
// object per line (JSON Lines) on stdout. THIS FILE IS THE CONTRACT — there is
// no mirrored copy on the other side. A TypeScript one existed and was deleted:
// nothing ever imported it, so it drifted silently and its only real effect was
// to make two files look authoritative when one was.
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
    /// The whole recording — opened by the first hold, closed by "Stop session".
    case sessionStart
    case sessionEnd
    /// One press-and-release of the hotkey. A session contains many.
    case holdStart
    case holdEnd
    case cursor
    case candidate
}

// ─────────────────────────────────────────────────────────────────────────────
// Candidates
//
// Every cursor settle is logged as a CANDIDATE, never filtered at capture time.
// Cursor data alone cannot tell a pointing act from a resting hand — but cursor
// data plus narration can, trivially: a settle with "yeh dekho" on it is a
// referent, a settle inside three seconds of silence is you thinking.
//
// So the recorder over-captures and records the features that let the alignment
// engine judge later. A candidate that never binds to speech simply never
// becomes a referent, and costs nothing.
// ─────────────────────────────────────────────────────────────────────────────

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
    /// This is the strongest of the four, because it is the only one that says
    /// anything about INTENT rather than mechanics: a cursor that stops while
    /// somebody is talking is almost always pointing at what they are talking
    /// about. It also gates capture — a settle further than a few seconds from
    /// any speech is never recorded at all.
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

/// Raw cursor sample. Kept at full rate so the aligner can re-derive settles
/// with different thresholds without re-recording the session — the settle
/// parameters are exactly what T0.2 expects to tune.
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

// ─────────────────────────────────────────────────────────────────────────────
// Sessions and holds
//
// Two nested levels, and keeping them apart matters more than it looks:
//
//   HOLD    one press-and-release of Right Option. One utterance, one WAV, its
//           own `audioT0`. Word timings are offsets from that hold's t0, which
//           is the only reason per-hold audio files exist.
//
//   SESSION everything from the first hold until "Stop session" — one directory,
//           one referent stack, one plan. It is the unit the user thinks in:
//           point in the editor, release, switch to Compass, point again, and
//           all of it is still the same description of the same problem.
//
// These were one event type called `sessionStart`/`sessionEnd` fired per hold,
// from when a session WAS a hold. Once holds accumulate into a session that the
// user closes explicitly, that name described the wrong boundary.
// ─────────────────────────────────────────────────────────────────────────────

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
    /// the ASR returns is an offset from THIS — not from `t`, because the mic
    /// takes a few milliseconds to start delivering and that gap would become a
    /// constant skew in every binding.
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

/// Which gesture drew a mark, and its badge number — present only on referents
/// minted by a modifier stroke. A plain settle carries nil. `kind` is
/// `StrokeKind.rawValue` (point/lasso/connector/trace/emphasis); a string on
/// the wire so old sessions and non-Swift readers need no enum.
struct MarkInfo: Codable {
    let kind: String
    let number: Int
}

/// The indicated area. `path` is the raw freehand polygon in screen coords
/// (absent for points). `bounds` is its bounding box — what gets cropped — and
/// the path is retained so the bounding box of the stroke is known, and so a
/// later reader can see the shape that was drawn.
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
    /// For regions: when the drag actually began and ended, on the session
    /// clock. Emitted because the recorder KNOWS this — it saw `dragBegan` —
    /// while the TS loader used to reconstruct it from frozen cursor samples,
    /// which could not tell "cursor frozen mid-drag" from "cursor parked here
    /// before pressing" and once recovered a 9.7-second phantom drag. Nil for
    /// plain settles; a marked tap carries the measured stroke interval too.
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

    init(
        shape: Shape,
        app: AppIdentity?,
        windowTitle: String?,
        snapshot: AXSnapshot,
        crop: CropResult? = nil,
        mark: MarkInfo? = nil,
        startSnapshot: AXSnapshot? = nil
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
            startSnapshot: startSnapshot
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
        startSnapshot: AXSnapshot? = nil
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
            span: span,
            app: app,
            windowTitle: windowTitle,
            snapshot: snapshot,
            crop: crop,
            mark: mark,
            startSnapshot: startSnapshot
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
            startSnapshot: startSnapshot
        )
    }
}

/// An interval on the session clock, in milliseconds.
struct TimeSpan: Codable {
    let start: Double
    let end: Double
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
    /// Read from the bundle rather than hardcoded, so there is ONE version in
    /// the product and it is the one macOS shows.
    ///
    /// `VERSION` at the repo root is the source; `make bundle` stamps it into
    /// `CFBundleShortVersionString`, and this reads it back. The two used to be
    /// separate literals with nothing keeping them in sync — the kind of drift
    /// nobody notices until a bug report cites a version that never shipped.
    ///
    /// The fallback covers the SwiftPM binary run straight out of `.build`,
    /// which has no bundle to read.
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0-dev"

    /// The build, for telling two shipped copies of the same version apart.
    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
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

    /// An `ErrorEvent` that also reaches the person it is about.
    ///
    /// THE SECOND ERROR CHANNEL, AND WHY IT NEEDED ONE. `PipelineFailure` and
    /// `HandoffError` produce sentences the user reads; `Emit.event(ErrorEvent)`
    /// produces a line in `launch.jsonl` that nobody has ever read. That split
    /// is right for diagnostics — most of these are for us — but three of them
    /// are the difference between "Fovea is broken" and "Fovea told me why",
    /// because they leave the app looking healthy while ignoring the user
    /// completely: no session directory, no event tap, no microphone.
    ///
    /// The hint is the fix, in the user's words, and it is already written at
    /// every call site — it was simply being filed rather than shown.
    static func problem(_ message: String, hint: String) {
        event(ErrorEvent(message, hint: hint))
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Fovea can't start a session"
            alert.informativeText = hint
            alert.addButton(withTitle: "OK")
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
        // Locked, and it matters: crop resolution runs on detached tasks, so
        // two multi-KB ProbeEvents can hit this concurrently — and concurrently
        // with `redirectToFile` swinging the handle on the main actor. Without
        // the lock, lines interleave mid-JSON (both loaders silently drop
        // unparseable lines, so the referent just vanishes) or a write lands on
        // a just-closed descriptor.
        sinkLock.lock()
        defer { sinkLock.unlock() }
        if let sink {
            sink.write(Data("\(line)\n".utf8))
        } else {
            print(line)
            fflush(stdout)
        }
    }

    /// Human-facing output.
    ///
    /// Goes to the SAME sink as `event()` when one is set, and to stderr
    /// otherwise. It used to write to stderr unconditionally, which is a file
    /// descriptor a Finder-launched app does not have — so every `Emit.log` in
    /// the menu-bar app went nowhere. That included the handoff trace added
    /// specifically so a failure in the field would leave evidence: after 44
    /// sessions, `~/Library/Logs/Fovea/launch.jsonl` was still zero bytes, and
    /// two "nothing happened" investigations started from no data at all.
    ///
    /// Wrapped as JSON so a line of prose cannot break a reader parsing the
    /// file as JSON Lines — the same file carries both.
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

    /// Send events to a file instead of stdout.
    ///
    /// An app launched from Finder has no terminal attached, so the JSON Lines
    /// stream has nowhere to go. Rather than teach every call site about a
    /// destination, redirect — `event()` stays a one-argument call everywhere
    /// and the session directory becomes the real output.
    ///
    /// Called more than once per process now: the menu-bar app opens on a
    /// diagnostics log, swings to the session's `events.jsonl` when a session
    /// starts, and swings back when it stops. Hence the close — the old handle
    /// used to be dropped still open, which on a long-lived app leaks a file
    /// descriptor per session and leaves the last writes unflushed.
    nonisolated(unsafe) private static var sink: FileHandle?
    private static let sinkLock = NSLock()

    static func redirectToFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Append rather than truncate: the diagnostics log is meant to survive
        // across launches, and a session file is only ever written once anyway.
        //
        // ROTATED AT 5MB, because "survives across launches" was being read as
        // "forever". Every handoff trace and pipeline timing this install has
        // ever written accumulates here, and nothing pruned it. One generation
        // is kept — enough to still hold the crash that happened just before a
        // restart, which is the only history anybody has ever wanted from it.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if (size ?? 0) > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let next = try? FileHandle(forWritingTo: url) else {
            // Keep the CURRENT sink. Swapping to nil here would close the one
            // destination that still works and silently discard every event
            // after it — including the error describing this very failure.
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
