import AppKit
import Foundation
import DeikoGesture

/// What a closed session captured, as the recorder knew it at close. The orb's working readout shows
/// this while the pipeline is still transcribing.
struct SessionStats {
    /// Wall time from session start to close. Nil for a reopened session,
    /// whose original start this launch may never have seen.
    let durationMs: Double?
    let referentCount: Int
}

/// Holds a session together: hotkey, overlay, cursor sampling, candidates and region referents, and the
/// events written to stdout.
///
/// It does not decide what is a referent. Every settle is emitted as a candidate with its features and the
/// alignment engine decides against the narration: over-capturing is cheap, and discarding a real referent
/// at capture time is unrecoverable.
///
/// A session is one continuous recording, toggled by tapping Right Option. Pointing and pausing records a
/// candidate referent if the user is talking; holding Left Option and moving draws a stroke (lasso, arrow,
/// scribble).
///
/// The one capture-time gate is speech: a settle more than `silenceGateMs` from any narration is not
/// recorded, so transit, scrolling and reading do not become referents.
@MainActor
final class Recorder {

    // Settle detection. The same numbers as `ax-probe --watch`, and tunable.
    var settleRadius: Double = 8
    var dwellMs: Double = 300

    /// Cursor sampling rate. 60Hz because the overlay draws from the same
    /// samples; the aligner needs far less.
    private let sampleInterval = 1.0 / 60.0

    private let hotkey = Hotkey()
    private let overlay = Overlay()
    private let audio = Audio()

    /// Where session directories are minted. Not a session directory itself: nothing is written here
    /// until the first hold.
    let sessionRoot: String
    private let captureCrops: Bool

    private var sampler: Timer?
    private var pulses: [Pulse] = []

    private var lassoPath: [Point]?
    /// When the current stroke began. The recorder sees `drawKeyDown` directly, so the emitted span is
    /// measured, not reconstructed.
    private var lassoStartT: Double?

    /// A stroke: Left Option held, cursor moving. It is only a candidate until the cursor is
    /// `minHoverStrokePt` from where the key went down, since Option is also Option+Backspace,
    /// Option+arrow and `@ [ ] { }` on most non-US layouts, and none of those may flash ink. Once promoted
    /// it is handed to `lassoPath` and is an ordinary stroke.
    private var hoverPath: [Point]?
    private var hoverStartT: Double?
    private var hoverPromoted = false
    /// Tunable on purpose, like `settleRadius`: hands and trackpads differ.
    var minHoverStrokePt: Double = 24

    /// Referents in the current hold, reported in `holdEnd`; and across the whole session, reported in
    /// `sessionEnd`.
    private var holdReferentCount = 0
    private var sessionReferentCount = 0

    /// Settles the speech gate threw away. Counted because discarding them is the one unrecoverable
    /// thing this app does, and a gate miscalibrated for someone's microphone would otherwise look like a
    /// quiet session. Reported at the end.
    private var gatedSettleCount = 0

    /// Which hold we are on, and a counter that runs for the whole session; crop filenames use both. The
    /// referent counter is per session, not per hold, so holds cannot overwrite each other's
    /// `referent-001.png`. The hold number stays in the name as the natural grouping for the referent stack.
    private var holdIndex = 0
    private var globalReferentIndex = 0

    /// Marks numbered in capture order across the session — the badge number.
    /// Separate from `globalReferentIndex`, which also counts plain settles.
    private var markIndex = 0

    /// How long after speech a settle still counts as pointing; see the gate in `detectSettle`. Regions
    /// are exempt: nobody draws a loop by accident. Six seconds leaves real margin over the longest gap
    /// `VoiceGate` leaves between voice buffers in real narration (about 3.9s), and is still far shorter
    /// than the pauses this rejects: transit, scrolling, reading, walking away.
    private let silenceGateMs: Double = 6000

    /// Stop a forgotten session after this much unbroken silence. A microphone left live is the failure
    /// that costs trust, and five minutes is far longer than any natural pause while describing something.
    /// The session is written out properly, not discarded.
    private let autoStopSilenceMs: Double = 5 * 60 * 1000

    /// Absolute ceiling on one session, independent of the microphone. The silence watchdog only fires
    /// while audio is flowing; this one fires regardless.
    private let maximumSessionMs: Double = 20 * 60 * 1000

    /// When the current recording began: the clock for the hard ceiling, and the fallback for the silence
    /// watchdog when there is no audio (a mic that failed to open would otherwise leave `msSinceVoice` nil
    /// forever).
    private var recordingStartedAt: Double?

    /// When the open session was minted, for the stats handed to the orb at close. Nil for reopened
    /// sessions; see `reopenSession`.
    private var sessionStartedMs: Double?

    // Settle state
    private var lastPosition = Point(x: 0, y: 0)
    private var stationarySince = Clock.nowMs()
    private var hasMoved = false
    private var firedForThisRest = false
    private var recentSpeeds: [(t: Double, speed: Double)] = []

    /// How fast the cursor was moving when it came to rest here. Snapshotted when motion stops, not read
    /// at commit time: `recentSpeeds` keeps a 200ms window but a settle fires only after `dwellMs` (300ms)
    /// of stillness, so by then every sample of the approach has aged out and the maximum would read 0.
    private var approachAtRest: Double = 0

    /// The previous sample, distinct from `lastPosition` (the settle anchor). Speed must come from
    /// per-tick displacement: the anchor re-bases only after 8px of drift, so distance-from-anchor over one
    /// frame's duration overstates slow, deliberate approaches.
    private var previousSample: Point?

    // Noise context
    private var lastAppSwitchT: Double?
    private var lastScrollT: Double?
    private var lastFrontPid: pid_t?

    init(sessionRoot: String, captureCrops: Bool) {
        self.sessionRoot = sessionRoot
        self.captureCrops = captureCrops
    }

    // MARK: - Session state (read by the menu bar)

    /// The directory of the open session, or nil when there is no session. The single source of truth for
    /// "is a session in progress": the menu has no separate flag to drift out of sync.
    private(set) var sessionDir: String?

    /// Folder name of the open session (`yyyyMMdd-HHmmss`). Also its id.
    private(set) var sessionId: String?

    /// True while capturing, held or locked.
    private(set) var isRecording = false

    /// Always 1: a session is one continuous recording. Kept because the wire contract and every recorded
    /// session carry it.
    var holdCount: Int { holdIndex }

    /// Milliseconds since speech was last heard, or nil if none yet. Drives
    /// the capture gate and rides along on every candidate.
    var msSinceVoice: Double? {
        audio.lastVoiceMs.map { Clock.nowMs() - $0 }
    }

    /// Referents captured so far this session — shown in the menu.
    var referentCount: Int { sessionReferentCount }

    /// How long the open session has been running, for the menu's live clock.
    /// Nil with no session, and for reopened ones (original start unknown).
    var sessionElapsedMs: Double? {
        sessionStartedMs.map { Clock.nowMs() - $0 }
    }

    /// Fired whenever any of the above changes, so the menu-bar icon and items
    /// reflect what is genuinely happening rather than what was last clicked.
    var onStateChange: (() -> Void)?

    /// Fired once with the session directory when a session has fully closed: crops written, WAV
    /// finalised, `sessionEnd` emitted. The review window hangs off this. The stats ride along because the
    /// orb's working readout wants them before the pipeline has produced a digest, by which time this
    /// class has reset its counters.
    var onSessionClosed: ((String, SessionStats) -> Void)?

    /// Consulted when the start gesture arrives with no session open. Return true to claim it: the orb
    /// does while it is showing a finished brief, routing the recording into that session as another
    /// hold. Returning false starts a fresh session.
    var onStartGestureWhileIdle: (() -> Bool)?

    /// Crop and AX resolution run off the sampling path in detached tasks. Their handles are kept so
    /// `stopSession` can wait for them and the closed session is complete.
    private var pendingResolves: [Int: Task<Void, Never>] = [:]

    /// Recognition running against the hold currently being spoken, and where to write its result.
    /// Awaited at close alongside the crops: the pipeline starts the moment the session closes, and a
    /// timing file that lands afterwards would be read by nobody.
    private var liveTiming: LiveSpeechTiming?
    private var liveTimingAudioPath: String?
    private var timingWrites: [Task<Void, Never>] = []

    /// The close-out in progress, if any. One task, shared: `stopSession` from the menu, Quit and a second
    /// Ctrl-C all await the same close rather than racing it, which could finalise the session while its
    /// crops are still being written.
    private var stopTask: Task<String?, Never>?

    func start() -> Bool {
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        return hotkey.start()
    }

    /// Stop listening for the keys without ending a session. The pair to `start()`, for a permission
    /// revoked while Deiko runs: the listener is dead either way, and holding a stale one means the
    /// returning grant can never rebuild it.
    func stopListening() {
        hotkey.stop()
    }

    // MARK: - Session lifetime

    /// Reopen a session that has already been closed out, so the next recording becomes another hold of
    /// it rather than a new session ("Forgot something?").
    ///
    /// The pipeline already supports this: `transcribe.mjs` pairs each hold's start and end to find its
    /// audio and shifts each onto the session clock, and the referent stack attributes what was pointed at
    /// to its hold.
    ///
    /// Counters are recovered from `events.jsonl`, not from memory, which is right only for the same
    /// launch with no other session in between; a referent index that restarts would overwrite the first
    /// hold's crops.
    func reopenSession(dir: String) -> Bool {
        guard sessionDir == nil else { return false }
        let events = "\(dir)/events.jsonl"
        guard FileManager.default.fileExists(atPath: events),
              let raw = try? String(contentsOfFile: events, encoding: .utf8)
        else { return false }

        var holds = 0
        var referents = 0
        var marks = 0
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            // A session-level `sessionStart` carries no `hold`; only a hold does.
            if type == "holdStart", obj["hold"] != nil { holds += 1 }
            // `probe`, not `candidate`: one probe is emitted per `resolve`, which is what increments
            // `globalReferentIndex`, and it covers lassos as well as settles.
            if type == "probe" { referents += 1 }
            if type == "probe", obj["mark"] != nil { marks += 1 }
        }
        guard holds > 0 else { return false }

        sessionDir = dir
        sessionId = (dir as NSString).lastPathComponent
        // The original start happened in some earlier close-out; a duration measured from here would
        // understate the session.
        sessionStartedMs = nil
        holdIndex = holds
        globalReferentIndex = referents
        markIndex = marks
        sessionReferentCount = referents
        gatedSettleCount = 0

        // `redirectToFile` seeks to the end, so this appends — the first hold's
        // events are the other half of this session, not something to overwrite.
        Emit.redirectToFile(events)
        Emit.log("↩ reopened \(sessionId ?? dir) — \(holds) hold(s), \(referents) referent(s) so far")
        onStateChange?()
        return true
    }

    /// Reopen a finished session and start recording another hold immediately. The button does the
    /// starting, so the gesture machine has to be told; otherwise the tap that stops reads as the first
    /// half of a double-tap to start, and the microphone stays live.
    func resumeForExtraHold(dir: String) -> Bool {
        guard reopenSession(dir: dir) else { return false }
        hotkey.noteSessionStarted()
        beginRecording()
        return isRecording
    }

    /// Mints `<root>/<stamp>` on the first hold and not before, so a run that records nothing leaves no
    /// folder behind. Returns false when the directory cannot be created (a full or read-only volume): no
    /// session starts, rather than one that silently writes to nowhere.
    private func startSessionIfNeeded() -> Bool {
        guard sessionDir == nil else { return true }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Fixed locale: a plain DateFormatter under a Hindi or Arabic system locale can render non-ASCII
        // digits or a non-Gregorian year, and the folder name has to sort.
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
            // Shown, not just logged: without a session directory `beginRecording` returns quietly, and the
            // user would double-tap Right Option and see nothing happen.
            Emit.problem(
                "could not create session directory \(dir): \(error.localizedDescription)",
                hint: "Deiko could not create its session folder in \(sessionRoot). Check that the disk has room and that Deiko can write there."
            )
            return false
        }

        // Excluded from backup: a session folder holds screen text, window titles and crops (including
        // captures the secret detector flagged and withheld from the agent) until somebody deletes them, and
        // Time Machine must not carry that to an external disk. Best-effort and idempotent, so it runs on
        // every session rather than relying on one-time setup. iCloud is not a concern: the root is in
        // Application Support, which it never syncs (see `Sessions.defaultRoot`).
        var rootURL = URL(fileURLWithPath: sessionRoot)
        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        try? rootURL.setResourceValues(exclusion)

        sessionDir = dir
        sessionId = stamp
        sessionStartedMs = Clock.nowMs()
        PickUp.shared.place(sessionDir: dir)
        holdIndex = 0
        globalReferentIndex = 0
        markIndex = 0
        sessionReferentCount = 0
        gatedSettleCount = 0

        // Events now belong to this session's file rather than the launch log.
        Emit.redirectToFile("\(dir)/events.jsonl")
        Emit.event(SessionEvent.start(id: stamp))
        Emit.log("▶ session \(stamp) → \(dir)")
        return true
    }

    /// Close the session out. Returns its directory so the caller can reveal it. Safe with no session
    /// open (the menu's Quit path does), mid-hold (the hold is ended first so its WAV is finalised and its
    /// `audioT0` recorded), and twice: concurrent callers await the same close.
    func stopSession() async -> String? {
        if let stopTask { return await stopTask.value }
        guard sessionDir != nil else { return nil }

        let task = Task { await self.closeSession() }
        stopTask = task
        let dir = await task.value
        stopTask = nil
        return dir
    }

    /// Set for the duration of one close-out: throw the session away instead of
    /// handing it to the orb.
    private var discardOnClose = false

    /// Stop, and keep nothing. Closes out through the same path as `stopSession` (a hold in flight is
    /// finalised and crops still being written are awaited) and then deletes the folder.
    func discardSession() async {
        guard sessionDir != nil else { return }
        discardOnClose = true
        _ = await stopSession()
        // Cleared whatever happened: `stopSession` returns the in-flight close when one is already running,
        // and that close may have passed the discard check before this flag was set, which would delete
        // the next session at its own close. `closeSession` clears it when it observes it; this clears it
        // when it did not.
        discardOnClose = false
    }

    private func closeSession() async -> String? {
        // A lasso still being drawn is a referent the user meant to capture: commit it before teardown, or
        // it dies on the `isRecording` guard in `commitLasso`.
        if isRecording, lassoPath != nil { commitLasso() }
        if isRecording { endRecording() }
        guard let dir = sessionDir, let id = sessionId else { return nil }

        // Wait for AX + crop + OCR still in flight. Awaiting releases the main actor so their completion
        // hops can run, and no new work can join the list meanwhile: `beginRecording` refuses while
        // `stopTask` is set.
        let outstanding = pendingResolves
        pendingResolves = [:]
        if !outstanding.isEmpty {
            Emit.log("  …finishing \(outstanding.count) crop(s)")
        }
        for task in outstanding.values { await task.value }

        // The last hold's recognition, closed by `endRecording` a moment ago. It resolves quickly and must
        // land before `onSessionClosed` starts the pipeline, or the pipeline would recognise the file again.
        let timings = timingWrites
        timingWrites = []
        for task in timings { await task.value }

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

        // Back to the launch log, so anything emitted between sessions is not appended to a finished session.
        Emit.redirectToFile(Paths.launchLog)

        // Read before the reset below.
        let stats = SessionStats(
            durationMs: sessionStartedMs.map { Clock.nowMs() - $0 },
            referentCount: sessionReferentCount
        )

        sessionDir = nil
        sessionId = nil
        sessionStartedMs = nil
        // Tell the hotkey, whatever route brought us here: a watchdog stop or a Quit never passed through
        // the gesture, and a hotkey that thinks a session is live keeps swallowing Option-drags.
        hotkey.noteSessionEnded()
        onStateChange?()

        // Thrown away only here, at the very end: the hold is finalised, in-flight crops awaited, and the
        // event file redirected and closed. Deleting earlier would race a write in flight. No orb, since
        // there is nothing to hand over.
        if discardOnClose {
            discardOnClose = false
            do {
                try FileManager.default.removeItem(atPath: dir)
                Emit.log("✕ session \(id) discarded")
                PickUp.shared.discarded(sessionDir: dir)
            } catch {
                Emit.log("✕ session \(id) — could not discard: \(error.localizedDescription)")
            }
            return dir
        }

        // Fired here rather than from the menu's stop action: the hotkey tap, the silence watchdog and Quit
        // all arrive through `stopSession`. One notification, every route.
        onSessionClosed?(dir, stats)
        return dir
    }

    /// Stop listening entirely. The hotkey tap is torn down rather than left running and ignored.
    func stop() async {
        _ = await stopSession()
        hotkey.stop()
    }

    // MARK: - Gesture handling

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .recordingStarted:
            // No session open and the orb is showing a finished brief: this gesture adds to that session.
            // The orb claims it via `resumeForExtraHold`, whose own `beginRecording` makes the call below a
            // no-op behind the `isRecording` guard.
            if sessionDir == nil, onStartGestureWhileIdle?() == true { break }
            beginRecording()
        case .recordingStopped:
            Task { _ = await self.stopSession() }
        case .drawKeyDown(let p):
            guard isRecording else { break }
            endHoverStroke()
            hoverPath = [p]
        case .drawKeyUp:
            if hoverPromoted, lassoPath != nil { commitLasso() }
            endHoverStroke()
        case .scrolled:
            // Reported unconditionally by the tap; only meaningful while a session is live.
            if isRecording { lastScrollT = Clock.nowMs() }
        }
    }

    private func endHoverStroke() {
        hoverPath = nil
        hoverStartT = nil
        hoverPromoted = false
    }

    private func beginRecording() {
        guard !isRecording else { return }

        // A start that lands while the previous session is still closing waits for it rather than being
        // dropped: `closeSession` can take a second or two on the crop drain, ignoring the gesture would
        // look like a dead hotkey, and starting on top of it would split its events across two files.
        if let stopTask {
            Task { @MainActor in
                _ = await stopTask.value
                self.beginRecording()
            }
            return
        }

        guard startSessionIfNeeded(), let sessionDir, let sessionId else { return }

        isRecording = true
        recordingStartedAt = Clock.nowMs()
        holdReferentCount = 0
        // Increment, not assign: a fresh session becomes hold 1, and one reopened by "Forgot something?"
        // carries its hold count in.
        holdIndex += 1

        // One WAV for the whole session: a single continuous recording has one audio timeline and one
        // `audioT0`. The wire still says `hold: 1`; downstream pairs holdStart/holdEnd to find the audio.
        var audioPath: String?
        // Hold 1 keeps the name recorded sessions already use; later holds get their own file. Each hold has
        // its own `audioT0`, which `transcribe.mjs` shifts onto the session clock separately, so a shared
        // filename would let the second hold overwrite the first.
        let path = holdIndex == 1
            ? "\(sessionDir)/audio/session.wav"
            : "\(sessionDir)/audio/hold-\(holdIndex).wav"
        // The recogniser is attached before the tap can fire: `onBuffer` is read on the audio thread, so
        // assigning it after `start()` would lose the opening buffers (the first words of the sentence) and
        // race a reader against a half-written closure.
        prepareLiveTiming()
        do {
            try audio.start(path: path)
            audioPath = path
            liveTimingAudioPath = path
        } catch {
            abandonLiveTiming()
            Emit.event(ErrorEvent(
                "audio capture failed: \(error.localizedDescription)",
                hint: "System Settings → Privacy & Security → Microphone, and make sure Deiko is switched on. Capture continues without narration, but the session cannot be aligned."
            ))
        }

        Emit.event(HoldEvent.start(id: sessionId, hold: holdIndex, audioPath: audioPath))
        Emit.log("● recording — point at things and talk. Hold LEFT Option and "
            + "move to circle an area. Tap \(SessionKey.selected.name) to stop.")
        onStateChange?()

        pulses.removeAll()
        recentSpeeds.removeAll()
        approachAtRest = 0
        hasMoved = false
        firedForThisRest = false
        lastPosition = AXProbe.cursorLocation()
        previousSample = nil
        stationarySince = Clock.nowMs()

        // Get Chromium's accessibility tree built before the first referent needs it (~300ms).
        lastFrontPid = AXProbe.prePokeFrontmost()

        // The pill's promise is "click me and this stops": the same close-out as every other route, so a
        // click cannot truncate crops in flight.
        overlay.onStopRequested = { [weak self] in
            Task { @MainActor in _ = await self?.stopSession() }
        }
        overlay.show()
        sampler = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        // Teardown first, unconditionally: the sampler, overlay and microphone must stop whatever state the
        // session is in. A live microphone is the one promise this product cannot break.
        isRecording = false
        recordingStartedAt = nil
        sampler?.invalidate()
        sampler = nil
        overlay.hide()
        lassoPath = nil
        endHoverStroke()
        let audioT0 = audio.stop()
        endLiveTiming()

        guard let sessionId else { return }
        Emit.event(HoldEvent.end(
            id: sessionId, hold: holdIndex,
            referentCount: holdReferentCount, audioT0: audioT0
        ))
        Emit.log("○ stopped — \(holdReferentCount) referent(s)"
            + (audioT0 == nil ? " (no audio)" : ""))
        onStateChange?()
    }

    // MARK: - Live word timings

    // Recognition runs while the words are said, so the answer is an `endAudio()` away when the hotkey is
    // tapped. It is best-effort, shaped like the crops: on any failure no file is written and
    // `BriefPipeline.precomputeTimings` does the work afterwards. Nothing downstream knows which path
    // produced the file.

    private func prepareLiveTiming() {
        // The same locale the file path uses (Settings → offline recogniser): a different one would change
        // the words depending on which path ran.
        guard let live = LiveSpeechTiming(localeIdentifier: SpeechLocale.selected) else { return }
        liveTiming = live
        audio.onBuffer = { [weak live] buffer in live?.append(buffer) }
    }

    /// The microphone never opened, so there is nothing to recognise.
    private func abandonLiveTiming() {
        audio.onBuffer = nil
        liveTiming?.cancel()
        liveTiming = nil
        liveTimingAudioPath = nil
    }

    private func endLiveTiming() {
        audio.onBuffer = nil
        guard let live = liveTiming, let path = liveTimingAudioPath else { return }
        liveTiming = nil
        liveTimingAudioPath = nil

        let out = URL(fileURLWithPath: path + ".timing.json")
        timingWrites.append(Task.detached {
            let result = await live.finish()
            // A result carrying an error is not written: an empty timing file would tell
            // `precomputeTimings` this hold is done and stop the file path from running. Silence here means
            // "fall back".
            guard result.error == nil, !result.words.isEmpty,
                  let data = try? JSONEncoder().encode(result) else { return }
            // Atomic because the reader polls for existence and parses immediately.
            try? data.write(to: out, options: .atomic)
        })
    }

    // MARK: - Sampling

    private func sample() {
        let now = Clock.nowMs()
        let position = AXProbe.cursorLocation()
        Emit.event(CursorEvent(position))

        // App-switch detection rides on the sampler rather than a notification observer: it only needs frame
        // accuracy, and this keeps the session on one clock.
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

        pulses.removeAll { now - $0.t > 450 }

        // A mouse button down means the gesture belongs to the app, not Deiko: Option + press-and-drag must
        // reach the app as it always did (select text, duplicate a file), and drawing over it would do both
        // at once. The stroke is dropped, not committed, and stays dropped until Option is pressed again.
        // Polled here because the tap deliberately sees no mouse events (see `Hotkey.swift`).
        if hoverPath != nil, NSEvent.pressedMouseButtons & 1 != 0 {
            if hoverPromoted { lassoPath = nil; lassoStartT = nil }
            endHoverStroke()
        }

        // The button-less stroke, fed from these samples rather than the event tap (see `Hotkey.swift`).
        // Stationary frames are skipped so a long-held Option cannot grow the path.
        if hoverPath != nil, step > 0 {
            if hoverPromoted {
                lassoPath?.append(position)
            } else {
                // Displacement from the key-down point, not path length: a resting hand jitters, and summed
                // jitter reaches any threshold if Option is held long enough (Option+Backspace over a few
                // words). The clock starts at the first movement, not the key press, since the span binds
                // narration to the stroke.
                if hoverStartT == nil { hoverStartT = now }
                hoverPath?.append(position)
                let origin = hoverPath?.first ?? position
                if hypot(position.x - origin.x, position.y - origin.y) >= minHoverStrokePt {
                    lassoPath = hoverPath
                    lassoStartT = hoverStartT
                    hoverPromoted = true
                }
            }
        }

        if lassoPath == nil {
            detectSettle(position: position, moved: moved, now: now)
        }

        // Silence watchdog. `msSinceVoice` is nil until the first buffer lands (and forever if the mic never
        // opened), so fall back to the time since recording began.
        let runningFor = recordingStartedAt.map { now - $0 } ?? 0
        let quietFor = msSinceVoice ?? runningFor
        if quietFor > autoStopSilenceMs {
            Emit.log("■ stopping — \(Int(autoStopSilenceMs / 60000)) minutes with no narration")
            Task { _ = await self.stopSession() }
        } else if runningFor > maximumSessionMs {
            Emit.log("■ stopping — \(Int(maximumSessionMs / 60000))-minute session limit")
            Task { _ = await self.stopSession() }
        }

        // The pill warns only if no voiced buffer has ever arrived, not when the user merely goes quiet: a
        // six-second pause while reading code is not a broken microphone. Once one buffer has arrived the
        // microphone has demonstrably worked, and later silence says nothing about the hardware.
        // `detectSettle` reads the same nil and does the opposite: it keeps capturing, because a silent gate
        // would turn a microphone problem into a session that records nothing and explains nothing.
        overlay.update(
            cursor: position, lasso: lassoPath,
            pulses: pulses,
            hearingVoice: msSinceVoice != nil || runningFor <= silenceGateMs
        )
    }

    private func detectSettle(position: Point, moved: Double, now: Double) {
        if moved > settleRadius {
            lastPosition = position
            stationarySince = now
            // Refreshed on every moving frame, so when the cursor stops this holds the speed it was
            // travelling at just beforehand.
            approachAtRest = recentSpeeds.map(\.speed).max() ?? 0
            hasMoved = true
            firedForThisRest = false
            return
        }

        guard hasMoved, !firedForThisRest, now - stationarySince >= dwellMs else { return }
        firedForThisRest = true

        // The capture gate. A settle with no narration anywhere near it is transit, reading, scrolling or a
        // hand at rest, not a pointing act; with the session always on, recent speech is what says "I am
        // describing something now". The window is wide on purpose: the aligner allows a referent up to 2s
        // after the word that named it and 1.5s before, so anything tighter would drop referents it could
        // still bind, and an extra crop costs a few milliseconds and some disk. With no audio at all (mic
        // denied, or the first buffer not yet in) everything is captured, so one permission problem does
        // not become a session that records nothing.
        if let quietFor = msSinceVoice, quietFor > silenceGateMs {
            gatedSettleCount += 1
            return
        }

        commitPoint(at: position, dwell: now - stationarySince, now: now)
    }

    // MARK: - Committing referents

    private func commitPoint(at position: Point, dwell: Double, now: Double) {
        let features = CandidateFeatures(
            dwellMs: dwell,
            // Taken from the moment the cursor stopped, not recomputed now (see `approachAtRest`): the window
            // is full of stationary samples by the end of the dwell.
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

        // The stroke itself is the meaning. Classification picks the verb and the dressing; every kind
        // captures the same way: stroke bounds plus what sits at the anchors, with the ink drawn on.
        let kind = StrokeClassifier.classify(path.map { StrokePoint(x: $0.x, y: $0.y) })
        markIndex += 1
        let mark = MarkInfo(kind: kind.rawValue, number: markIndex)

        // Geometry container on the wire: a tap stays a point, everything with
        // extent is a region. `mark.kind` carries the finer reading.
        let shape = kind == .point
            ? Shape.point(Shape.region(path: path).origin)
            : Shape.region(path: path)

        let now = Clock.nowMs()
        pulses.append(
            Pulse(position: shape.origin, t: now, isRegion: shape.kind == .region)
        )
        overlay.flourish(path: path, kind: kind)
        holdReferentCount += 1
        sessionReferentCount += 1
        // The narration for a stroke happens while drawing it, so every mark kind gets the measured span.
        let span = startT.map { TimeSpan(start: $0, end: now) }
        resolve(shape: shape, span: span, mark: mark, strokePath: path)
    }

    /// AX + crop, off the sampling path: resolution can take a few hundred milliseconds, and blocking
    /// would freeze the overlay and drop cursor samples mid-gesture. The task handle is retained so
    /// `stopSession` can wait on it. The session directory is read here and captured by value, since a
    /// slow OCR may finish after `sessionDir` is nil.
    private func resolve(
        shape: Shape, span: TimeSpan?,
        mark: MarkInfo? = nil, strokePath: [Point]? = nil
    ) {
        globalReferentIndex += 1
        let hold = holdIndex
        let index = globalReferentIndex
        let dir = sessionDir

        let task = Task.detached { [captureCrops] in
            let kind = mark.flatMap { StrokeKind(rawValue: $0.kind) }

            var event: ProbeEvent
            var loci: [(point: Point, snapshot: AXSnapshot)] = []

            switch kind {
            case .connector, .trace:
                // The endpoints are the content; the line between them is
                // mostly whitespace. Probe both — release end is primary.
                let start = strokePath?.first ?? shape.origin
                let end = strokePath?.last ?? shape.origin
                let startProbe = AXProbe.probePoint(start)
                let endProbe = AXProbe.probePoint(end)
                event = ProbeEvent(
                    shape: shape,
                    app: endProbe.app ?? startProbe.app,
                    windowTitle: endProbe.windowTitle ?? startProbe.windowTitle,
                    snapshot: endProbe.snapshot,
                    mark: mark,
                    startSnapshot: startProbe.snapshot,
                    pageURL: endProbe.pageURL ?? startProbe.pageURL,
                    document: endProbe.document ?? startProbe.document
                )
                loci = [(start, startProbe.snapshot), (end, endProbe.snapshot)]
            case .point:
                let probe = AXProbe.probePoint(shape.origin)
                event = ProbeEvent(
                    shape: shape, app: probe.app, windowTitle: probe.windowTitle,
                    snapshot: probe.snapshot, mark: mark,
                    pageURL: probe.pageURL, document: probe.document
                )
                loci = [(shape.origin, probe.snapshot)]
            case .lasso, .emphasis:
                let probe = AXProbe.probeRegion(shape)
                event = ProbeEvent(
                    shape: shape, app: probe.app, windowTitle: probe.windowTitle,
                    snapshot: probe.snapshot, mark: mark,
                    pageURL: probe.pageURL, document: probe.document
                )
                // Emphasis breathes around what was scribbled over; a lasso's
                // own loop already declares its extent.
                if kind == .emphasis { loci = [(shape.origin, probe.snapshot)] }
            case nil:
                // A plain settle.
                event = shape.kind == .region
                    ? AXProbe.probeRegion(shape)
                    : AXProbe.probePoint(shape.origin)
            }
            if let span { event = event.with(span: span) }

            if captureCrops {
                let screenArea = AXProbe.screenArea()
                let rect: Frame
                let fromAX: Bool
                if mark != nil, !loci.isEmpty {
                    rect = Capture.markRect(
                        strokeBounds: shape.bounds, loci: loci, screenArea: screenArea
                    )
                    fromAX = loci.contains { locus in
                        Capture.rect(for: Shape.point(locus.point),
                                     snapshot: locus.snapshot,
                                     screenArea: screenArea).fromAX
                    }
                } else {
                    (rect, fromAX) = Capture.rect(
                        for: shape, snapshot: event.snapshot, screenArea: screenArea
                    )
                }

                // A file for every mark: everything under the modifier is deliberate. A settle captures in
                // memory only.
                let path = mark != nil || shape.kind == .region
                    ? dir.map {
                        "\($0)/crops/h\(String(format: "%02d", hold))-r\(String(format: "%03d", index)).png"
                    }
                    : nil

                let crop = await Capture.crop(
                    snapshot: event.snapshot,
                    outputPath: path,
                    runOCR: true,
                    rectFromAX: fromAX,
                    rect: rect
                )
                event = event.with(crop: crop)

                // Ink after capture and OCR: recognition reads clean pixels, the file the agent sees carries
                // the stroke and its number.
                if let mark, let kind, let written = crop.path {
                    InkRenderer.ink(
                        file: written,
                        strokePath: strokePath ?? [shape.origin],
                        cropRect: crop.rect,
                        kind: kind,
                        number: mark.number
                    )
                }
            }

            Emit.event(event)

            // Retire the handle: `Task` exposes no "did it finish" flag, so each task removes itself to keep
            // the set to what is in flight.
            await MainActor.run { [weak self] in self?.pendingResolves[index] = nil }
        }

        pendingResolves[index] = task
    }
}

/// Fixed locations the app writes to outside a session.
enum Paths {
    /// Where events go when no session is open. An app launched from Finder has no stdout, so a
    /// permission failure at startup would otherwise vanish.
    static let launchLog =
        "\(NSHomeDirectory())/Library/Logs/Deiko/launch.jsonl"
}
