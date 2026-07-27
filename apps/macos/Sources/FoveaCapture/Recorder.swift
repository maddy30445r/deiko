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
    private let sessionId: String
    private let outputDir: String?
    private let captureCrops: Bool

    private var sampler: Timer?
    private var trail: [TrailPoint] = []
    private var pulses: [Pulse] = []

    private var lassoPath: [Point]?

    /// Referents in the CURRENT hold — reported in `sessionEnd`.
    private var referentCount = 0

    /// Which hold we're on, and a counter that never resets for the life of the
    /// process. Crop filenames are built from both.
    ///
    /// Every press of the hotkey is a new session, so a per-session counter
    /// restarted at 1 each time and five holds all wrote `referent-001.png`
    /// over each other: 30 referents produced 12 files and 18 crops were
    /// destroyed. The hold number is kept in the name because it is also the
    /// natural grouping for the referent stack later.
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

    init(sessionId: String, outputDir: String?, captureCrops: Bool) {
        self.sessionId = sessionId
        self.outputDir = outputDir
        self.captureCrops = captureCrops
    }

    /// Where sessions are written — the menu bar's "Open sessions folder".
    var outputRoot: String? { outputDir }

    /// True while the hotkey is actually held, not merely while armed.
    private(set) var isRecording = false

    /// Fired when a session starts or ends, so the menu-bar icon can reflect
    /// what is genuinely happening rather than what was last clicked.
    var onSessionStateChange: ((Bool) -> Void)?

    func start() -> Bool {
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        guard hotkey.start() else { return false }
        return true
    }

    /// Tear the tap down rather than ignoring events. "Paused" has to mean the
    /// keyboard is no longer being read, or the word is a lie.
    func stop() {
        if isRecording { endSession() }
        hotkey.stop()
    }

    // ── Gesture handling ────────────────────────────────────────────────────

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            beginSession()
        case .released:
            endSession()
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

    private func beginSession() {
        isRecording = true
        onSessionStateChange?(true)
        referentCount = 0
        holdIndex += 1

        // One WAV per hold. Holds are separate utterances, and keeping them
        // separate means each transcript's word timings are offsets from that
        // hold's own t0 rather than from a stitched timeline.
        var audioPath: String?
        if let outputDir {
            let path = "\(outputDir)/audio/hold-\(String(format: "%02d", holdIndex)).wav"
            do {
                try audio.start(path: path)
                audioPath = path
            } catch {
                Emit.event(ErrorEvent(
                    "audio capture failed: \(error.localizedDescription)",
                    hint: "System Settings → Privacy & Security → Microphone. Grant the terminal you launched from. Capture continues without narration, but the session cannot be aligned."
                ))
            }
        }

        Emit.event(SessionEvent.start(id: sessionId, hold: holdIndex, audioPath: audioPath))
        Emit.log("● recording — point, or hold the mouse button and circle an area")

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

    private func endSession() {
        isRecording = false
        onSessionStateChange?(false)
        sampler?.invalidate()
        sampler = nil
        overlay.hide()
        lassoPath = nil

        let audioT0 = audio.stop()
        Emit.event(SessionEvent.end(
            id: sessionId, hold: holdIndex,
            referentCount: referentCount, audioT0: audioT0
        ))
        Emit.log("○ stopped — \(referentCount) referent(s)"
            + (audioT0 == nil ? " (no audio)" : ""))
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
        referentCount += 1
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
        referentCount += 1
        resolve(shape: shape)
    }

    /// AX + crop, off the sampling path. Resolution can take a few hundred
    /// milliseconds; blocking here would freeze the overlay and drop cursor
    /// samples mid-gesture — the two things the user can actually see.
    private func resolve(shape: Shape) {
        globalReferentIndex += 1
        let hold = holdIndex
        let index = globalReferentIndex

        Task.detached { [captureCrops, outputDir] in
            var event = shape.kind == .region
                ? AXProbe.probeRegion(shape)
                : AXProbe.probePoint(shape.origin)

            if captureCrops {
                let (rect, fromAX) = Capture.rect(
                    for: shape, snapshot: event.snapshot, screenArea: AXProbe.screenArea()
                )
                let path = outputDir.map {
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
        }
    }
}
