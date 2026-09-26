import AppKit
import Foundation
import DeikoGesture

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
//   hold Left Option + move → a stroke: lasso, arrow, scribble
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

/// What a closed session captured, as the recorder knew it at the moment of
/// close. The orb's working readout shows this while the pipeline is still
/// transcribing — "0:43 captured · 6 things pointed at" is answerable
/// immediately; everything else has to wait.
struct SessionStats {
    /// Wall time from session start to close. Nil for a reopened session,
    /// whose original start this launch may never have seen.
    let durationMs: Double?
    let referentCount: Int
}

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
    private var pulses: [Pulse] = []

    private var lassoPath: [Point]?
    /// When the current stroke began — the recorder sees `drawKeyDown`
    /// directly, so the span it emits is measured, not reconstructed.
    private var lassoStartT: Double?

    /// A stroke: Left Option held, cursor moving. It is only a CANDIDATE until
    /// the cursor is `minHoverStrokePt` away from where the key went down — Option is
    /// also Option+Backspace, Option+arrow, and `@ [ ] { }` on most non-US
    /// layouts, and none of those may flash ink or leave a mark. Once promoted
    /// it is handed to `lassoPath` and is an ordinary stroke from there on.
    private var hoverPath: [Point]?
    private var hoverStartT: Double?
    private var hoverPromoted = false
    /// Tunable on purpose, like `settleRadius`: hands and trackpads differ.
    var minHoverStrokePt: Double = 24

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

    /// Marks numbered in capture order across the session — the badge number.
    /// Separate from `globalReferentIndex`, which also counts plain settles.
    private var markIndex = 0

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

    /// When the OPEN session was minted, for the stats handed to the orb at
    /// close. Nil for reopened sessions — see `reopenSession`.
    private var sessionStartedMs: Double?

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

    /// How long the open session has been running, for the menu's live clock.
    /// Nil with no session, and for reopened ones (original start unknown).
    var sessionElapsedMs: Double? {
        sessionStartedMs.map { Clock.nowMs() - $0 }
    }

    /// Fired whenever any of the above changes, so the menu-bar icon and items
    /// reflect what is genuinely happening rather than what was last clicked.
    var onStateChange: (() -> Void)?

    /// Fired once with the session directory when a session has fully closed —
    /// crops written, WAV finalised, `sessionEnd` emitted. The review window
    /// hangs off this: everything it reads has to exist before it opens.
    ///
    /// The stats ride along because the orb's working readout wants them the
    /// moment it appears — long before the pipeline has produced a digest —
    /// and by then this class has already reset its counters for the next
    /// session.
    var onSessionClosed: ((String, SessionStats) -> Void)?

    /// Consulted when the start gesture arrives with no session open. Return
    /// true to claim the gesture — the orb does, while it is showing a
    /// finished brief, routing the recording into THAT session as another
    /// hold (the redesign cut the orb's "Add more" button; the start gesture
    /// is its replacement). Returning false starts a fresh session as always.
    var onStartGestureWhileIdle: (() -> Bool)?

    /// Crop + AX resolution runs off the sampling path in detached tasks. Their
    /// handles are kept so `stopSession` can wait for them: the stop button
    /// reveals the folder in Finder, and a folder revealed while three crops are
    /// still being written is a folder the user sees as incomplete.
    private var pendingResolves: [Int: Task<Void, Never>] = [:]

    /// Recognition running against the hold currently being spoken, and where to
    /// write its result. Awaited at close alongside the crops, for the same
    /// reason: the pipeline starts the moment the session closes, and a timing
    /// file that lands afterwards would be read by nobody.
    private var liveTiming: LiveSpeechTiming?
    private var liveTimingAudioPath: String?
    private var timingWrites: [Task<Void, Never>] = []

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

    /// Stop listening for the keys without ending a session.
    ///
    /// The pair to `start()`, for when a permission is revoked while Deiko is
    /// running: the listener is dead either way, and holding a stale one means the
    /// grant coming back can never rebuild it.
    func stopListening() {
        hotkey.stop()
    }

    // ── Session lifetime ────────────────────────────────────────────────────

    /// Mints `<root>/<stamp>` on the FIRST hold and not before.
    ///
    /// Creating it at launch instead meant every run of the app left a folder
    /// behind with a 0-byte `events.jsonl`, whether or not anything was ever
    /// recorded — three of them accumulated in a single evening.
    ///
    /// Returns false when the directory cannot be created (a full or
    /// read-only volume) — in which case NO session starts, rather than
    /// a session that silently writes to nowhere.
    /// Reopen a session that has already been closed out, so the next recording
    /// becomes another HOLD of it rather than a new session.
    ///
    /// This is "Forgot something?" — you stop, read the brief, realise you never
    /// showed the one file that explains the whole task, and add it to the same
    /// account rather than starting a second one the agent would have to
    /// reconcile.
    ///
    /// The pipeline never stopped supporting this. `transcribe.mjs` pairs each
    /// hold's start and end to find its audio and shifts each onto the session
    /// clock; the referent stack attributes what you pointed at to the hold it
    /// happened in. Only the recorder had been simplified to always write hold 1.
    ///
    /// Counters are recovered from `events.jsonl`, not from whatever is still in
    /// memory. In-memory state is right only if this is the same launch and no
    /// other session happened in between — and a referent index that restarts
    /// silently overwrites the first hold's crops.
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
            // `probe`, not `candidate`. One probe is emitted per `resolve` —
            // which is exactly what increments `globalReferentIndex` — and it
            // covers lassos as well as settles. Verified against two recorded
            // sessions: 16 probes / 16 referents, 35 / 35, where the candidate
            // counts were 10 and 25.
            if type == "probe" { referents += 1 }
            if type == "probe", obj["mark"] != nil { marks += 1 }
        }
        guard holds > 0 else { return false }

        sessionDir = dir
        sessionId = (dir as NSString).lastPathComponent
        // The original start happened in some earlier close-out, possibly an
        // earlier launch. A duration measured from HERE would claim the
        // session is seconds old when its first hold is minutes of material.
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

    /// Reopen a finished session and start recording another hold immediately.
    ///
    /// The button does the starting, so the gesture machine has to be told —
    /// otherwise the tap the user makes to stop reads as the first half of a
    /// double-tap to start, and the microphone stays live on a session they
    /// believe they just closed.
    func resumeForExtraHold(dir: String) -> Bool {
        guard reopenSession(dir: dir) else { return false }
        hotkey.noteSessionStarted()
        beginRecording()
        return isRecording
    }

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
            // SHOWN, not just filed. Without a session directory `beginRecording`
            // guards out and returns, so the user double-taps Right Option and
            // nothing happens — again, and again, with a perfectly good
            // explanation sitting in a log file they will never open.
            Emit.problem(
                "could not create session directory \(dir): \(error.localizedDescription)",
                hint: "Deiko could not create its session folder in \(sessionRoot). Check that the disk has room and that Deiko can write there."
            )
            return false
        }

        // NOT FOR BACKUP. A session folder holds screen text, window titles and
        // crops read off whatever the user pointed at — including, by design,
        // captures the secret detector flagged and withheld from the agent —
        // until somebody deletes them. Marking the root excluded keeps Time
        // Machine from carrying that to an external disk. Best-effort and
        // idempotent, so it runs on every session rather than trusting a
        // one-time setup that a fresh install would never see. iCloud is not
        // a question: the root is in Application Support, which it never
        // syncs (see `Sessions.defaultRoot`).
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

    /// Set for the duration of one close-out: throw the session away instead of
    /// handing it to the orb.
    private var discardOnClose = false

    /// Stop, and keep nothing.
    ///
    /// The only way out of a session used to be one that produced a brief —
    /// so a session started by accident, or one where the wrong thing was said,
    /// had to be carried all the way to an orb and then dismissed, leaving the
    /// recording and its screenshots on disk anyway. This closes out through
    /// exactly the same path (so a hold in flight is finalised and crops still
    /// being written are awaited) and then deletes the folder.
    func discardSession() async {
        guard sessionDir != nil else { return }
        discardOnClose = true
        _ = await stopSession()
        // CLEARED WHATEVER HAPPENED. `stopSession` returns the in-flight close
        // when one is already running, and that close may have passed the
        // discard check before this flag was set — leaving it true, and the
        // NEXT session silently deleted at its own close. `closeSession` clears
        // it when it observes it; this clears it when it did not.
        discardOnClose = false
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

        // The last hold's recognition, which `endRecording` closed a moment ago.
        // It resolves in well under a second — the audio is already in the
        // recogniser — and it must land before `onSessionClosed` starts the
        // pipeline, or the pipeline would recognise the file all over again.
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

        // Back to the launch log, so anything emitted between sessions is not
        // silently appended to a session the user considers finished.
        Emit.redirectToFile(Paths.launchLog)

        // Read out BEFORE the reset below — after it, this session's numbers
        // are gone.
        let stats = SessionStats(
            durationMs: sessionStartedMs.map { Clock.nowMs() - $0 },
            referentCount: sessionReferentCount
        )

        sessionDir = nil
        sessionId = nil
        sessionStartedMs = nil
        // Tell the hotkey, whatever route brought us here. A watchdog stop or
        // a Quit never passed through the gesture, and leaving it believing a
        // session is live means Option-drags stay swallowed afterwards.
        hotkey.noteSessionEnded()
        onStateChange?()

        // THROWN AWAY, and only here at the very end.
        //
        // Everything above has already run: the hold is finalised, crops still
        // being written were awaited, the event file was redirected back to the
        // launch log and its handle closed. Deleting earlier would race a write
        // still in flight; deleting here removes a directory nothing is holding
        // open. No orb, because there is nothing to hand over.
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

        // Fired HERE rather than from the menu's stop action, because that is
        // only one of four ways a session ends — the hotkey tap, the silence
        // watchdog and Quit all arrive through `stopSession` and would each have
        // needed their own call. One notification, every route.
        onSessionClosed?(dir, stats)
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
            // No session open and the orb is showing a finished brief? Then
            // this gesture ADDS to that session — the orb claims it via
            // `resumeForExtraHold`, whose own `beginRecording` makes the one
            // below a no-op behind the `isRecording` guard.
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
            // Reported unconditionally by the tap now; only meaningful while
            // a session is live.
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
        // Increment, not assign. A fresh session sets this to 0 and this makes
        // it hold 1; a session reopened by "Forgot something?" carries its hold
        // count in and this makes the next one hold 2.
        holdIndex += 1

        // ONE WAV for the whole session. It used to be one per hold, because a
        // hold was an utterance; a session is now a single continuous recording,
        // so there is one audio timeline and one `audioT0`. The wire still says
        // `hold: 1` — downstream pairs holdStart/holdEnd to find the audio, and
        // that pairing is worth keeping stable.
        var audioPath: String?
        // Hold 1 keeps the name every recorded session already uses; later holds
        // get their own file. Both must exist independently — each hold has its
        // own `audioT0`, and `transcribe.mjs` shifts each onto the session clock
        // separately. One shared filename would have the second hold silently
        // overwrite the first, losing the original narration entirely.
        let path = holdIndex == 1
            ? "\(sessionDir)/audio/session.wav"
            : "\(sessionDir)/audio/hold-\(holdIndex).wav"
        // The recogniser is attached BEFORE the tap can fire. `onBuffer` is read
        // on the audio thread, so assigning it after `start()` would both lose
        // the opening buffers and race a reader against a half-written closure —
        // and the opening buffers are the first words of the sentence.
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

        // Get Chromium's tree built before the first referent needs it, rather
        // than making that referent wait ~300ms for it.
        lastFrontPid = AXProbe.prePokeFrontmost()

        // The pill's promise is "click me and this stops" — same close-out as
        // every other route, so a click can never truncate crops in flight.
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

    // ── Live word timings ───────────────────────────────────────────────────
    //
    // Recognition used to start when the session ended, which put the whole of
    // it — including the several seconds a file-based recogniser spends working
    // out that it has reached the end — between letting go and reading a brief.
    // Here it runs while the words are being said, so by the time the hotkey is
    // tapped the answer is a `endAudio()` away.
    //
    // BEST-EFFORT, deliberately, and shaped exactly like the crops: on any
    // failure no file is written, and `BriefPipeline.precomputeTimings` does the
    // work afterwards precisely as it does today. Nothing downstream knows or
    // cares which path produced the file.

    private func prepareLiveTiming() {
        // The same locale the file path uses (Settings → offline recogniser).
        // Recognising live under a different one would change the words
        // depending on which path happened to run — the worst kind of
        // difference to debug.
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
            // A result carrying an error is not written: an empty timing file
            // would tell `precomputeTimings` this hold is done and stop the file
            // path from ever running, turning a recoverable miss into a hold
            // with no timings at all. Silence here means "fall back", which is
            // the whole contract of this shortcut.
            guard result.error == nil, !result.words.isEmpty,
                  let data = try? JSONEncoder().encode(result) else { return }
            // Atomic because the reader polls for existence and parses
            // immediately — a half-written file is a discarded hold.
            try? data.write(to: out, options: .atomic)
        })
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

        pulses.removeAll { now - $0.t > 450 }

        // A BUTTON DOWN MEANS THE GESTURE IS THE APP'S, NOT OURS. Nothing is
        // swallowed any more, so Option + press-and-drag reaches the app as
        // what it has always been there — select text, duplicate a file — and
        // drawing over it as well gave the user both at once. The stroke is
        // dropped, not committed, and stays dropped until Option is pressed
        // again. Polled here rather than tapped: the tap sees no mouse events,
        // on purpose (see `Hotkey.swift`).
        if hoverPath != nil, NSEvent.pressedMouseButtons & 1 != 0 {
            if hoverPromoted { lassoPath = nil; lassoStartT = nil }
            endHoverStroke()
        }

        // The button-less stroke, fed from these samples rather than from the
        // event tap — see `Hotkey.swift`. Stationary frames are skipped so a
        // long-held Option cannot grow the path.
        if hoverPath != nil, step > 0 {
            if hoverPromoted {
                lassoPath?.append(position)
            } else {
                // DISPLACEMENT from the key-down point, not path length: a
                // resting hand jitters, and summed jitter reaches any
                // threshold if Option is held long enough (deleting a few
                // words with Option+Backspace is exactly that).
                //
                // The clock starts at the first movement, not the key press:
                // the span binds narration to the stroke, and a key held for
                // ten seconds before drawing would claim all ten.
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

        // NEVER HEARD ANYTHING, EVER — not "has gone quiet".
        //
        // The first version read `quietFor <= silenceGateMs`, which fires on
        // any six-second pause: lasso a function, read it silently while you
        // think, and the pill asserts a hardware fault and hides the stop hint.
        // Six seconds of silence while reading code is not a broken microphone,
        // it is reading code.
        //
        // `msSinceVoice == nil` is the honest signal, because it means no
        // voiced buffer has arrived in the whole session. Once one has, the
        // microphone has demonstrably worked and a later silence says nothing
        // about the hardware. That is also exactly the 44-second session this
        // was built for: a Bluetooth earbud at 27% input volume never delivered
        // one, so the value stayed nil throughout.
        //
        // `detectSettle` reads the same nil and does the opposite — it keeps
        // capturing, because a silent gate would turn a microphone problem into
        // a session that records nothing and explains nothing. Capture stays
        // permissive; the pill speaks up. Both are right about the same fact.
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

        // The stroke itself is the meaning. Classification picks the verb and
        // the dressing; every kind captures the same way — stroke bounds plus
        // what sits at the anchors, with the ink drawn on.
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
        // The narration for a stroke happens while DRAWING it — every mark
        // kind gets the measured span, not only lassos.
        let span = startT.map { TimeSpan(start: $0, end: now) }
        resolve(shape: shape, span: span, mark: mark, strokePath: path)
    }

    /// AX + crop, off the sampling path. Resolution can take a few hundred
    /// milliseconds; blocking here would freeze the overlay and drop cursor
    /// samples mid-gesture — the two things the user can actually see.
    ///
    /// The task handle is retained so `stopSession` can wait on it. The session
    /// directory is read HERE and captured by value, not read inside the task —
    /// by the time a slow OCR finishes, `sessionDir` may already be nil.
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
                // A plain settle — exactly the old path.
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

                // A file for every MARK — everything under the modifier is
                // deliberate. A settle still captures in memory only.
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

                // Ink AFTER capture and OCR: recognition reads clean pixels,
                // the file the agent sees carries the stroke and its number.
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
    /// the behaviour that littered `~/Documents/Deiko` with empty folders.
    static let launchLog =
        "\(NSHomeDirectory())/Library/Logs/Deiko/launch.jsonl"
}
