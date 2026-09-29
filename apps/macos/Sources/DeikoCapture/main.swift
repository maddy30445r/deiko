import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation
import DeikoGesture
import DeikoHandoff

// deiko-capture: the capture binary. Subcommand parsing is hand-rolled to avoid a dependency that
// would make `make dev` need the network.

struct Args {
    let subcommand: String
    private let flags: [String: String]
    private let bools: Set<String>

    init(_ argv: [String]) {
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var subcommand: String

        // Double-clicking Deiko.app passes no subcommand: inside a bundle the default is the app,
        // from a terminal it is the handshake.
        var subcommandDefault = "hello"
        if Bundle.main.bundleIdentifier != nil { subcommandDefault = "app" }
        subcommand = subcommandDefault

        var rest = argv.dropFirst()
        if let first = rest.first, !first.hasPrefix("--") {
            subcommand = first
            rest = rest.dropFirst()
        }

        // Index-based with a peek, never a consume: consuming the next token to test it would register a
        // following flag as a bool, so `--no-ocr --region 90` would drop the 90. Flag order must not
        // change behaviour.
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

            // `--flag value`, only when the next token isn't itself a flag.
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

case "record":
    runRecord(args)

case "app":
    runApp(args)

case "timing":
    await runTiming(args)

case "icon":
    renderIconset(args)

// deiko-capture ink-demo --out /tmp/ink-demo.png
// Draws all five mark kinds on a flat background: the smallest check that fails if the geometry
// (flip, scale, arrowhead, badge) breaks.
case "ink-demo":
    runInkDemo(args)

// deiko-capture ui-shot --out /tmp/deiko-ui
// Every window, light and dark, as PNGs.
case "ui-shot":
    UIShot.run(args)

// Also a subcommand, not only a Settings button: diagnostics matter most when the app will not
// launch, when a button inside it is unreachable.
case "diagnostics":
    print(Diagnostics.report())

case "help", "--help", "-h":
    Emit.log(Usage.text)

default:
    Emit.event(ErrorEvent("unknown subcommand '\(args.subcommand)'", hint: "try: deiko-capture help"))
    Emit.log(Usage.text)
    exit(2)
}

func runAXProbe(_ args: Args) async {
    guard AXProbe.ensureTrusted(prompt: true) else {
        Emit.event(ErrorEvent(
            "not trusted for Accessibility",
            hint: "System Settings → Privacy & Security → Accessibility. Grant the TERMINAL you launched this from, not the binary — TCC permissions attach to the launching process."
        ))
        exit(1)
    }

    // Region radius: when set, probe a circular lasso around the cursor instead of a single point,
    // exercising the same code path as a freehand path.
    let regionRadius = args.double("region")
    let allowManual = !args.has("no-manual")
    let descend = !args.has("no-descend")

    if let delay = args.double("delay") {
        Emit.log("waiting \(delay)s — switch to the app you want to probe…")
        try? await Task.sleep(for: .seconds(delay))
    }

    // Crop + OCR is opt-in here so the AX matrix measures AX alone; the recorder always runs it.
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
                snapshot: event.snapshot,
                outputPath: "\(cropDir)/probe-\(String(format: "%03d", cropIndex)).png",
                // Unconditional, matching the recorder: this tool checks what the recorder will capture.
                runOCR: true,
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

    // Watch mode probes when the cursor settles, not on every move: the same trigger the recorder
    // uses for point-moments.
    let settleRadius = args.double("settle-radius") ?? 6
    let dwellMs = args.double("dwell") ?? 350
    let pollMs: UInt32 = 40

    Emit.log("watching — point at things, Ctrl-C to stop. (settle \(settleRadius)px / \(Int(dwellMs))ms\(regionRadius.map { ", region r=\(Int($0))px" } ?? ""))")

    var last = AXProbe.cursorLocation()
    var stationarySince = Clock.nowMs()
    var hasMoved = false
    var firedForThisRest = false

    // Pre-poke the frontmost app, and again on each switch, as the recorder does at hotkey-down: it
    // gets Chromium's accessibility tree built before the first referent needs it.
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

/// The product: a menu-bar app that arms the hotkey and stays out of the way.
///
/// This is what `Deiko.app` runs when double-clicked. Launched through LaunchServices, macOS holds
/// Deiko responsible for its own privacy requests; run from a terminal, the permissions attach to the
/// terminal instead, which is why `record` needs grants on whatever shell was used.
@MainActor
func runApp(_ args: Args) {
    let app = NSApplication.shared
    // .accessory: no Dock icon, no app switcher. `MainWindowController` makes it a regular app while
    // its board window is open.
    app.setActivationPolicy(.accessory)
    AppMenu.install()

    // A root, not a session directory: the session folder is minted on the first hold
    // (see `Recorder.startSessionIfNeeded`).
    if args.string("out") == nil { Sessions.migrateFromDocuments() }
    let root = args.string("out") ?? Sessions.defaultRoot

    let recorder = Recorder(sessionRoot: root, captureCrops: !args.has("no-crop"))
    if let radius = args.double("settle-radius") { recorder.settleRadius = radius }
    if let dwell = args.double("dwell") { recorder.dwellMs = dwell }

    // Events go to a file because an app launched from Finder has nowhere to print. Until a session
    // exists they go to a launch log, so a startup permission failure stays recoverable.
    Emit.redirectToFile(Paths.launchLog)
    // After the sink exists: a crash report with nowhere to go is not a crash report.
    CrashReport.install()

    let menu = MenuBar(recorder: recorder)
    app.delegate = menu
    menu.install()

    Emit.log("Deiko running in the menu bar — sessions → \(root)")
    app.run()
}

/// Word timings for a recorded WAV, on-device. Emits JSON on stdout so the Node side can merge these
/// times with the better transcript text.
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

    // No network fallback and no flag for one: it could only ship narration to Apple's servers, which
    // SpeechTiming's guard exists to refuse.
    //
    // `--live` runs the WAV through the live recogniser by handing it the file's samples the way the
    // microphone tap hands it buffers, to check that it accepts the 16kHz mono int16 buffers we feed it.
    let result: TimingResult
    if args.has("live") {
        result = await liveTimingFromFile(
            path: path, locale: args.string("locale") ?? "hi-IN"
        )
    } else {
        // `--context <file>`: newline-separated vocabulary hints, to compare on-device recognition with
        // and without the on-screen identifiers over the same audio. A file because the list runs to
        // dozens of symbols.
        let context = args.string("context")
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        result = await SpeechTiming.transcribe(
            url: URL(fileURLWithPath: path),
            localeIdentifier: args.string("locale") ?? "hi-IN",
            contextualStrings: context
        )
    }

    // Written to a file, not only stdout, so this can run via `open -a`: TCC blames the responsible
    // process, and a binary exec'd from an IDE terminal inherits the IDE's identity (Electron, whose
    // Info.plist has no speech key), so the request dies before our plist is consulted. LaunchServices
    // makes the app responsible for itself, and then it has no stdout.
    if let out = args.string("out") {
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(result) {
            // Atomic: transcribe.mjs polls for this file and reads it the instant it appears, and a plain
            // write could be caught at zero bytes.
            try? data.write(to: url, options: .atomic)
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

/// Replay a WAV through the live recogniser in the buffer shape and at the pace the mic tap produces:
/// 16kHz mono int16, 4096 frames at a time, one buffer per 256ms of audio.
///
/// Read as int16 rather than the default float processing format, so what reaches `append` is what
/// `Audio`'s converter emits; float would test a format the app never sends.
///
/// The pacing matters: fed a whole file as fast as the disk allows, the recogniser drops most of it.
/// A microphone cannot deliver faster than realtime, so an unpaced replay tests a condition the app
/// can never be in.
func liveTimingFromFile(path: String, locale: String) async -> TimingResult {
    guard let live = LiveSpeechTiming(localeIdentifier: locale) else {
        return TimingResult(
            words: [], transcript: "", locale: locale, onDevice: false,
            error: "no on-device live recogniser for \(locale)"
        )
    }
    guard let file = try? AVAudioFile(
        forReading: URL(fileURLWithPath: path),
        commonFormat: .pcmFormatInt16,
        interleaved: true
    ), let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: 4096
    ) else {
        live.cancel()
        return TimingResult(
            words: [], transcript: "", locale: locale, onDevice: false,
            error: "could not read \(path) as 16-bit PCM"
        )
    }

    let bufferMs = 4096.0 / file.processingFormat.sampleRate * 1000
    while (try? file.read(into: buffer, frameCount: 4096)) != nil, buffer.frameLength > 0 {
        live.append(buffer)
        try? await Task.sleep(for: .milliseconds(Int(bufferMs)))
    }
    return await live.finish()
}

/// Push-to-talk session recorder. Unlike the other subcommands this needs a real AppKit run loop: the
/// overlay is a window and the event tap delivers on a run loop source. `.accessory` keeps it out of
/// the Dock and the app switcher.
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

    // Same session model as the app: a root that session folders are minted under, one per session,
    // named by timestamp.
    let root = args.string("out") ?? "sessions"

    let recorder = Recorder(sessionRoot: root, captureCrops: !args.has("no-crop"))
    if let radius = args.double("settle-radius") { recorder.settleRadius = radius }
    if let dwell = args.double("dwell") { recorder.dwellMs = dwell }

    guard recorder.start() else {
        Emit.event(ErrorEvent(
            "could not create the event tap",
            hint: "Accessibility is granted but the tap was refused — try Input Monitoring for the same terminal, or relaunch it."
        ))
        exit(1)
    }

    // Ctrl-C is this command's "Stop session": it must close the session out rather than kill the
    // process mid-write, which would leave the last crops unwritten and no `sessionEnd` line. The
    // default handler has to be disabled explicitly, since a DispatchSource for a signal observes it
    // rather than replacing it.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        Task { @MainActor in
            if let dir = await recorder.stopSession() {
                Emit.log("session → \(dir)")
            }
            await recorder.stop()
            exit(0)
        }
    }
    interrupt.resume()

    Emit.log("""
    deiko-capture record — sessions → \(root)

      DOUBLE-TAP Right Option   start capturing — audio and screen, until you
                                stop it. Let go of the key and walk through as
                                many windows as you like.
      point and pause           → a candidate referent, when you are talking
      hold LEFT Option + move   → a region referent. No mouse button, and
                                nothing is swallowed: clicks always land
      TAP Right Option          stop, and write the session out

      Ctrl-C                    same as stopping.
    """)

    app.run()
}

/// Polygon approximating a circle — a stand-in freehand lasso.
func circlePath(around center: Point, radius: Double, segments: Int = 24) -> [Point] {
    (0..<segments).map { i in
        let angle = 2 * Double.pi * Double(i) / Double(segments)
        return Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

/// Draws all five `StrokeKind`s onto a flat 900×300 background and writes it to `--out` (default
/// `/tmp/ink-demo.png`), so InkRenderer can be eyeballed without a real session. The five calls ink
/// the same file in sequence, so one image shows all five kinds.
func runInkDemo(_ args: Args) {
    let outPath = args.string("out") ?? "/tmp/ink-demo.png"
    let w = 900, h = 300

    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        Emit.event(ErrorEvent("could not create demo context"))
        exit(1)
    }
    ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.makeImage(), Capture.writePNG(base, to: outPath) else {
        Emit.event(ErrorEvent("could not write demo background to \(outPath)"))
        exit(1)
    }

    let cropRect = Frame(x: 0, y: 0, width: 900, height: 300)
    let marks: [(strokePath: [Point], kind: StrokeKind, number: Int)] = [
        // 1. tap
        ([Point(x: 80, y: 150)], .point, 1),
        // 2. circle
        (circlePath(around: Point(x: 250, y: 150), radius: 50), .lasso, 2),
        // 3. straight line
        ([Point(x: 380, y: 200), Point(x: 560, y: 90)], .connector, 3),
        // 4. L-shaped path
        ([Point(x: 600, y: 250), Point(x: 600, y: 80), Point(x: 720, y: 80)], .trace, 4),
        // 5. zigzag
        ([Point(x: 760, y: 130), Point(x: 790, y: 170), Point(x: 820, y: 130),
          Point(x: 850, y: 170), Point(x: 870, y: 130)], .emphasis, 5),
    ]
    for mark in marks {
        InkRenderer.ink(
            file: outPath, strokePath: mark.strokePath, cropRect: cropRect,
            kind: mark.kind, number: mark.number
        )
    }
    print(outPath)
}

/// One-line human summary for stderr while hand-testing the app matrix.
func summarize(_ event: ProbeEvent) -> String {
    let app = event.app?.name ?? "?"
    let snap = event.snapshot
    let flag = snap.manualAccessibilityApplied ? " [poked]" : ""
    let timing = String(format: "%.0fms", snap.elapsedMs)

    // Crop line, when one was taken. `ax-rect` vs `box` shows whether AX gave precise geometry even
    // where it gave no text.
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
            cropLine = "\n      crop \(size) \(source) \(Int(crop.captureElapsedMs))ms\(ocr)"
        }
    }

    guard snap.resolved, let first = snap.elements.first else {
        return "  ✗ \(app): \(snap.error ?? "unresolved") (\(timing))\(flag)\(cropLine)"
    }

    let text = [first.value, first.title, first.elementDescription, first.selectedText]
        .compactMap { $0 }
        .first ?? "—"
    let clipped = text.count > 70 ? String(text.prefix(70)) + "…" : text

    // Points show the ancestor chain: a bare AXScrollArea under AXGroup/AXGroup is the signature of an
    // unbridged Electron window. Regions show the sample→element collapse, the granularity signal.
    let context: String
    if let samples = snap.samplesTested {
        context = "\(snap.uniqueElements ?? 0) elems / \(samples) samples · \(first.role ?? "?")"
    } else {
        let chain = first.ancestors.compactMap { $0.role }.joined(separator: "/")
        context = chain.isEmpty ? (first.role ?? "?") : "\(first.role ?? "?") ← \(chain)"
    }

    return "  ✓ \(app): \(context) · \"\(clipped.replacingOccurrences(of: "\n", with: "⏎"))\" (\(timing))\(flag)\(cropLine)"
}

/// Held in a type rather than a top-level `let`: globals in main.swift initialise in source order as
/// execution reaches them, so a `let usage` below the dispatch switch would read as an empty string.
/// Static members initialise lazily, so declaration order does not matter.
enum Usage {
    static let text = """
deiko-capture \(DeikoVersion.current)

  app                         The product: menu-bar app, hotkey live, events
                              written to a session folder. This is what runs
                              when Deiko.app is launched — and launching it that
                              way is what makes macOS attribute permissions to
                              Deiko rather than to your terminal.
    --out <dir>               Where sessions are minted (~/Library/Application Support/Deiko).
    --no-crop                 Skip the Tier 1 crop + OCR per referent.

  hello                       Handshake event on stdout (checks AX trust).

  record [options]            The same recorder without the menu bar.

                              DOUBLE-TAP Right Option to start; TAP it to stop.
                              Capture runs continuously in between — audio and
                              screen — with the key released, so switching
                              windows can no longer eat the middle of a
                              sentence.

                              Point and pause at something WHILE TALKING for a
                              candidate referent; a settle more than a few
                              seconds from any speech is not recorded at all.
                              Hold LEFT Option and move to circle an area.

                              The directory <root>/<stamp> is created when
                              capture starts, so a run that records nothing
                              leaves nothing behind.
    --out <dir>               Where sessions are minted (default: sessions).
    --settle-radius <px>      Movement under this counts as stationary (8).
    --dwell <ms>              Rest time before a settle fires (300).
    --no-crop                 Skip the Tier 1 crop + OCR per referent.

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

  timing --wav <path>         On-device word timings for a recorded WAV.
    --locale <id>             Recogniser locale (hi-IN; the app uses en-IN).
    --out <path>              Write the JSON here as well as to stdout.
    --live                    Replay the file through the LIVE recogniser —
                              the path a real session uses — instead of the
                              file-based one, buffer by buffer and at realtime
                              pace. Whether the recogniser accepts the buffers
                              the microphone produces is the one thing no unit
                              test can answer, and recording depends on it.

                              Run this from Deiko.app, not from a terminal:
                              speech is attributed to the RESPONSIBLE process,
                              and a terminal has no speech usage description,
                              so the request aborts the binary outright.
                                open -n -a build/Deiko.app --args timing \\
                                  --wav f.wav --live --out /tmp/t.json

  diagnostics                 Version, permissions and where the log is — the
                              block the Settings button copies. Contains
                              nothing from inside a session, so it is safe to
                              paste into a bug report.

  icon --out <dir>            Render the Deiko mark into an .iconset. Build
                              step, not a runtime one — `make icon` runs this
                              and hands the result to iconutil.

  ink-demo                    Draws all five stroke kinds (point, lasso,
                              connector, trace, emphasis) onto a flat
                              background — the runnable check for
                              InkRenderer's geometry (flip, scale, arrowhead,
                              badge).
    --out <path>              Where the demo PNG is written (/tmp/ink-demo.png).

Events go to stdout as JSON Lines. Logs go to stderr.
"""
}
