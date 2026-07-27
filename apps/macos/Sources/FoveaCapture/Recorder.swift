import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE RECORDER
//
// Holds a session together: hotkey → overlay → cursor sampling → candidates and
// region referents → events on stdout.
//
// The governing decision is that it does NOT decide. Every settle is emitted as
// a candidate with its features; which candidates are real referents is the
// alignment engine's call, made against the narration. Over-capturing is cheap;
// discarding a real referent at capture time is unrecoverable.
//
// TWO NESTED LIFETIMES, and the distinction is the reason this file changed:
//
//   HOLD     press Right Option → release. One utterance, one WAV.
//   SESSION  first hold → "Stop session". One directory, one referent stack.
//
// A session used to be a hold, and the directory was created at launch. That
// made every app launch mint a folder whether or not anything was recorded, and
// left the user with no moment that meant "I have finished describing this" —
// which is exactly the moment plan generation needs to hang off.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class Recorder {

    // Settle detection. Deliberately the same numbers as `ax-probe --watch`,
    // and deliberately tunable — T0.2 exists partly to tell us they're wrong.
    var settleRadius: Double = 8
    var dwellMs: Double = 300

    /// Cursor sampling rate. 60Hz because the overlay draws from the same
    /// samples; the aligner needs far less.
    private let sampleInterval = 1.0 / 60.0

    private let hotkey = Hotkey()
    private let overlay = Overlay()
    private let audio = Audio()

    /// Where session directories are minted. NOT a session directory itself —
    /// nothing is written here until the first hold.
    let sessionRoot: String
    private let captureCrops: Bool

    private var sampler: Timer?
    private var trail: [TrailPoint] = []
    private var pulses: [Pulse] = []

    private var lassoPath: [Point]?

    /// Referents in the CURRENT hold, reported in `holdEnd`; and across the
    /// whole session, reported in `sessionEnd`.
    private var holdReferentCount = 0
    private var sessionReferentCount = 0

    /// Which hold we're on, and a counter that runs for the whole session. Crop
    /// filenames are built from both.
    ///
    /// The referent counter is per SESSION rather than per hold because a
    /// per-hold counter restarted at 1 each time and five holds all wrote
    /// `referent-001.png` over each other: 30 referents produced 12 files and
    /// 18 crops were destroyed. The hold number stays in the name because it is
    /// also the natural grouping for the referent stack.
    private var holdIndex = 0
    private var globalReferentIndex = 0

    /// A drag smaller than this is a flick, not a circle. One recorded "region"
    /// was 170x1 points from a single grid sample.
    private let minimumRegionArea: Double = 400

    // Settle state
    private var lastPosition = Point(x: 0, y: 0)
    private var stationarySince = Clock.nowMs()
    private var hasMoved = false
    private var firedForThisRest = false
    private var recentSpeeds: [(t: Double, speed: Double)] = []

    // Noise context
    private var lastAppSwitchT: Double?
    private var lastScrollT: Double?
    private var lastFrontPid: pid_t?

    init(sessionRoot: String, captureCrops: Bool) {
        self.sessionRoot = sessionRoot
        self.captureCrops = captureCrops
    }

    // ── Session state, as the menu bar needs to see it ──────────────────────

    /// The directory of the OPEN session, or nil when there is no session. This
    /// is the single source of truth for "is a session in progress" — the menu
    /// has no separate flag to drift out of sync with.
    private(set) var sessionDir: String?

    /// Folder name of the open session, e.g. `20260728-011253`. Also its id.
    private(set) var sessionId: String?

    /// True while the hotkey is actually held.
    private(set) var isRecording = false

    /// Holds completed plus the one in progress — shown in the menu.
    var holdCount: Int { holdIndex }

    /// Referents captured so far this session — shown in the menu.
    var referentCount: Int { sessionReferentCount }

    /// Fired whenever any of the above changes, so the menu-bar icon and items
    /// reflect what is genuinely happening rather than what was last clicked.
    var onStateChange: (() -> Void)?

    /// Crop + AX resolution runs off the sampling path in detached tasks. Their
    /// handles are kept so `stopSession` can wait for them: the stop button
    /// reveals the folder in Finder, and a folder revealed while three crops are
    /// still being written is a folder the user sees as incomplete.
    private var pendingResolves: [Int: Task<Void, Never>] = [:]

    func start() -> Bool {
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        return hotkey.start()
    }

    // ── Session lifetime ────────────────────────────────────────────────────

    /// Mints `<root>/<stamp>` on the FIRST hold and not before.
    ///
    /// Creating it at launch instead meant every run of the app left a folder
    /// behind with a 0-byte `events.jsonl`, whether or not anything was ever
    /// recorded — three of them accumulated in a single evening.
    private func startSessionIfNeeded() {
        guard sessionDir == nil else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Fixed locale: under a Hindi or Arabic system locale a plain
        // DateFormatter will happily render the year in a non-Gregorian
        // calendar with non-ASCII digits, and the folder name has to sort.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        let dir = "\(sessionRoot)/\(stamp)"
        try? FileManager.default.createDirectory(
            atPath: "\(dir)/crops", withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            atPath: "\(dir)/audio", withIntermediateDirectories: true
        )

        sessionDir = dir
        sessionId = stamp
        holdIndex = 0
        globalReferentIndex = 0
        sessionReferentCount = 0

        // Events now belong to this session's file rather than the launch log.
        Emit.redirectToFile("\(dir)/events.jsonl")
        Emit.event(SessionEvent.start(id: stamp, directory: dir))
        Emit.log("▶ session \(stamp) → \(dir)")
    }

    /// Close the session out. Returns its directory so the caller can reveal it.
    ///
    /// Safe to call with no session open (the menu's Quit path does), and safe
    /// to call mid-hold — the hold is ended first so its WAV is finalised and
    /// its `audioT0` recorded.
    func stopSession() async -> String? {
        if isRecording { endHold() }
        guard let dir = sessionDir, let id = sessionId else { return nil }

        // Wait for AX + crop + OCR still in flight. Awaiting releases the main
        // actor, so the tasks' own completion hops back here are free to run.
        let outstanding = pendingResolves
        pendingResolves = [:]
        if !outstanding.isEmpty {
            Emit.log("  …finishing \(outstanding.count) crop(s)")
        }
        for task in outstanding.values { await task.value }

        Emit.event(SessionEvent.end(
            id: id, holdCount: holdIndex, referentCount: sessionReferentCount
        ))
        Emit.log("■ session \(id) — \(holdIndex) hold(s), \(sessionReferentCount) referent(s)")

        // Back to the launch log, so anything emitted between sessions is not
        // silently appended to a session the user considers finished.
        Emit.redirectToFile(Paths.launchLog)

        sessionDir = nil
        sessionId = nil
        onStateChange?()
        return dir
    }

    /// Stop listening entirely. The hotkey tap is torn down rather than left
    /// running and ignored — an input peripheral that claims to be off should
    /// not still be reading your keystrokes.
    func stop() async {
        _ = await stopSession()
        hotkey.stop()
    }

    // ── Gesture handling ────────────────────────────────────────────────────

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            beginHold()
        case .released:
            endHold()
        case .dragBegan(let p):
            lassoPath = [p]
        case .dragMoved(let p):
            lassoPath?.append(p)
        case .dragEnded(let p):
            lassoPath?.append(p)
            commitLasso()
        case .scrolled:
            lastScrollT = Clock.nowMs()
        }
    }

    private func beginHold() {
        // The first hold is what brings a session into existence.
        startSessionIfNeeded()
        guard let sessionDir, let sessionId else { return }

        isRecording = true
        holdReferentCount = 0
        holdIndex += 1

        // One WAV per hold. Holds are separate utterances, and keeping them
        // separate means each transcript's word timings are offsets from that
        // hold's own t0 rather than from a stitched timeline.
        var audioPath: String?
        let path = "\(sessionDir)/audio/hold-\(String(format: "%02d", holdIndex)).wav"
        do {
            try audio.start(path: path)
            audioPath = path
        } catch {
            Emit.event(ErrorEvent(
                "audio capture failed: \(error.localizedDescription)",
                hint: "System Settings → Privacy & Security → Microphone, and make sure Fovea is switched on. Capture continues without narration, but the session cannot be aligned."
            ))
        }

        Emit.event(HoldEvent.start(id: sessionId, hold: holdIndex, audioPath: audioPath))
        Emit.log("● recording — point, or hold the mouse button and circle an area")
        onStateChange?()

        trail.removeAll()
        pulses.removeAll()
        recentSpeeds.removeAll()
        hasMoved = false
        firedForThisRest = false
        lastPosition = AXProbe.cursorLocation()
        stationarySince = Clock.nowMs()

        // Get Chromium's tree built before the first referent needs it, rather
        // than making that referent wait ~300ms for it.
        lastFrontPid = AXProbe.prePokeFrontmost()

        overlay.show()
        sampler = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
    }

    private func endHold() {
        guard isRecording, let sessionId else { return }
        isRecording = false
        sampler?.invalidate()
        sampler = nil
        overlay.hide()
        lassoPath = nil

        let audioT0 = audio.stop()
        Emit.event(HoldEvent.end(
            id: sessionId, hold: holdIndex,
            referentCount: holdReferentCount, audioT0: audioT0
        ))
        Emit.log("○ hold \(holdIndex) — \(holdReferentCount) referent(s)"
            + (audioT0 == nil ? " (no audio)" : ""))
        onStateChange?()
    }

    // ── Sampling ────────────────────────────────────────────────────────────

    private func sample() {
        let now = Clock.nowMs()
        let position = AXProbe.cursorLocation()
        Emit.event(CursorEvent(position))

        // App-switch detection rides on the sampler rather than a notification
        // observer: it only needs to be accurate to a frame, and this keeps the
        // whole session on one clock.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPid != lastFrontPid {
            lastFrontPid = frontPid
            lastAppSwitchT = now
            if let frontPid { AXProbe.enableManualAccessibility(pid: frontPid) }
        }

        let moved = hypot(position.x - lastPosition.x, position.y - lastPosition.y)
        let speed = moved / sampleInterval
        recentSpeeds.append((now, speed))
        recentSpeeds.removeAll { now - $0.t > 200 }

        trail.append(TrailPoint(position: position, t: now))
        trail.removeAll { now - $0.t > 700 }
        pulses.removeAll { now - $0.t > 450 }

        if lassoPath == nil {
            detectSettle(position: position, moved: moved, now: now)
        }

        overlay.update(cursor: position, trail: trail, lasso: lassoPath, pulses: pulses)
    }

    private func detectSettle(position: Point, moved: Double, now: Double) {
        if moved > settleRadius {
            lastPosition = position
            stationarySince = now
            hasMoved = true
            firedForThisRest = false
            return
        }

        guard hasMoved, !firedForThisRest, now - stationarySince >= dwellMs else { return }
        firedForThisRest = true
        commitPoint(at: position, dwell: now - stationarySince, now: now)
    }

    // ── Committing referents ────────────────────────────────────────────────

    private func commitPoint(at position: Point, dwell: Double, now: Double) {
        // Approach speed over the window BEFORE the stop, which is what
        // separates decelerating-to-point from pausing-mid-sweep.
        let approach = recentSpeeds.map(\.speed).max() ?? 0

        let features = CandidateFeatures(
            dwellMs: dwell,
            approachSpeed: approach,
            msSinceAppSwitch: lastAppSwitchT.map { now - $0 },
            msSinceScroll: lastScrollT.map { now - $0 }
        )

        let app = NSWorkspace.shared.frontmostApplication.map {
            AppIdentity(
                pid: $0.processIdentifier,
                bundleId: $0.bundleIdentifier,
                name: $0.localizedName
            )
        }
        Emit.event(CandidateEvent(position: position, features: features, app: app))

        pulses.append(Pulse(position: position, t: now, isRegion: false))
        holdReferentCount += 1
        sessionReferentCount += 1
        resolve(shape: Shape.point(position))
    }

    private func commitLasso() {
        guard let path = lassoPath, path.count >= 3 else {
            lassoPath = nil
            return
        }
        lassoPath = nil

        var shape = Shape.region(path: path)

        // A drag too small to enclose anything is a flick, not a circle — it
        // grid-samples to a single point and produces a 1px-tall "region".
        // Treat it as what the user actually did: point at somewhere.
        if shape.bounds.width * shape.bounds.height < minimumRegionArea {
            shape = Shape.point(shape.origin)
        }

        pulses.append(
            Pulse(position: shape.origin, t: Clock.nowMs(), isRegion: shape.kind == .region)
        )
        holdReferentCount += 1
        sessionReferentCount += 1
        resolve(shape: shape)
    }

    /// AX + crop, off the sampling path. Resolution can take a few hundred
    /// milliseconds; blocking here would freeze the overlay and drop cursor
    /// samples mid-gesture — the two things the user can actually see.
    ///
    /// The task handle is retained so `stopSession` can wait on it. The session
    /// directory is read HERE and captured by value, not read inside the task —
    /// by the time a slow OCR finishes, `sessionDir` may already be nil.
    private func resolve(shape: Shape) {
        globalReferentIndex += 1
        let hold = holdIndex
        let index = globalReferentIndex
        let dir = sessionDir

        let task = Task.detached { [captureCrops] in
            var event = shape.kind == .region
                ? AXProbe.probeRegion(shape)
                : AXProbe.probePoint(shape.origin)

            if captureCrops {
                let (rect, fromAX) = Capture.rect(
                    for: shape, snapshot: event.snapshot, screenArea: AXProbe.screenArea()
                )
                let path = dir.map {
                    "\($0)/crops/h\(String(format: "%02d", hold))-r\(String(format: "%03d", index)).png"
                }

                // A region ALWAYS gets OCR. "Capture this whole area" cannot be
                // represented by one AX string, and relying on the conditional
                // rule here silently lost referents: a git-blame annotation
                // ("You, 6 hours ago") counted as "AX has text" and suppressed
                // OCR for an entire circled region of code.
                let runOCR = shape.kind == .region || OCR.isNeeded(for: event.snapshot)

                let crop = await Capture.crop(
                    shape: shape,
                    snapshot: event.snapshot,
                    outputPath: path,
                    runOCR: runOCR,
                    rectFromAX: fromAX,
                    rect: rect
                )
                event = event.with(crop: crop)
            }

            Emit.event(event)

            // Retire the handle. `Task` exposes no "did it finish" flag, so a
            // plain array would grow for the life of the session; letting each
            // task remove itself keeps the set to what is genuinely in flight.
            await MainActor.run { [weak self] in self?.pendingResolves[index] = nil }
        }

        pendingResolves[index] = task
    }
}

/// Fixed locations the app writes to outside a session.
enum Paths {
    /// Where events go when no session is open. An app launched from Finder has
    /// no stdout, so without this a permission failure at startup would vanish
    /// — and the alternative, opening a session file at launch, is precisely
    /// the behaviour that littered `~/Documents/Fovea` with empty folders.
    static let launchLog =
        "\(NSHomeDirectory())/Library/Logs/Fovea/launch.jsonl"
}
