import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// fovea-capture — the capture binary
//
//   hello                     handshake; proves the Swift→Node stdio contract
//   ax-probe                  resolve what's under (or inside) the cursor
//
// Subcommand parsing is hand-rolled on purpose: ~40 lines versus an external
// dependency that would make `make dev` need the network.
// ─────────────────────────────────────────────────────────────────────────────

struct Args {
    let subcommand: String
    private let flags: [String: String]
    private let bools: Set<String>

    init(_ argv: [String]) {
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var subcommand = "hello"

        var rest = argv.dropFirst()
        if let first = rest.first, !first.hasPrefix("--") {
            subcommand = first
            rest = rest.dropFirst()
        }

        // Index-based with a PEEK, never a consume. An earlier version pulled
        // the next token to test it, and when that token was itself a flag it
        // registered it as a bool — so `--no-ocr --region 90` silently dropped
        // the 90 and captured a point. Flag order must not change behaviour.
        let tokens = Array(rest)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard token.hasPrefix("--") else { continue }
            let name = String(token.dropFirst(2))

            // `--flag=value`
            if let eq = name.firstIndex(of: "=") {
                flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
                continue
            }

            // `--flag value` — only when the next token isn't itself a flag.
            if i < tokens.count, !tokens[i].hasPrefix("--") {
                flags[name] = tokens[i]
                i += 1
            } else {
                bools.insert(name)
            }
        }

        self.subcommand = subcommand
        self.flags = flags
        self.bools = bools
    }

    func has(_ name: String) -> Bool { bools.contains(name) || flags[name] != nil }
    func string(_ name: String) -> String? { flags[name] }
    func double(_ name: String) -> Double? { flags[name].flatMap(Double.init) }
}

// Pin the monotonic origin before anything can emit a timestamp.
Clock.bootstrap()

let args = Args(CommandLine.arguments)

switch args.subcommand {

case "hello":
    Emit.event(HelloEvent(axTrusted: AXProbe.isTrusted()))

case "ax-probe":
    await runAXProbe(args)

case "capture":
    await runCapture(args)

case "record":
    runRecord(args)

case "timing":
    await runTiming(args)

case "help", "--help", "-h":
    Emit.log(Usage.text)

default:
    Emit.event(ErrorEvent("unknown subcommand '\(args.subcommand)'", hint: "try: fovea-capture help"))
    Emit.log(Usage.text)
    exit(2)
}

// ─────────────────────────────────────────────────────────────────────────────

func runAXProbe(_ args: Args) async {
    guard AXProbe.ensureTrusted(prompt: true) else {
        Emit.event(ErrorEvent(
            "not trusted for Accessibility",
            hint: "System Settings → Privacy & Security → Accessibility. Grant the TERMINAL you launched this from, not the binary — TCC permissions attach to the launching process."
        ))
        exit(1)
    }

    // Region radius: when set, we probe a circular lasso around the cursor
    // instead of a single point. Stands in for the freehand path until the
    // recorder's drawing UI exists, and exercises the identical code path.
    let regionRadius = args.double("region")
    let allowManual = !args.has("no-manual")
    let descend = !args.has("no-descend")

    if let delay = args.double("delay") {
        Emit.log("waiting \(delay)s — switch to the app you want to probe…")
        try? await Task.sleep(for: .seconds(delay))
    }

    // Crop + OCR: the Tier 1 base. Opt-in here so the AX matrix stays a clean
    // measurement of AX alone; the recorder will always run it.
    let wantsCrop = args.has("crop") || args.has("crop-dir")
    let cropDir = args.string("crop-dir") ?? "sessions/crops"
    var cropIndex = 0

    func probeOnce() async {
        let cursor = AXProbe.cursorLocation()
        var event: ProbeEvent
        if let radius = regionRadius {
            event = AXProbe.probeRegion(
                Shape.region(path: circlePath(around: cursor, radius: radius)),
                allowManualRetry: allowManual,
                descend: descend
            )
        } else {
            event = AXProbe.probePoint(
                cursor, allowManualRetry: allowManual, descend: descend
            )
        }

        if wantsCrop {
            let (rect, fromAX) = Capture.rect(
                for: event.shape,
                snapshot: event.snapshot,
                screenArea: AXProbe.screenArea()
            )
            cropIndex += 1
            let crop = await Capture.crop(
                shape: event.shape,
                snapshot: event.snapshot,
                outputPath: "\(cropDir)/probe-\(String(format: "%03d", cropIndex)).png",
                // Only pay Vision's 50-200ms when AX gave us nothing to read.
                runOCR: OCR.isNeeded(for: event.snapshot),
                rectFromAX: fromAX,
                rect: rect
            )
            event = event.with(crop: crop)
        }

        Emit.event(event)
        if args.has("verbose") { Emit.log(summarize(event)) }
    }

    guard args.has("watch") else {
        await probeOnce()
        return
    }

    // Watch mode: probe on cursor SETTLE, not on every move. Same trigger the
    // recorder will use for point-moments, so tuning these numbers here is not
    // throwaway work.
    let settleRadius = args.double("settle-radius") ?? 6
    let dwellMs = args.double("dwell") ?? 350
    let pollMs: UInt32 = 40

    Emit.log("watching — point at things, Ctrl-C to stop. (settle \(settleRadius)px / \(Int(dwellMs))ms\(regionRadius.map { ", region r=\(Int($0))px" } ?? ""))")

    var last = AXProbe.cursorLocation()
    var stationarySince = Clock.nowMs()
    var hasMoved = false
    var firedForThisRest = false

    // Pre-poke the app you're in, and again whenever you switch. Stands in for
    // what the recorder does at hotkey-down: get Chromium's tree built before
    // the first referent, rather than making that referent wait ~300ms for it.
    var lastFrontPid = allowManual ? AXProbe.prePokeFrontmost() : nil

    while true {
        usleep(pollMs * 1000)

        if allowManual, NSWorkspace.shared.frontmostApplication?.processIdentifier != lastFrontPid {
            lastFrontPid = AXProbe.prePokeFrontmost()
        }

        let now = AXProbe.cursorLocation()
        let moved = hypot(now.x - last.x, now.y - last.y)

        if moved > settleRadius {
            last = now
            stationarySince = Clock.nowMs()
            hasMoved = true
            firedForThisRest = false
            continue
        }

        let restedFor = Clock.nowMs() - stationarySince
        if hasMoved, !firedForThisRest, restedFor >= dwellMs {
            firedForThisRest = true
            await probeOnce()
        }
    }
}

/// Word timings for a recorded WAV, on-device. Emits JSON on stdout so the
/// Node side can merge these times with Sarvam's better text.
func runTiming(_ args: Args) async {
    guard let path = args.string("wav") else {
        Emit.event(ErrorEvent("timing needs --wav <path>"))
        exit(2)
    }

    let status = await SpeechTiming.requestAuthorization()
    guard status == .authorized else {
        Emit.event(ErrorEvent(
            "speech recognition not authorized (\(status.rawValue))",
            hint: "System Settings → Privacy & Security → Speech Recognition. Grant the terminal you launched from."
        ))
        exit(1)
    }

    let result = await SpeechTiming.transcribe(
        url: URL(fileURLWithPath: path),
        localeIdentifier: args.string("locale") ?? "hi-IN",
        forceOnDevice: !args.has("allow-network")
    )

    // Writing to a file rather than only stdout, because this has to be
    // launchable via `open -a`: TCC blames the RESPONSIBLE process, and a
    // binary exec'd from a terminal inherits that terminal's identity — inside
    // an IDE that is Electron, whose Info.plist has no speech key, so the
    // request is killed before our own plist is ever consulted. Going through
    // LaunchServices makes the app responsible for itself, and then it has no
    // stdout to write to.
    if let out = args.string("out") {
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: url)
        }
    }

    Emit.event(result)

    if let error = result.error {
        Emit.log("✗ \(error)")
        exit(1)
    }
    Emit.log("✓ \(result.words.count) words with timings (\(result.locale), on-device: \(result.onDevice))")
    if !result.transcript.isEmpty {
        Emit.log("  \"\(result.transcript.prefix(120))\"")
    }
}

/// Push-to-talk session recorder. Unlike the other subcommands this needs a
/// real AppKit run loop — the overlay is a window, and the event tap delivers
/// on a run loop source. `.accessory` keeps it out of the Dock and the app
/// switcher: it is an input peripheral, not an app you switch to.
@MainActor
func runRecord(_ args: Args) {
    guard AXProbe.ensureTrusted(prompt: true) else {
        Emit.event(ErrorEvent(
            "not trusted for Accessibility",
            hint: "System Settings → Privacy & Security → Accessibility. Grant the TERMINAL you launched from. An active event tap requires it — there is no partial mode."
        ))
        exit(1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let sessionId = args.string("session") ?? "session-\(Int(Date().timeIntervalSince1970))"
    let outputDir = args.string("out")

    let recorder = Recorder(
        sessionId: sessionId,
        outputDir: outputDir,
        captureCrops: !args.has("no-crop")
    )
    if let radius = args.double("settle-radius") { recorder.settleRadius = radius }
    if let dwell = args.double("dwell") { recorder.dwellMs = dwell }

    guard recorder.start() else {
        Emit.event(ErrorEvent(
            "could not create the event tap",
            hint: "Accessibility is granted but the tap was refused — try Input Monitoring for the same terminal, or relaunch it."
        ))
        exit(1)
    }

    Emit.log("""
    fovea-capture record — session \(sessionId)

      HOLD Right Option    to start a session
      point and pause      → a candidate referent
      hold mouse + circle  → a region referent (the drag is swallowed, so the
                             app underneath is never touched)
      release Right Option to end the session

      Ctrl-C to quit.
    """)

    app.run()
}

/// Tier 1 in isolation: crop + OCR with no Accessibility involvement at all.
/// Exists so the base path can be verified independently of AX — if this works
/// and ax-probe doesn't, the problem is a permission, not the capture code.
func runCapture(_ args: Args) async {
    if let delay = args.double("delay") {
        Emit.log("waiting \(delay)s…")
        try? await Task.sleep(for: .seconds(delay))
    }

    let cursor = AXProbe.cursorLocation()
    let shape: Shape
    // An explicit --rect must be captured verbatim, not run through the
    // point-referent heuristics that would replace it with a default box.
    var explicitRect: Frame?

    if let radius = args.double("region") {
        shape = Shape.region(path: circlePath(around: cursor, radius: radius))
    } else if let spec = args.string("rect") {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else {
            Emit.event(ErrorEvent("--rect needs x,y,w,h"))
            exit(2)
        }
        let f = Frame(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        explicitRect = f
        shape = Shape(kind: .point, origin: f.center, bounds: f, path: nil)
    } else {
        shape = Shape.point(cursor)
    }

    // An empty snapshot: no AX consulted, so `rect(for:)` falls back to the
    // default box and OCR always runs. That is exactly the Tier 1 path an app
    // with no accessibility tree would take.
    let empty = AXSnapshot(
        resolved: false, elements: [], samplesTested: nil, uniqueElements: nil,
        manualAccessibilityApplied: false, elapsedMs: 0, error: nil
    )
    let (rect, fromAX) = explicitRect.map { ($0, false) }
        ?? Capture.rect(for: shape, snapshot: empty, screenArea: AXProbe.screenArea())

    let out = args.string("out") ?? "sessions/crops/capture.png"

    // Repeat in-process. The display cache and ScreenCaptureKit's own warm-up
    // only pay off after the first call, so measuring cost by running the
    // binary N times measures N cold starts. The <4s release-to-plan budget is
    // a stated gate, so this needs to be measurable.
    let repeats = max(1, Int(args.string("repeat") ?? "1") ?? 1)
    var crop: CropResult!
    var timings: [Double] = []
    for _ in 0..<repeats {
        crop = await Capture.crop(
            shape: shape, snapshot: empty, outputPath: out,
            runOCR: !args.has("no-ocr"), rectFromAX: fromAX, rect: rect
        )
        timings.append(crop.captureElapsedMs)
    }
    if repeats > 1 {
        Emit.log("  capture ms: " + timings.map { String(Int($0)) }.joined(separator: " → "))
    }

    Emit.event(ProbeEvent(
        shape: shape, app: nil, windowTitle: nil, snapshot: empty, crop: crop
    ))

    if let err = crop.error {
        Emit.log("✗ \(err)")
        Emit.log("  Screen Recording is a SEPARATE permission from Accessibility.")
        Emit.log("  System Settings → Privacy & Security → Screen & System Audio Recording")
        Emit.log("  Grant the terminal you launched from, then relaunch that terminal.")
        exit(1)
    }

    Emit.log("✓ \(Int(crop.rect.width))×\(Int(crop.rect.height)) → \(crop.path ?? "(not written)") in \(Int(crop.captureElapsedMs))ms")
    if let ms = crop.ocrElapsedMs {
        Emit.log("  ocr: \(crop.ocr.count) lines in \(Int(ms))ms")
        for line in crop.ocr.prefix(12) {
            Emit.log(String(format: "    %.2f  %@", line.confidence, line.text))
        }
    }
}

/// Polygon approximating a circle — a stand-in freehand lasso.
func circlePath(around center: Point, radius: Double, segments: Int = 24) -> [Point] {
    (0..<segments).map { i in
        let angle = 2 * Double.pi * Double(i) / Double(segments)
        return Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

/// One-line human summary for stderr while hand-testing the app matrix.
func summarize(_ event: ProbeEvent) -> String {
    let app = event.app?.name ?? "?"
    let snap = event.snapshot
    let flag = snap.manualAccessibilityApplied ? " [poked]" : ""
    let timing = String(format: "%.0fms", snap.elapsedMs)

    // Crop line, when one was taken. `ax-rect` vs `box` is the interesting bit:
    // it shows whether AX gave us precise geometry even where it gave no text.
    var cropLine = ""
    if let crop = event.crop {
        if let err = crop.error {
            cropLine = "\n      crop ✗ \(err)"
        } else {
            let source = crop.rectFromAX ? "ax-rect" : "box"
            let size = "\(Int(crop.rect.width))×\(Int(crop.rect.height))"
            let ocr = crop.ocr.isEmpty
                ? ""
                : " · ocr \(crop.ocr.count) lines in \(Int(crop.ocrElapsedMs ?? 0))ms: \"\(crop.ocr.prefix(3).map(\.text).joined(separator: " ⏐ ").prefix(60))…\""
            let masked = crop.masked ? " masked" : ""
            cropLine = "\n      crop \(size) \(source)\(masked) \(Int(crop.captureElapsedMs))ms\(ocr)"
        }
    }

    guard snap.resolved, let first = snap.elements.first else {
        return "  ✗ \(app): \(snap.error ?? "unresolved") (\(timing))\(flag)\(cropLine)"
    }

    let text = [first.value, first.title, first.elementDescription, first.selectedText]
        .compactMap { $0 }
        .first ?? "—"
    let clipped = text.count > 70 ? String(text.prefix(70)) + "…" : text

    // Points show the ancestor chain — a bare AXScrollArea under AXGroup/AXGroup
    // is the signature of an unbridged Electron window, and you want to see that
    // live rather than discover it in the JSON afterwards.
    // Regions show the sample→element collapse, which is the granularity signal.
    let context: String
    if let samples = snap.samplesTested {
        context = "\(snap.uniqueElements ?? 0) elems / \(samples) samples · \(first.role ?? "?")"
    } else {
        let chain = first.ancestors.compactMap { $0.role }.joined(separator: "/")
        context = chain.isEmpty ? (first.role ?? "?") : "\(first.role ?? "?") ← \(chain)"
    }

    return "  ✓ \(app): \(context) · \"\(clipped.replacingOccurrences(of: "\n", with: "⏎"))\" (\(timing))\(flag)\(cropLine)"
}

/// Held in a type rather than as a top-level `let`. Globals in main.swift are
/// initialised in source order as execution reaches them, so a top-level
/// `let usage` declared below the dispatch switch read back as an EMPTY STRING
/// — `fovea-capture help` printed nothing and exited 0. Static members are
/// initialised lazily on first access, so declaration order stops mattering.
enum Usage {
    static let text = """
fovea-capture \(FoveaVersion.current)

  hello                       Handshake event on stdout (checks AX trust).

  record [options]            Push-to-talk session recorder (the real thing).
                              HOLD Right Option to record. Point and pause for
                              a candidate referent; hold the mouse button and
                              circle an area for a region referent. Release to
                              stop. An overlay shows the cursor, its trace and
                              the lasso while the key is down — and only then.
    --out <dir>               Session directory (crops land in <dir>/crops).
    --session <id>            Session id (default: session-<unix time>).
    --settle-radius <px>      Movement under this counts as stationary (8).
    --dwell <ms>              Rest time before a settle fires (300).
    --no-crop                 Skip the Tier 1 crop + OCR per referent.

  capture [options]           Tier 1 only: crop + OCR, no Accessibility.
    --delay <sec>             Wait before capturing.
    --region <radius>         Capture a circular lasso, masked to the path.
    --rect <x,y,w,h>          Capture an explicit rectangle.
    --out <path>              PNG destination (sessions/crops/capture.png).
    --no-ocr                  Skip Vision text recognition.
    --repeat <n>              Capture n times in-process and print each timing.
                              First call is cold (~200ms); steady state is what
                              the <4s release-to-plan budget actually pays.

  ax-probe [options]          Resolve what the cursor is pointing at.
    --watch                   Probe continuously, on each cursor settle.
    --delay <sec>             Wait before probing (time to switch apps).
    --region <radius>         Probe a circular region instead of a point.
    --no-manual               Do NOT set AXManualAccessibility (also disables
                              pre-poking). Use this to tell "works natively"
                              from "works once poked".
    --no-descend              Do NOT walk down into children when the hit
                              element carries no text. Use this to measure what
                              descent is actually buying per app.
    --settle-radius <px>      Movement under this counts as stationary (6).
    --dwell <ms>              Rest time before a settle fires (350).
    --crop                    Also capture the screen crop (Tier 1 base), and
                              OCR it when AX returned no usable text. Prefers
                              the AX element rectangle over a fixed box.
    --crop-dir <path>         Where crops are written (sessions/crops).
    --verbose                 Human summary on stderr alongside the JSON.

Events go to stdout as JSON Lines. Logs go to stderr.
"""
}
