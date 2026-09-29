import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// FROM A CLOSED SESSION TO A BRIEF YOU CAN READ
//
// The transcribe-and-render work lives in Node, and this runs it. That is a
// smaller decision than it looks, because the alternative — porting the renderer
// into Swift — would put two implementations of "what does a brief say" in the
// project, and they would disagree the first time one was changed.
//
// Run through a LOGIN SHELL, not by exec'ing node directly. An app launched from
// Finder inherits none of a terminal's environment: `node` on this machine lives
// under nvm at a version-specific path, and SARVAM_API_KEY lives in the repo's
// `.env`. `zsh -lc` loads the same profile Terminal does, so the command
// resolves exactly the way it does when you type `make brief` by hand — and when
// nvm updates, nothing here needs to know.
// ─────────────────────────────────────────────────────────────────────────────

/// The brief in short — decoded from `brief.json`'s `summary`, which the
/// renderer computes. Deliberately not parsed out of the markdown: a reader that
/// scrapes prose starts lying the first time the prose is reworded.
struct BriefSummary: Codable {
    var narration: String
    var narrationEdited: Bool
    var apps: [String]
    var repoHints: [String]
    var referentCount: Int
    var wordCount: Int
    var boundCount: Int
    var unboundCount: Int
    var deicticCount: Int
    var overlapCount: Int
    var needsReviewCount: Int
    var durationMs: Double
    /// Some or all of the words came from the on-device recogniser rather than
    /// the cloud — a spent trial, an unreachable relay, a chunk that failed.
    ///
    /// OPTIONAL because sessions rendered before this existed have no such key,
    /// and a brief on disk from last week must still open. Absent reads as
    /// false, which is the honest default: it means "nothing told us it was
    /// degraded", not "we checked and it was fine".
    var degraded: Bool?
    /// WHICH degradation: "trial", "monthly", "ceiling", "unavailable" or
    /// "timing". `degraded` on its own could only ever produce a hedge — the
    /// five have five different answers and only two are about the user's plan
    /// at all. Written by `packages/core/src/lib/cloud.mjs`, rendered by
    /// `ReviewView.degradedSentence`.
    var degradedReason: String?
    /// Who produced the words — "sarvam", "deiko", or "on-device". Feeds the
    /// one line that says what left this Mac.
    var transcriber: String?
    /// How many requests actually reached the network. Zero with a `deiko`
    /// transcriber means the relay was never reached (or every hold came from
    /// the cache, as it does when an old session is reopened) — so no audio
    /// left, whatever the configuration says.
    var uploadedChunks: Int?
    /// Screenshot labels dropped because the sentence they quoted is no longer
    /// in the corrected narration. Surfaced because the alternative is a brief
    /// that quietly means less than the developer thinks it does.
    var labelsDropped: Int?
    /// Screenshots the developer took out by hand in the review window.
    var cropsRemoved: Int?
    /// What the brief is about, by name — the board names work after the
    /// page or file. Optional: older briefs have no keys.
    var keys: Keys?
    /// The windows the brief was recorded over, titles redacted — the brief
    /// view's "Details". Optional: older briefs have none.
    var windows: [String]?

    struct Keys: Codable {
        var pages: [String]?
        var files: [String]?
        var tickets: [String]?
    }
}

private struct BriefManifest: Codable {
    struct Referent: Codable {
        let cropPath: String?
        let cropWithheld: String?
        /// What was said while this screenshot was drawn. Absent on briefs
        /// rendered before it was kept.
        let said: String?
    }
    let summary: BriefSummary
    let referents: [Referent]
}

/// Everything the review window shows.
struct BriefDigest {
    let sessionDir: String
    let summary: BriefSummary
    let cropsReleased: Int
    let cropsWithheld: Int
    /// WHY they were withheld, distinct and in the order the renderer gave
    /// them. `render-brief.mjs` has two reasons and only one of them is about
    /// a credential; the other is "Deiko could not read this to check", which
    /// is what fires when Screen Recording has been granted but the app has
    /// not been relaunched yet — i.e. on a first run. Carrying only the count
    /// meant the window picked the alarming sentence for both, and told a
    /// brand-new user that a credential had been visible on their screen when
    /// nothing of the sort had happened.
    let withheldReasons: [String]
    /// The images themselves, so the window can show what is about to go
    /// rather than a count of it. A count cannot be wrong in a way anybody
    /// notices; a thumbnail can.
    let cropPaths: [String]
    /// Each screenshot's caption, by path — what was said while it was drawn.
    var captions: [String: String] = [:]
}

enum BriefPipelineError: LocalizedError {
    case pipelineNotFound(String)
    case nodeNotFound
    case commandFailed(stage: String, output: String)
    case noManifest(String)
    case noPrompt(String)

    var errorDescription: String? {
        switch self {
        case .pipelineNotFound(let path):
            return "Could not find Deiko's pipeline, in the app bundle or beside it (looked at \(path))."
        case .nodeNotFound:
            return "Could not find Node on this Mac. Deiko needs it to transcribe and render a brief."
        case .commandFailed(let stage, let output):
            return "\(stage) failed.\n\n\(output)"
        case .noManifest(let path):
            return "The brief rendered but \(path) is missing."
        case .noPrompt(let path):
            // Distinct from `.noManifest` on purpose: by the time this throws,
            // `brief.json` already loaded fine, so this is not "nothing
            // rendered" — it is "rendering didn't finish". And unlike a
            // `Handoff.deliver` failure, the file this names does NOT exist,
            // so telling the user to go paste it themselves would send them
            // looking for something that isn't there. "Point at more" re-runs
            // the render and is the recourse that actually exists here.
            return "The brief didn't finish rendering — \(path) is missing. "
                + "Use \"Point at more\" to re-run it before sending again."
        }
    }
}

enum BriefPipeline {

    /// One stage of the pipeline: a Node script, and the `make` target that
    /// wraps it in a checkout.
    ///
    /// The two spellings exist because the development path must keep going
    /// through `make`: those targets build the TypeScript packages first
    /// (`npm run build -w @deiko/alignment`), and a script run directly against
    /// a stale or absent `dist/` fails in a way that looks like a bug in the
    /// script. A bundle ships `dist/` already built, so there is nothing to
    /// build and nothing to wrap.
    private enum Stage {
        case transcribe, brief, summarize, classify, notes

        var script: String {
            switch self {
            case .transcribe: return "transcribe.mjs"
            case .brief: return "render-brief.mjs"
            case .summarize: return "summarize.mjs"
            case .classify: return "classify.mjs"
            case .notes: return "task-notes.mjs"
            }
        }

        var makeTarget: String {
            switch self {
            case .transcribe: return "transcribe"
            case .brief: return "brief"
            case .summarize: return "summarize"
            case .classify: return "classify"
            case .notes: return "task-notes"
            }
        }

        /// What the orb says while this is running.
        var label: String {
            switch self {
            case .transcribe: return "Transcribing"
            case .brief: return "Rendering the brief"
            case .summarize: return "Summarising"
            case .classify: return "Placing it"
            case .notes: return "Updating task notes"
            }
        }
    }

    /// The one setting the renderer reads from the app: whether a brief the
    /// classifier called quick may carry the "a fast model is probably
    /// enough" line. A defaults key, so the Settings toggle and this cannot
    /// drift.
    static let optimizeCostsKey = "DEIKO_OPTIMIZE_COSTS"

    private static func briefEnvironment() -> [String: String] {
        UserDefaults.standard.bool(forKey: optimizeCostsKey) ? [optimizeCostsKey: "1"] : [:]
    }

    /// Run one stage, whichever layout this app is running in.
    @discardableResult
    private static func run(
        _ stage: Stage, sessionDir: String, extraEnvironment: [String: String] = [:]
    ) async throws -> String {
        guard let layout = Layout.resolve() else {
            throw BriefPipelineError.pipelineNotFound(Bundle.main.bundleURL.path)
        }
        switch layout {
        case .development(let repo):
            return try await shell(
                "make \(stage.makeTarget) SESSION=\(quoted(sessionDir))",
                in: repo,
                stage: stage.label,
                extraEnvironment: extraEnvironment
            )
        case .bundled(let resources):
            guard let node = NodeRuntime.resolve() else { throw BriefPipelineError.nodeNotFound }
            // No shell at all here: the executable and its one argument are
            // passed directly, so nothing has to be quoted and a session path
            // with a space or a quote in it cannot be misread.
            return try await exec(
                node,
                arguments: [
                    resources.appendingPathComponent("scripts/\(stage.script)").path,
                    sessionDir,
                ],
                stage: stage.label,
                extraEnvironment: extraEnvironment
            )
        }
    }

    /// Transcribe, then render. Returns the brief in short.
    ///
    /// TIMED, and the timing is logged. `transcribe.mjs` has printed its own
    /// stage breakdown to stderr since the last latency pass — and this app
    /// captured that output and threw it away, so the only number anybody could
    /// see from a real session was the total. Both halves are now in
    /// `launch.jsonl`: the app's stages, and the script's own line. Any change
    /// claiming to make this faster has to move these.
    static func run(sessionDir: String) async throws -> BriefDigest {
        let clock = ContinuousClock()
        let started = clock.now
        var marks: [String] = []
        var last = started
        func mark(_ name: String) {
            let now = clock.now
            marks.append("\(name) \(seconds(last.duration(to: now)))")
            last = now
        }
        // Emitted on the failure path too, via defer: a run that died after
        // eleven seconds of recognition is exactly the one whose timing matters,
        // and it is the one that would never have reached a trailing log call.
        defer {
            Emit.log("pipeline: " + marks.joined(separator: " · ")
                + " · total \(seconds(started.duration(to: clock.now)))")
        }

        // ON-DEVICE RECOGNITION AND THE UPLOAD, TOGETHER. The script waits
        // for each hold's timing file beside its upload (`DEIKO_TIMINGS_PENDING`)
        // instead of the upload waiting for all of them first.
        let recordings = hasRecordings(sessionDir: sessionDir)
        // A marker left by a run that died would tell the script "finished"
        // before this run has started.
        try? FileManager.default.removeItem(atPath: "\(sessionDir)/audio/\(doneMarker)")
        async let precomputed: Void = precomputeTimings(sessionDir: sessionDir)
        // EVERY timing file is transient, and one that outlives the run is a
        // verbatim transcript of the developer's narration sitting in a
        // directory they may hand to somebody. `transcribe.mjs` deletes each
        // one as it consumes it — but it only consumes holds it actually
        // transcribes, and a hold served from the transcript cache is never
        // read at all. So sweep unconditionally, including on the failure path.
        defer { removeTimingSidecars(sessionDir: sessionDir) }
        let transcribeOutput = try await run(
            .transcribe,
            sessionDir: sessionDir,
            // Only when there is audio to recognise: with none, nothing would
            // ever be written, and the script would wait for it.
            extraEnvironment: recordings ? ["DEIKO_TIMINGS_PENDING": "1"] : [:]
        )
        await precomputed
        mark("transcribe")

        // THE SPEND JUST HAPPENED — ask what is left of it.
        //
        // Here, and not when the session closed: `Recorder.closeSession` fires
        // `onSessionClosed` BEFORE any of this runs, so a refresh there would
        // report the balance as it stood before the audio this session just
        // metered. Detached and unawaited, because the brief is what the
        // developer is waiting for and a quota readout must never sit in front
        // of it. Failure is silence; the menu keeps the previous answer.
        Task { try? await License.refresh() }

        // The script's own per-stage breakdown, which says which half of the
        // transcribe leg was slow — the app's single number cannot.
        if let line = transcribeOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.contains("timing:") })?
            .trimmingCharacters(in: .whitespaces) {
            Emit.log("transcribe: \(line)")
        }
        await MainActor.run { Personas.point(session: sessionDir, to: Personas.current()) }
        try await run(.brief, sessionDir: sessionDir, extraEnvironment: briefEnvironment())
        mark("render")
        let brief = try digest(sessionDir: sessionDir)
        // The brief exists, so the recording has done its one job.
        discardAudio(sessionDir: sessionDir)
        return brief
    }

    /// Delete the session's recordings once the brief is made.
    ///
    /// Nothing downstream reads them again: the transcript cache holds each
    /// hold's words, a re-render works from that, and `transcribe.mjs` treats a
    /// missing WAV with cached words as a hit. What is left behind is a
    /// screenshot-and-text record of a task — not a recording of somebody's
    /// voice sitting in a folder indefinitely.
    ///
    /// `DEIKO_KEEP_AUDIO=1` keeps them, and it earns its place: the WAV has
    /// twice been the only evidence that explained a failure in this project.
    /// The "Apple heard nothing" diagnosis was made by feeding the file to
    /// Sarvam by hand and finding the speech perfectly audible — the real cause
    /// was a 27% input volume, and nothing else on disk could have shown that.
    /// Shipped users get deletion; whoever is debugging keeps the choice.
    ///
    /// Only the app deletes. `make transcribe` is the diagnostic path and
    /// leaves the evidence alone.
    private static func discardAudio(sessionDir: String) {
        guard ProcessInfo.processInfo.environment["DEIKO_KEEP_AUDIO"] != "1" else {
            Emit.log("audio: kept (DEIKO_KEEP_AUDIO=1)")
            return
        }
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audio, includingPropertiesForKeys: nil
        ) else { return }
        var removed = 0
        for file in files where file.pathExtension == "wav" {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 { Emit.log("audio: deleted \(removed) recording(s) — the brief is made") }
    }

    /// Recognise every hold's audio HERE, in the app that is already running.
    ///
    /// `transcribe.mjs` gets on-device word timings by launching a second copy
    /// of Deiko through LaunchServices — because TCC blames the *responsible*
    /// process, and a binary exec'd from node inherits node's identity, which
    /// has no speech usage description. That reasoning is sound for the command
    /// line and irrelevant here: this code is already inside the app that holds
    /// the grant.
    ///
    /// What the launch was costing, measured on a 16-second two-hold session:
    /// a whole second app instance per hold, in series — process spawn, AppKit,
    /// the speech model loading — against roughly one second of actual
    /// recognition per hold at 7–12× realtime. The work was never the slow part.
    ///
    /// Holds run concurrently: the WAVs are independent and neither recogniser
    /// reads the other's output.
    ///
    /// Best-effort throughout. Every failure here simply leaves no file, and
    /// `appleTimings` falls back to launching the app exactly as before — this
    /// is a shortcut, not a new dependency.
    /// Delete every `<wav>.timing.json` in a session. See `run`'s `defer`.
    private static func removeTimingSidecars(sessionDir: String) {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audio, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".timing.json") || file.lastPathComponent == doneMarker {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Every hold's on-device timing file, recognised here while the script
    /// uploads, and then `timings.done` — the script waits for each file until
    /// that marker says no more are coming (`awaitPrecomputed`).
    ///
    /// A hold recognised live during the session already has its file and is
    /// left alone: the script reads whatever is on disk, never only what this
    /// wrote. The script DELETES a file it was not told to expect and relaunches
    /// the app to redo the work, which is why it is told (`DEIKO_TIMINGS_PENDING`).
    private static func precomputeTimings(sessionDir: String) async {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        let wavs = recordings(sessionDir: sessionDir)
        // Said even when nothing was recognised, so the script never waits
        // past the end of this.
        defer { FileManager.default.createFile(atPath: audio.appendingPathComponent(doneMarker).path, contents: nil) }

        await withTaskGroup(of: Bool.self) { group in
            for wav in wavs {
                let out = URL(fileURLWithPath: wav.path + ".timing.json")
                // Recognised already: live, during the session, or by an earlier
                // run of this pipeline (the extend flow re-runs the whole thing).
                if FileManager.default.fileExists(atPath: out.path) { continue }
                group.addTask {
                    // The same locale `transcribe.mjs` reads from
                    // DEIKO_SPEECH_LOCALE, so the words cannot differ between
                    // this path and the script's own fallback launch.
                    let result = await SpeechTiming.transcribe(
                        url: wav, localeIdentifier: SpeechLocale.selected
                    )
                    // WRITTEN EVEN WHEN RECOGNITION FAILED. A result carrying
                    // `error` is a real answer — the script reads it, throws,
                    // and takes the degraded path that keeps the transcript
                    // with estimated word times. Withholding it instead would
                    // send the script off to launch the app and wait out the
                    // same silence a second time, which is the single most
                    // expensive thing in this pipeline.
                    guard let data = try? JSONEncoder().encode(result) else {
                        Emit.log("timings: could not encode \(wav.lastPathComponent) — the script will launch the app")
                        return false
                    }
                    // Atomic for the same reason the subcommand is: the reader
                    // polls for existence and parses immediately, so a
                    // half-written file is a discarded hold.
                    do {
                        try data.write(to: out, options: .atomic)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await _ in group {}
        }
    }

    /// Written beside the WAVs when `precomputeTimings` is finished. The same
    /// name as `TIMINGS_DONE` in `packages/core/src/lib/session-io.mjs`.
    private static let doneMarker = "timings.done"

    private static func recordings(sessionDir: String) -> [URL] {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        return ((try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
    }

    private static func hasRecordings(sessionDir: String) -> Bool { !recordings(sessionDir: sessionDir).isEmpty }

    /// Which holds a session has already transcribed, and what each one said.
    ///
    /// Read before an extra hold is recorded so that afterwards we can tell which
    /// text is new — that is what gets appended to a narration the developer had
    /// already corrected, instead of throwing their correction away.
    static func holdTexts(sessionDir: String) -> [Int: String] {
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let holds = obj["holdTexts"] as? [[String: Any]]
        else { return [:] }
        var out: [Int: String] = [:]
        for entry in holds {
            if let hold = entry["hold"] as? Int { out[hold] = entry["text"] as? String ?? "" }
        }
        return out
    }

    /// Re-render only. Used after the narration is edited: the transcript has not
    /// changed, so there is nothing to recognise again.
    ///
    /// IT DOES NOT RE-POINT THE PERSONA. The first render picks the default;
    /// after that the session owns its own answer, because the review window
    /// can change it for this brief alone. Re-pointing here would have quietly
    /// reverted that choice the next time somebody fixed a misheard word.
    static func rerender(sessionDir: String) async throws -> BriefDigest {
        try await run(.brief, sessionDir: sessionDir, extraEnvironment: briefEnvironment())
        return try digest(sessionDir: sessionDir)
    }

    /// Every task note, rebuilt now (after Forget or Edit on one). The
    /// "session" handed to the script is the board root.
    static func rebuildNotes() async {
        _ = try? await run(.notes, sessionDir: Collections.root)
    }

    /// The board's search by meaning as well as words: brief ids, best
    /// first, ranked the way the memory helper ranks for agents
    /// (`packages/core/src/search-briefs.mjs`). Empty on any failure — the word
    /// filter on the board still works on its own.
    @MainActor private static var searching: Task<String?, Never>?

    @MainActor static func search(query: String) async -> [String] {
        // ONE AT A TIME. Each search is a Node process that loads the meaning
        // model; a slow typist's pauses would otherwise stack several of them
        // side by side. A newer query waits for the running one, then goes.
        _ = await searching?.value
        guard !Task.isCancelled else { return [] }
        let run = Task { await script("search-briefs.mjs", [Collections.root, query], label: "Searching") }
        searching = run
        let output = await run.value
        guard let line = output?.split(separator: "\n").last(where: { $0.hasPrefix("BRIEFS ") }),
              let ids = try? JSONDecoder().decode([String].self, from: Data(line.dropFirst(7).utf8))
        else { return [] }
        return ids
    }

    /// A piece of work as Markdown for a person (`packages/core/src/handoff.mjs`):
    /// `<dir>/handoff.md`, and the kept screenshots beside it unless
    /// `images` is off. The file's text, or nil when it could not be made.
    static func handoff(task: String, into dir: URL, images: Bool) async -> String? {
        var args = [Collections.root, task, dir.path]
        if !images { args.append("--no-images") }
        // Never mistaken for this run's: an earlier export into the same folder.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("handoff.md"))
        _ = await script("handoff.mjs", args, label: "Writing the hand-off")
        return try? String(contentsOf: dir.appendingPathComponent("handoff.md"), encoding: .utf8)
    }

    /// A script that is not a pipeline stage, with its own arguments.
    private static func script(_ name: String, _ args: [String], label: String) async -> String? {
        guard let layout = Layout.resolve() else { return nil }
        switch layout {
        case .development(let repo):
            return try? await shell((["node", "packages/core/src/\(name)"] + args.map(quoted)).joined(separator: " "), in: repo, stage: label)
        case .bundled(let resources):
            guard let node = NodeRuntime.resolve() else { return nil }
            return try? await exec(node, arguments: [resources.appendingPathComponent("scripts/\(name)").path] + args, stage: label)
        }
    }

    /// Place the brief: which collection, which task it belongs to, how much
    /// work it looks like. Written to `context.json`
    /// by the script; nil when it decided nothing — no relay, a short
    /// narration, a network that was not there.
    ///
    /// Separate from `run`, like `summary`, and for the same reason: it is a
    /// network round trip and the brief must not wait on it. The caller
    /// re-renders afterwards so the prompt on disk carries what was placed.
    static func classify(sessionDir: String) async -> SessionContext? {
        _ = try? await run(.classify, sessionDir: sessionDir)
        return SessionContext.read(sessionDir: sessionDir)
    }

    /// Three lines about the session, for the developer to glance at. Nil when
    /// there is no summary — no API key, no network, a bad response.
    ///
    /// Separate from `run` on purpose. The brief is what the window exists to
    /// show, and it is ready in milliseconds once rendering finishes; the summary
    /// is a network round trip. Folding this into `run` would hold a finished
    /// brief off screen waiting for a nicety.
    ///
    /// Never throws. A missing summary is a smaller thing than an error dialog
    /// about a missing summary.
    static func summary(sessionDir: String) async -> String? {
        _ = try? await run(.summarize, sessionDir: sessionDir)

        // Read the file rather than the command's stdout: the script prints
        // progress and skip reasons there, and a skip must read as "no summary",
        // not as a summary whose text happens to be an apology.
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("review-summary.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the drop hands over, in both the forms a destination might need.
    ///
    /// Which one travels is decided at the moment of release, by `Handoff`,
    /// from the app under the cursor — so both have to be in hand before the
    /// developer lets go.
    struct Prompt {
        /// Names the crops by absolute path. For a destination that can open
        /// one: Claude Code reads a local file with its own tools.
        let text: String
        /// Numbers the crops by their position in the message instead. For a
        /// destination that gets the image bytes pasted in, where a path would
        /// be a link it cannot follow.
        let attachedText: String
        /// The crops themselves, in the order `attachedText` numbers them.
        /// Only the released ones — a withheld crop has no path in the
        /// manifest, so it cannot be pasted by accident here either.
        let images: [String]
        /// The persona file's contents, for a browser chat. `text` names the
        /// file by path, which a local agent opens; a browser cannot, so the
        /// handoff pastes this beside the brief instead. Nil when the session
        /// was rendered without a persona.
        let personaText: String?
        /// The persona's own `.md`, for a chat that takes a document paste.
        /// The text above is the fallback for one that does not.
        let personaFile: String?
    }

    /// Read from disk rather than held in memory: the review window may have
    /// re-rendered after a narration correction, and the files are the only
    /// things that saw that.
    static func prompt(sessionDir: String) throws -> Prompt {
        let dir = URL(fileURLWithPath: sessionDir)
        let path = dir.appendingPathComponent("prompt.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw BriefPipelineError.noPrompt(path.path)
        }
        // Read from disk beside the prompt, for the same reason the prompt is:
        // the review window may have changed which persona this brief is for
        // since the orb first appeared, and the files are what saw that.
        let persona = Personas.browserText(forSession: sessionDir)
        let personaFile = Personas.file(forSession: sessionDir)
        // THE TWO MUST FALL BACK TOGETHER, and they used to fall back
        // independently.
        //
        // `brief.json` has carried `cropPath` since long before
        // `prompt-attached.txt` existed, so a session rendered by an older
        // build has the manifest but not the attached text. Read separately,
        // that produced the one combination neither form is: N images pasted
        // into the composer AND a text block naming `/Users/…/h01-r002.png`
        // underneath them — the dead link this feature exists to remove, beside
        // the attachments that made it unnecessary. The mirror case is worse
        // still: `attachedText` announcing "The 3 screenshots above" with
        // nothing attached, which is a message inviting the model to describe
        // pictures it was never given.
        //
        // So: no attached text, no attaching. The path form works everywhere it
        // ever did, and re-rendering the session produces both.
        guard let attached = try? String(
            contentsOf: dir.appendingPathComponent("prompt-attached.txt"), encoding: .utf8
        ) else {
            return Prompt(text: text, attachedText: text, images: [],
                          personaText: persona, personaFile: personaFile)
        }
        let images = (try? digest(sessionDir: sessionDir).cropPaths) ?? []
        // Same rule from the other side: an attached text that numbers
        // screenshots is only usable if there are screenshots to number.
        return Prompt(
            text: text,
            attachedText: images.isEmpty ? text : attached,
            images: images,
            personaText: persona,
            personaFile: personaFile
        )
    }

    /// Save the developer's corrected narration next to the session. The renderer
    /// picks this up; an empty edit removes it rather than writing a blank
    /// override, so "I cleared the box" means "use what was heard".
    static func writeNarrationOverride(_ text: String, sessionDir: String) throws {
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("narration.override.txt")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: path)
        } else {
            try trimmed.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    /// Screenshots the developer has taken out by hand, by basename.
    ///
    /// BASENAMES, not paths: the session directory belongs to the user and can
    /// be moved between capture and review, and a list of absolute paths would
    /// quietly stop excluding anything the moment it was. The renderer reads
    /// this file and drops the whole referent — see the comment there for why
    /// nulling its `cropPath` would ship the removed screenshot's text.
    static func cropExclusions(sessionDir: String) -> [String] {
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("crops.excluded.json")
        guard let data = try? Data(contentsOf: path),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    static func writeCropExclusions(_ names: [String], sessionDir: String) throws {
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("crops.excluded.json")
        guard !names.isEmpty else {
            try? FileManager.default.removeItem(at: path)
            return
        }
        try JSONEncoder().encode(names).write(to: path, options: .atomic)
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    /// Read a finished session's manifest. Internal because the main window
    /// lists sessions from exactly this, and a second reader of the same file
    /// would be a second opinion about what a session is.
    static func digest(sessionDir: String) throws -> BriefDigest {
        let manifestPath = URL(fileURLWithPath: sessionDir).appendingPathComponent("brief.json")
        guard let data = try? Data(contentsOf: manifestPath) else {
            throw BriefPipelineError.noManifest(manifestPath.path)
        }
        let manifest = try JSONDecoder().decode(BriefManifest.self, from: data)
        return BriefDigest(
            sessionDir: sessionDir,
            summary: manifest.summary,
            cropsReleased: manifest.referents.filter { $0.cropPath != nil }.count,
            cropsWithheld: manifest.referents.filter { $0.cropWithheld != nil }.count,
            withheldReasons: NSOrderedSet(array: manifest.referents.compactMap(\.cropWithheld))
                .array as? [String] ?? [],
            cropPaths: manifest.referents.compactMap(\.cropPath),
            captions: Dictionary(
                manifest.referents.compactMap { r in r.cropPath.flatMap { path in r.said.map { (path, $0) } } },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// One decimal, the same shape `transcribe.mjs` prints, so the app's line
    /// and the script's line read as one measurement rather than two formats.
    private static func seconds(_ duration: Duration) -> String {
        let s = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        return String(format: "%.1fs", s)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A checkout: through `make`, in a login shell, with `.env` sourced.
    @discardableResult
    private static func shell(
        _ command: String, in repo: URL, stage: String, extraEnvironment: [String: String] = [:]
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` for the login profile (nvm), `-c` for the command. The `set -a`
        // pair exports everything in .env for the child, which is where
        // SARVAM_API_KEY lives; `[ -f .env ]` so a checkout without one fails
        // in the transcriber with its own clear message rather than here with
        // a shell error about a missing file.
        process.arguments = [
            "-lc",
            "cd \(quoted(repo.path)) && set -a && [ -f .env ] && . ./.env; set +a; \(command)",
        ]
        process.currentDirectoryURL = repo
        // Same environment as the bundled path. The `.env` this login shell
        // sources still wins for the API keys — but `DEIKO_APP_PATH` is not in
        // any `.env`, so the checkout gets told where the app is too, rather
        // than relying on it happening to sit at `<repo>/build/Deiko.app`.
        process.environment = Credentials.childEnvironment().merging(extraEnvironment) { _, new in new }
        return try await capture(process, stage: stage)
    }

    /// A bundle: the executable and its arguments, with no shell in between.
    ///
    /// Nothing is quoted because nothing is parsed — a session path containing a
    /// space, a quote or a `$` reaches the script exactly as written. The shell
    /// path above cannot offer that, which is one more reason it stays confined
    /// to the developer's own checkout.
    @discardableResult
    private static func exec(
        _ executable: URL, arguments: [String], stage: String,
        extraEnvironment: [String: String] = [:]
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Credentials.childEnvironment().merging(extraEnvironment) { _, new in new }
        return try await capture(process, stage: stage)
    }

    /// How long any one stage may take before Deiko stops waiting for it.
    ///
    /// GENEROUS, because the honest slow case is real: a long session's audio
    /// against a cold provider is tens of seconds, and cutting that off would
    /// throw away work that was about to arrive. What this exists for is the
    /// case that never arrives at all — most often a quarantined Node runtime,
    /// which `isExecutableFile` cannot see (quarantine bites at exec, not at
    /// stat), so the child is spawned, refused by Gatekeeper, and the
    /// continuation is simply never resumed. The orb reads "Transcribing…"
    /// until the app is quit.
    private static let stageTimeout: DispatchTimeInterval = .seconds(180)

    /// Run a prepared process and collect everything it says.
    private static func capture(_ process: Process, stage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Read the pipe on a queue, not after waiting. A build that writes
            // more than the 64KB pipe buffer would otherwise block forever with
            // nobody draining it, and the app would hang instead of finishing.
            let collected = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }

            // THE WATCHDOG RESUMES NOTHING. It only ends the process, which
            // makes the termination handler fire on its own with a non-zero
            // status — so there is exactly one path out of this continuation
            // and no way to resume it twice. `timedOut` is read there to
            // explain a status that would otherwise say only "exit 15".
            let watchdog = Watchdog(process)
            watchdog.arm(after: stageTimeout)

            process.terminationHandler = { proc in
                watchdog.disarm()
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = collected.text()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else if watchdog.firedOnTime {
                    continuation.resume(throwing: BriefPipelineError.commandFailed(
                        stage: stage,
                        output: "timed out after 180s\n" + output
                    ))
                } else {
                    continuation.resume(throwing: BriefPipelineError.commandFailed(
                        stage: stage,
                        output: output.isEmpty ? "exit \(proc.terminationStatus)" : output
                    ))
                }
            }

            do { try process.run() } catch {
                watchdog.disarm()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// A deadline for one child process.
///
/// Holds the process and two bools behind one lock, because the timer queue
/// and the termination handler both touch them and neither can be told which
/// arrives first. `@unchecked Sendable` for the same reason `OutputCollector`
/// is: the lock is the checking.
///
/// It never resumes anything. Ending the process is enough — the termination
/// handler fires on its own and stays the single exit from the continuation.
private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var done = false
    private var fired = false

    init(_ process: Process) { self.process = process }

    /// True when the deadline ended this process, rather than the process
    /// ending on its own with a status of its own.
    var firedOnTime: Bool { lock.lock(); defer { lock.unlock() }; return fired }

    func disarm() { lock.lock(); done = true; lock.unlock() }

    func arm(after timeout: DispatchTimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            if done { lock.unlock(); return }
            fired = true
            lock.unlock()

            process.terminate()
            // SIGTERM is a request. A process wedged in an uninterruptible
            // state ignores it, and the hang we are fixing would simply move
            // five seconds later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                lock.lock()
                let stillWaiting = !done
                lock.unlock()
                if stillWaiting, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}

/// Accumulates pipe output from the reader queue. A plain `var` captured by the
/// handler is a data race; the lock is cheaper than reasoning about which queue
/// the last chunk landed on.
private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
