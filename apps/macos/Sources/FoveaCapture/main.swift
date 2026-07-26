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

        var iterator = Array(rest).makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else { continue }
            let name = String(token.dropFirst(2))
            // `--flag=value` and `--flag value` both work; a bare `--flag` is a bool.
            if let eq = name.firstIndex(of: "=") {
                flags[String(name[name.startIndex..<eq])] = String(name[name.index(after: eq)...])
            } else if let next = iterator.next() {
                if next.hasPrefix("--") {
                    bools.insert(name)
                    if let inner = String(next.dropFirst(2)).split(separator: "=").first {
                        bools.insert(String(inner))
                    }
                } else {
                    flags[name] = next
                }
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
    runAXProbe(args)

case "help", "--help", "-h":
    Emit.log(usage)

default:
    Emit.event(ErrorEvent("unknown subcommand '\(args.subcommand)'", hint: "try: fovea-capture help"))
    Emit.log(usage)
    exit(2)
}

// ─────────────────────────────────────────────────────────────────────────────

func runAXProbe(_ args: Args) {
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

    if let delay = args.double("delay") {
        Emit.log("waiting \(delay)s — switch to the app you want to probe…")
        Thread.sleep(forTimeInterval: delay)
    }

    func probeOnce() {
        let cursor = AXProbe.cursorLocation()
        let event: ProbeEvent
        if let radius = regionRadius {
            event = AXProbe.probeRegion(
                Shape.region(path: circlePath(around: cursor, radius: radius)),
                allowManualRetry: allowManual
            )
        } else {
            event = AXProbe.probePoint(cursor, allowManualRetry: allowManual)
        }
        Emit.event(event)
        if args.has("verbose") { Emit.log(summarize(event)) }
    }

    guard args.has("watch") else {
        probeOnce()
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

    while true {
        usleep(pollMs * 1000)
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
            probeOnce()
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

    guard snap.resolved, let first = snap.elements.first else {
        return "  ✗ \(app): \(snap.error ?? "unresolved") (\(timing))\(flag)"
    }

    let text = [first.value, first.title, first.elementDescription, first.selectedText]
        .compactMap { $0 }
        .first ?? "—"
    let clipped = text.count > 70 ? String(text.prefix(70)) + "…" : text
    let counts = snap.samplesTested.map { "\(snap.uniqueElements ?? 0) elems / \($0) samples" } ?? (first.role ?? "?")

    return "  ✓ \(app): \(counts) · \(first.role ?? "?") · \"\(clipped.replacingOccurrences(of: "\n", with: "⏎"))\" (\(timing))\(flag)"
}

let usage = """
fovea-capture \(FoveaVersion.current)

  hello                       Handshake event on stdout (checks AX trust).

  ax-probe [options]          Resolve what the cursor is pointing at.
    --watch                   Probe continuously, on each cursor settle.
    --delay <sec>             Wait before probing (time to switch apps).
    --region <radius>         Probe a circular region instead of a point.
    --no-manual               Do NOT set AXManualAccessibility. Use this to
                              tell "works natively" from "works once poked" —
                              that distinction is the whole AX gate.
    --settle-radius <px>      Movement under this counts as stationary (6).
    --dwell <ms>              Rest time before a settle fires (350).
    --verbose                 Human summary on stderr alongside the JSON.

Events go to stdout as JSON Lines. Logs go to stderr.
"""
