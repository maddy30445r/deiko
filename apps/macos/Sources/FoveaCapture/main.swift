import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation
import FoveaHandoff

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
        var subcommand: String

        // Double-clicking Fovea.app passes no subcommand. Inside a bundle the
        // sensible default is the product itself; from a terminal it is the
        // handshake, which is what a developer poking at the binary wants.
        var subcommandDefault = "hello"
        if Bundle.main.bundleIdentifier != nil { subcommandDefault = "app" }
        subcommand = subcommandDefault

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

case "record":
    runRecord(args)

case "app":
    runApp(args)

case "timing":
    await runTiming(args)

case "icon":
    renderIconset(args)

case "connect":
    runConnect(args)

// Also a subcommand, not only a Settings button. The moment diagnostics are
// worth having is the moment the app is not working — and if it will not
// launch, a button inside it is not reachable.
case "diagnostics":
    print(Diagnostics.report())

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
                snapshot: event.snapshot,
                outputPath: "\(cropDir)/probe-\(String(format: "%03d", cropIndex)).png",
                // Unconditional, matching the recorder — this is the tool used
                // to check what the recorder will capture, so it must not
                // capture something different.
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

/// The product: a menu-bar app that arms the hotkey and stays out of the way.
///
/// This is what `Fovea.app` runs when double-clicked, and the difference from
/// `record` is not cosmetic — launched through LaunchServices, macOS holds
/// Fovea responsible for its own privacy requests. Run the same binary from a
/// terminal and the permissions attach to the terminal instead, which is why
/// `record` needs four things granted to whatever shell you happened to use.
@MainActor
func runApp(_ args: Args) {
    let app = NSApplication.shared
    // .accessory: no Dock icon, no app switcher. It is an input peripheral,
    // not something you alt-tab to.
    app.setActivationPolicy(.accessory)

    // A ROOT, not a session directory. The session folder is minted on the
    // first hold and named `20260728-011253` — see `Recorder.startSessionIfNeeded`.
    let root = args.string("out") ?? "\(NSHomeDirectory())/Documents/Fovea"

    let recorder = Recorder(sessionRoot: root, captureCrops: !args.has("no-crop"))
    if let radius = args.double("settle-radius") { recorder.settleRadius = radius }
    if let dwell = args.double("dwell") { recorder.dwellMs = dwell }

    // Events go to a file rather than stdout: an app launched from Finder has
    // nowhere to print. Until a session exists they go to a launch log, so a
    // permission failure at startup is still recoverable after the fact.
    Emit.redirectToFile(Paths.launchLog)

    let menu = MenuBar(recorder: recorder)
    app.delegate = menu
    menu.install()

    Emit.log("Fovea running in the menu bar — sessions → \(root)")
    app.run()
}


/// Show which coding clients Fovea can see, and optionally register with them.
///
/// The Settings window does the same thing with a button. This exists because
/// the interesting question — "did writing to a config file that another program
/// owns damage it?" — is answered by a diff, and a diff needs a scriptable way
/// to trigger the write against a throwaway copy:
///
///   CLAUDE_CONFIG_DIR=/tmp/fakehome fovea-capture connect --write
///
/// `ClaudeCodeConnector` reads `CLAUDE_CONFIG_DIR` (as Claude Code itself does),
/// so that runs the real code path against a config nobody depends on.
@MainActor
func runConnect(_ args: Args) {
    Emit.log("node:   \(NodeRuntime.resolve()?.path ?? "NOT FOUND")")
    Emit.log("layout: \(Layout.resolve().map(String.init(describing:)) ?? "NOT FOUND")")

    for connector in Connectors.all {
        Emit.log("")
        Emit.log("\(connector.name)")
        Emit.log("  installed: \(connector.isInstalled)")
        Emit.log("  connected: \(connector.isConnected)")
        Emit.log("  command:   \(connector.commandForm)")

        do {
            if args.has("disconnect") {
                try Connectors.disconnect(connector)
                Emit.log("  → connected: \(connector.isConnected)")
            } else if args.has("write") {
                try Connectors.connect(connector)
                Emit.log("  → connected: \(connector.isConnected)")
            }
        } catch {
            Emit.log("  ✗ \(error.localizedDescription)")
        }
    }
    if !args.has("write"), !args.has("disconnect") {
        Emit.log("")
        Emit.log("nothing written — pass --write to register, --disconnect to remove")
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

    // No network fallback and no flag for one. The only thing such a flag
    // could do is ship narration to Apple's servers — the exact thing
    // SpeechTiming's guard exists to refuse (PRD §10).
    //
    // `--live` runs the WAV through the LIVE recogniser instead, by handing it
    // the file's samples the way the microphone tap hands it buffers. That is
    // the one thing about the live path a unit test cannot answer: whether the
    // recogniser accepts the 16kHz mono int16 buffers we feed it. Since
    // recording now depends on that being true, it needs a way to be checked
    // that does not involve speaking into a microphone and hoping.
    let result: TimingResult
    if args.has("live") {
        result = await liveTimingFromFile(
            path: path, locale: args.string("locale") ?? "hi-IN"
        )
    } else {
        result = await SpeechTiming.transcribe(
            url: URL(fileURLWithPath: path),
            localeIdentifier: args.string("locale") ?? "hi-IN"
        )
    }

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
            // Atomic: transcribe.mjs polls for this file's existence and reads
            // it the instant it appears. A plain write is create-then-fill, so
            // the poller could catch it at zero bytes and JSON.parse("") threw
            // the whole hold away.
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

/// Replay a WAV through the live recogniser, in the buffer shape AND at the pace
/// the mic tap produces: 16kHz mono int16, 4096 frames at a time, one buffer per
/// 256ms of audio.
///
/// Read AS int16 rather than through the default float processing format, so
/// what reaches `append` is the same thing `Audio`'s converter emits. Reading it
/// as float would test a format the app never sends and pass while the real path
/// failed.
///
/// THE PACING IS NOT POLITENESS, it is the difference between a valid test and a
/// misleading one. Fed a whole file as fast as the disk allows, the recogniser
/// drops most of it: this replay returned three garbled segments where the
/// file-based path on the same WAV returned twenty-one correct words. A
/// microphone cannot deliver faster than realtime, so an unpaced replay tests a
/// condition the app can never be in — and fails it, which would have looked
/// exactly like a broken live path.
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

    // Same session model as the app: a root that session folders are minted
    // under, one folder per session, named by timestamp.
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

    // Ctrl-C is this command's "Stop session" button, so it must close the
    // session out properly rather than killing the process mid-write: default
    // SIGINT would leave the last crops unwritten and no `sessionEnd` line.
    // The default handler has to be disabled explicitly — a DispatchSource for
    // a signal observes it, it does not replace it.
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
    fovea-capture record — sessions → \(root)

      DOUBLE-TAP Right Option   start capturing — audio and screen, until you
                                stop it. Let go of the key and walk through as
                                many windows as you like.
      point and pause           → a candidate referent, when you are talking
      hold LEFT Option + drag   → a region referent (that drag alone is
                                swallowed, and only while a session is running)
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

  app                         The product: menu-bar app, hotkey live, events
                              written to a session folder. This is what runs
                              when Fovea.app is launched — and launching it that
                              way is what makes macOS attribute permissions to
                              Fovea rather than to your terminal.
    --out <dir>               Where sessions are minted (~/Documents/Fovea).
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
                              Hold LEFT Option and drag to circle an area.

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

                              Run this from Fovea.app, not from a terminal:
                              speech is attributed to the RESPONSIBLE process,
                              and a terminal has no speech usage description,
                              so the request aborts the binary outright.
                                open -n -a build/Fovea.app --args timing \\
                                  --wav f.wav --live --out /tmp/t.json

  diagnostics                 Version, permissions, connectors and where the
                              log is — the block the Settings button copies.
                              Contains nothing from inside a session, so it is
                              safe to paste into a bug report.

  connect [--write]           Show every coding client's state; --write
                              registers Fovea, --disconnect removes it.

  icon --out <dir>            Render the fovea mark into an .iconset. Build
                              step, not a runtime one — `make icon` runs this
                              and hands the result to iconutil.

Events go to stdout as JSON Lines. Logs go to stderr.
"""
}
