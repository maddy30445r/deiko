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
// A SESSION IS ONE CONTINUOUS RECORDING, toggled on and off.
//
//   tap Right Option        → start: audio, cursor sampling, overlay, all of it
//   point and pause         → a candidate referent, IF you are talking
//   hold Right Option+drag  → a region referent
//   tap Right Option        → stop, finish the crops, write it out
//
// It was push-to-talk until session 20260728-152834 measured what that costs:
// 23.2 of 58.7 seconds recorded nothing, because letting go of a key to switch
// windows also stops the microphone and the sampler. The transcript caught the
// user restarting a sentence verbatim across the gap.
//
// The gate that replaced the held key is SPEECH. With capture always on, every
// settle would otherwise become a referent — transit, scrolling, reading. A
// settle more than `silenceGateMs` from any narration is not recorded. This is
// the same principle the aligner runs on ("narration is the filter"), applied
// at capture time as well; the difference from the old rule about never
// deciding at capture time is that this decision is made by the user's own
// voice rather than by a heuristic about cursor movement.
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
    /// When the current lasso's drag began — the recorder sees `dragBegan`
    /// directly, so the span it emits is measured, not reconstructed.
    private var lassoStartT: Double?

    /// Referents in the CURRENT hold, reported in `holdEnd`; and across the
    /// whole session, reported in `sessionEnd`.
    private var holdReferentCount = 0
    private var sessionReferentCount = 0

    /// Settles the speech gate threw away. Counted because throwing them away
    /// is the only unrecoverable thing this app does, and until now it did it
    /// in silence — a gate calibrated wrong for someone's microphone would have
    /// looked exactly like a quiet session. Reported at the end so a run that
    /// dropped half of what you pointed at cannot pass for a normal one.
    private var gatedSettleCount = 0

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

    /// How long after speech a settle still counts as pointing. See the gate in
    /// `detectSettle`. Regions are exempt — nobody draws a loop by accident.
    ///
    /// Six seconds, not four, because of what the detector on the other side can
    /// promise. Simulated over every WAV this project has recorded, `VoiceGate`'s
    /// worst gap between voice buffers during real narration is 3924ms. Four
    /// seconds left 76ms of margin, which is not margin — the previous fixed-RMS
    /// detector opened gaps past four seconds in nine of twenty recordings and
    /// silently lost referents to it. Six is still far shorter than the pauses
    /// this is meant to reject: transit, scrolling, reading, walking away.
    private let silenceGateMs: Double = 6000

    /// Stop a forgotten session after this much unbroken silence.
    ///
    /// Push-to-talk could not be left running: letting go ended it. A toggle
    /// can, and "I walked away with the microphone live" is the failure that
    /// costs trust rather than data. Five minutes is far longer than any
    /// natural pause while describing something, and the session is written out
    /// properly rather than discarded.
    private let autoStopSilenceMs: Double = 5 * 60 * 1000

    /// Absolute ceiling on one session, independent of the microphone.
    ///
    /// The silence watchdog only fires if audio is flowing; this one fires
    /// regardless, which is the point of having both. Wispr Flow caps desktop
    /// dictation at the same 20 minutes.
    private let maximumSessionMs: Double = 20 * 60 * 1000

    /// When the current recording began — the clock for the hard ceiling, and
    /// the fallback for the silence watchdog when there is no audio at all (a
    /// mic that failed to open would otherwise leave `msSinceVoice` nil
    /// forever, and the session running with it).
    private var recordingStartedAt: Double?

    // Settle state
    private var lastPosition = Point(x: 0, y: 0)
    private var stationarySince = Clock.nowMs()
    private var hasMoved = false
    private var firedForThisRest = false
    private var recentSpeeds: [(t: Double, speed: Double)] = []

    /// How fast the cursor was moving when it came to rest here.
    ///
    /// Snapshotted at the moment motion stops, NOT read at commit time — and that
    /// is the whole fix. `recentSpeeds` keeps a 200ms window, but a settle does
    /// not fire until the cursor has been still for `dwellMs` (300ms), so by the
    /// time the old code asked for a maximum, every sample of the approach had
    /// aged out. Measured on session 20260730-004641: 18 of 25 candidates
    /// reported exactly 0, and the 7 non-zero ones were jitter inside the 8px
    /// settle radius rather than an approach at all. The aligner has been
    /// multiplying confidence by 1.05 on `approachSpeed > 800`, a branch that
    /// could never fire.
    private var approachAtRest: Double = 0

    /// The previous SAMPLE, distinct from `lastPosition` (the settle anchor).
    /// Speed must come from per-tick displacement: the anchor only re-bases
    /// after 8px of accumulated drift, so dividing distance-from-anchor by one
    /// frame's duration reported a steady 150px/s glide as ~450px/s — worst
    /// for exactly the slow deliberate approaches the feature exists to spot.
    private var previousSample: Point?

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

    /// True while capturing, held or locked.
    private(set) var isRecording = false

    /// Always 1 now — a session is one continuous recording. Kept because the
    /// wire contract and every recorded session so far carry it.
    var holdCount: Int { holdIndex }

    /// Milliseconds since speech was last heard, or nil if none yet. Drives
    /// the capture gate and rides along on every candidate.
    var msSinceVoice: Double? {
        audio.lastVoiceMs.map { Clock.nowMs() - $0 }
    }

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

    /// The close-out in progress, if any. One task, shared: `stopSession` from
    /// the menu, Quit, and a second Ctrl-C all await the SAME close rather than
    /// racing it — a second caller used to pass the `sessionDir` guard, see an
    /// already-drained task list, and finalise the session out from under the
    /// first caller while its crops were still being written.
    private var stopTask: Task<String?, Never>?

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
    ///
    /// Returns false when the directory cannot be created (denied Documents
    /// access, read-only volume) — in which case NO session starts, rather than
    /// a session that silently writes to nowhere.
    private func startSessionIfNeeded() -> Bool {
        guard sessionDir == nil else { return true }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Fixed locale: under a Hindi or Arabic system locale a plain
        // DateFormatter will happily render the year in a non-Gregorian
        // calendar with non-ASCII digits, and the folder name has to sort.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        let dir = "\(sessionRoot)/\(stamp)"
        do {
            try FileManager.default.createDirectory(
                atPath: "\(dir)/crops", withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: "\(dir)/audio", withIntermediateDirectories: true
            )
        } catch {
            Emit.event(ErrorEvent(
                "could not create session directory \(dir): \(error.localizedDescription)",
                hint: "Check that Fovea can write to \(sessionRoot) — System Settings → Privacy & Security → Files and Folders."
            ))
            return false
        }

        sessionDir = dir
        sessionId = stamp
        holdIndex = 0
        globalReferentIndex = 0
        sessionReferentCount = 0
        gatedSettleCount = 0

        // Events now belong to this session's file rather than the launch log.
        Emit.redirectToFile("\(dir)/events.jsonl")
        Emit.event(SessionEvent.start(id: stamp))
        Emit.log("▶ session \(stamp) → \(dir)")
        return true
    }

    /// Close the session out. Returns its directory so the caller can reveal it.
    ///
    /// Safe to call with no session open (the menu's Quit path does), safe to
    /// call mid-hold — the hold is ended first so its WAV is finalised and its
    /// `audioT0` recorded — and safe to call twice: concurrent callers await
    /// the same close.
    func stopSession() async -> String? {
        if let stopTask { return await stopTask.value }
        guard sessionDir != nil else { return nil }

        let task = Task { await self.closeSession() }
        stopTask = task
        let dir = await task.value
        stopTask = nil
        return dir
    }

    private func closeSession() async -> String? {
        // A lasso still being drawn is a referent the user meant to capture.
        // Commit it before teardown, or it dies on the `isRecording` guard in
        // `commitLasso` and the drag is lost.
        if isRecording, lassoPath != nil { commitLasso() }
        if isRecording { endRecording() }
        guard let dir = sessionDir, let id = sessionId else { return nil }

        // Wait for AX + crop + OCR still in flight. Awaiting releases the main
        // actor, so the tasks' own completion hops back here are free to run.
        // No NEW work can join the list meanwhile — `beginHold` refuses while
        // `stopTask` is set.
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
        if gatedSettleCount > 0 {
            Emit.log(
                "  \(gatedSettleCount) settle(s) skipped — no narration within "
                + "\(Int(silenceGateMs / 1000))s. If you were talking through those, "
                + "the microphone is not hearing you."
            )
        }

        // Back to the launch log, so anything emitted between sessions is not
        // silently appended to a session the user considers finished.
        Emit.redirectToFile(Paths.launchLog)

        sessionDir = nil
        sessionId = nil
        // Tell the hotkey, whatever route brought us here. A watchdog stop or
        // a Quit never passed through the gesture, and leaving it believing a
        // session is live means Option-drags stay swallowed afterwards.
        hotkey.noteSessionEnded()
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
        case .recordingStarted:
            beginRecording()
        case .recordingStopped:
            Task { _ = await self.stopSession() }
        case .dragBegan(let p):
            guard isRecording else { break }
            lassoPath = [p]
            lassoStartT = Clock.nowMs()
        case .dragMoved(let p):
            lassoPath?.append(p)
        case .dragEnded(let p):
            guard lassoPath != nil else { break }
            lassoPath?.append(p)
            commitLasso()
        case .scrolled:
            // Reported unconditionally by the tap now; only meaningful while
            // a session is live.
            if isRecording { lastScrollT = Clock.nowMs() }
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }

        // A start that lands while the previous session is still closing WAITS
        // for it rather than being dropped. `closeSession` is suspended on the
        // crop drain at that moment and can take a second or two; silently
        // ignoring the gesture would look like the hotkey had stopped working,
        // and starting on top of the closing session would split its events
        // across two files.
        if let stopTask {
            Task { @MainActor in
                _ = await stopTask.value
                self.beginRecording()
            }
            return
        }

        // The toggle is what brings a session into existence.
        guard startSessionIfNeeded(), let sessionDir, let sessionId else { return }

        isRecording = true
        recordingStartedAt = Clock.nowMs()
        holdReferentCount = 0
        holdIndex = 1

        // ONE WAV for the whole session. It used to be one per hold, because a
        // hold was an utterance; a session is now a single continuous recording,
        // so there is one audio timeline and one `audioT0`. The wire still says
        // `hold: 1` — downstream pairs holdStart/holdEnd to find the audio, and
        // that pairing is worth keeping stable.
        var audioPath: String?
        let path = "\(sessionDir)/audio/session.wav"
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
        Emit.log("● recording — point at things and talk. Hold LEFT Option and "
            + "drag to circle an area. Tap Right Option to stop.")
        onStateChange?()

        trail.removeAll()
        pulses.removeAll()
        recentSpeeds.removeAll()
        approachAtRest = 0
        hasMoved = false
        firedForThisRest = false
        lastPosition = AXProbe.cursorLocation()
        previousSample = nil
        stationarySince = Clock.nowMs()

        // Get Chromium's tree built before the first referent needs it, rather
        // than making that referent wait ~300ms for it.
        lastFrontPid = AXProbe.prePokeFrontmost()

        overlay.show()
        sampler = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        // Teardown FIRST, unconditionally. The sampler, overlay and microphone
        // must stop no matter what state the session is in — a guard that
        // returned before this once left the mic running, which is the one
        // promise this product cannot break.
        isRecording = false
        recordingStartedAt = nil
        sampler?.invalidate()
        sampler = nil
        overlay.hide()
        lassoPath = nil
        let audioT0 = audio.stop()

        guard let sessionId else { return }
        Emit.event(HoldEvent.end(
            id: sessionId, hold: holdIndex,
            referentCount: holdReferentCount, audioT0: audioT0
        ))
        Emit.log("○ stopped — \(holdReferentCount) referent(s)"
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
        let step = previousSample.map {
            hypot(position.x - $0.x, position.y - $0.y)
        } ?? 0
        previousSample = position
        recentSpeeds.append((now, step / sampleInterval))
        recentSpeeds.removeAll { now - $0.t > 200 }

        trail.append(TrailPoint(position: position, t: now))
        trail.removeAll { now - $0.t > 700 }
        pulses.removeAll { now - $0.t > 450 }

        if lassoPath == nil {
            detectSettle(position: position, moved: moved, now: now)
        }

        // Silence watchdog. `msSinceVoice` is nil until the first buffer lands
        // (and forever if the mic never opened), so fall back to the time since
        // recording began rather than never firing.
        let runningFor = recordingStartedAt.map { now - $0 } ?? 0
        let quietFor = msSinceVoice ?? runningFor
        if quietFor > autoStopSilenceMs {
            Emit.log("■ stopping — \(Int(autoStopSilenceMs / 60000)) minutes with no narration")
            Task { _ = await self.stopSession() }
        } else if runningFor > maximumSessionMs {
            Emit.log("■ stopping — \(Int(maximumSessionMs / 60000))-minute session limit")
            Task { _ = await self.stopSession() }
        }

        overlay.update(
            cursor: position, trail: trail, lasso: lassoPath,
            pulses: pulses
        )
    }

    private func detectSettle(position: Point, moved: Double, now: Double) {
        if moved > settleRadius {
            lastPosition = position
            stationarySince = now
            // Refreshed on every moving frame, so when the cursor finally stops
            // this holds the speed it was travelling at just beforehand. Reading
            // it here is what makes the 200ms window the right window.
            approachAtRest = recentSpeeds.map(\.speed).max() ?? 0
            hasMoved = true
            firedForThisRest = false
            return
        }

        guard hasMoved, !firedForThisRest, now - stationarySince >= dwellMs else { return }
        firedForThisRest = true

        // THE CAPTURE GATE. A settle with no narration anywhere near it is not
        // a pointing act — it is transit, reading, scrolling, or a hand at
        // rest. Under push-to-talk the held key said "I am describing
        // something now"; with the session always on, recent speech says it
        // instead. "Narration is the filter" was always the design; this
        // applies it at capture time as well as at alignment time.
        //
        // The window is deliberately wide. The aligner allows a referent to
        // sit up to 2s after the word that named it and 1.5s before, so
        // anything tighter would drop referents the aligner could still have
        // bound. Losing one is unrecoverable; an extra crop costs a few
        // milliseconds and some disk.
        //
        // No audio at all (mic denied, or the first buffer not yet in) means
        // capture EVERYTHING. A silent gate would turn one permission problem
        // into a session that records nothing and says nothing about why.
        if let quietFor = msSinceVoice, quietFor > silenceGateMs {
            gatedSettleCount += 1
            return
        }

        commitPoint(at: position, dwell: now - stationarySince, now: now)
    }

    // ── Committing referents ────────────────────────────────────────────────

    private func commitPoint(at position: Point, dwell: Double, now: Double) {
        let features = CandidateFeatures(
            dwellMs: dwell,
            // Taken from the moment the cursor stopped, not recomputed now — see
            // `approachAtRest`. Recomputing here is what made this field a lie:
            // the window it reads has been full of stationary samples for the
            // whole dwell.
            approachSpeed: approachAtRest,
            msSinceAppSwitch: lastAppSwitchT.map { now - $0 },
            msSinceScroll: lastScrollT.map { now - $0 },
            msSinceVoice: msSinceVoice
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
        resolve(shape: Shape.point(position), span: nil)
    }

    private func commitLasso() {
        let startT = lassoStartT
        lassoStartT = nil
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

        let now = Clock.nowMs()
        pulses.append(
            Pulse(position: shape.origin, t: now, isRegion: shape.kind == .region)
        )
        holdReferentCount += 1
        sessionReferentCount += 1
        // The measured drag interval rides along for regions: the narration for
        // a lasso happens while DRAWING it, and downstream needs the real span,
        // not a reconstruction.
        let span = shape.kind == .region
            ? startT.map { TimeSpan(start: $0, end: now) }
            : nil
        resolve(shape: shape, span: span)
    }

    /// AX + crop, off the sampling path. Resolution can take a few hundred
    /// milliseconds; blocking here would freeze the overlay and drop cursor
    /// samples mid-gesture — the two things the user can actually see.
    ///
    /// The task handle is retained so `stopSession` can wait on it. The session
    /// directory is read HERE and captured by value, not read inside the task —
    /// by the time a slow OCR finishes, `sessionDir` may already be nil.
    private func resolve(shape: Shape, span: TimeSpan?) {
        globalReferentIndex += 1
        let hold = holdIndex
        let index = globalReferentIndex
        let dir = sessionDir

        let task = Task.detached { [captureCrops] in
            var event = shape.kind == .region
                ? AXProbe.probeRegion(shape)
                : AXProbe.probePoint(shape.origin)
            if let span { event = event.with(span: span) }

            if captureCrops {
                let (rect, fromAX) = Capture.rect(
                    for: shape, snapshot: event.snapshot, screenArea: AXProbe.screenArea()
                )
                let path = dir.map {
                    "\($0)/crops/h\(String(format: "%02d", hold))-r\(String(format: "%03d", index)).png"
                }

                // Always. Deciding when accessibility text is "enough" is what
                // cost us referents twice — see the note where `OCR.isNeeded`
                // used to live. This runs on a detached task; nothing waits on
                // it but the end of the session.
                let crop = await Capture.crop(
                    shape: shape,
                    snapshot: event.snapshot,
                    outputPath: path,
                    runOCR: true,
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
