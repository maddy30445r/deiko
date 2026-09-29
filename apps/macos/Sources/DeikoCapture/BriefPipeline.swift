import Foundation

// Runs the Node transcribe-and-render pipeline for a closed session. The renderer stays in Node rather
// than being ported to Swift, so there is one implementation of "what does a brief say".
//
// In a checkout the stages run through a login shell (`zsh -lc`) rather than exec'ing node directly: an
// app launched from Finder inherits none of a terminal's environment, and `node` and the repo's `.env`
// are found through the shell profile.

/// The brief in short, decoded from `brief.json`'s `summary`, which the renderer computes. Deliberately
/// not parsed out of the markdown: a reader that scrapes prose breaks when the prose is reworded.
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
    /// Some or all of the words came from the on-device recogniser rather than the cloud (spent free hours,
    /// an unreachable relay, a chunk that failed). Optional because older sessions have no such key;
    /// absent reads as false, meaning "nothing told us it was degraded".
    var degraded: Bool?
    /// Which degradation: "trial", "monthly", "ceiling", "unavailable" or "timing". They have different
    /// answers and only two concern the user's plan. Written by `packages/core/src/lib/cloud.mjs`,
    /// rendered by `ReviewView.degradedSentence`.
    var degradedReason: String?
    /// Who produced the words — "sarvam", "deiko", or "on-device". Feeds the
    /// one line that says what left this Mac.
    var transcriber: String?
    /// How many requests actually reached the network. Zero with a `deiko` transcriber means the relay
    /// was never reached (or every hold came from the cache, as when an old session is reopened), so no
    /// audio left whatever the configuration says.
    var uploadedChunks: Int?
    /// Screenshot labels dropped because the sentence they quoted is no longer in the corrected
    /// narration. Surfaced so a brief never quietly means less than the developer thinks.
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
        /// What was said while this screenshot was drawn. Absent on older briefs.
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
    /// Why they were withheld, distinct and in the order the renderer gave them. `render-brief.mjs` has
    /// two reasons and only one concerns a credential; the other is "Deiko could not read this to check",
    /// which fires when Screen Recording is granted but the app has not been relaunched. A bare count
    /// would show the alarming sentence for both.
    let withheldReasons: [String]
    /// The images themselves, so the window can show what is about to go rather than a count of it.
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
            // Distinct from `.noManifest`: `brief.json` loaded, so rendering did not finish. The file
            // named here does not exist, so telling the user to paste it themselves would be a dead end;
            // "Point at more" re-runs the render.
            return "The brief didn't finish rendering — \(path) is missing. "
                + "Use \"Point at more\" to re-run it before sending again."
        }
    }
}

enum BriefPipeline {

    /// One stage of the pipeline: a Node script, and the `make` target that wraps it in a checkout.
    ///
    /// Development goes through `make` because those targets build the TypeScript packages first, and a
    /// script run against a stale or absent `dist/` fails in a misleading way. A bundle ships `dist/` built.
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

    /// The one setting the renderer reads from the app: whether a brief classified as quick may carry the
    /// "a fast model is probably enough" line. A defaults key, so the Settings toggle and this cannot drift.
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
            // No shell here: the executable and its argument are passed directly, so a session path with
            // a space or a quote cannot be misread.
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
    /// Timed, and the timing is logged to `launch.jsonl`: the app's stages, plus `transcribe.mjs`'s own
    /// stage line.
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
        // Emitted on the failure path too, via defer: a run that died late is the one whose timing matters.
        defer {
            Emit.log("pipeline: " + marks.joined(separator: " · ")
                + " · total \(seconds(started.duration(to: clock.now)))")
        }

        // On-device recognition and the upload run together: the script waits for each hold's timing file
        // (`DEIKO_TIMINGS_PENDING`) beside its upload, rather than the upload waiting for all of them.
        let recordings = hasRecordings(sessionDir: sessionDir)
        // A marker left by a run that died would tell the script "finished"
        // before this run has started.
        try? FileManager.default.removeItem(atPath: "\(sessionDir)/audio/\(doneMarker)")
        async let precomputed: Void = precomputeTimings(sessionDir: sessionDir)
        // Every timing file is transient: one that outlives the run is a verbatim transcript of the
        // narration in a directory that may be handed to somebody. `transcribe.mjs` deletes each it
        // consumes, but a hold served from the transcript cache is never read, so sweep unconditionally,
        // including on failure.
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

        // Refresh the quota now, not when the session closed: `Recorder.closeSession` fires
        // `onSessionClosed` before this runs, so a refresh there would report the balance from before this
        // session's audio was metered. Detached and unawaited so a quota readout never sits in front of
        // the brief; failure is silent and the menu keeps the previous answer.
        Task { try? await License.refresh() }

        // The script's own per-stage breakdown, which says which half of the transcribe leg was slow.
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
    /// Nothing downstream reads them again: the transcript cache holds each hold's words, a re-render
    /// works from that, and `transcribe.mjs` treats a missing WAV with cached words as a hit.
    /// `DEIKO_KEEP_AUDIO=1` keeps them for debugging. Only the app deletes; `make transcribe` is the
    /// diagnostic path and leaves the evidence alone.
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

    /// Recognises every hold's audio in the running app while the script uploads, then writes
    /// `timings.done`; the script waits for each file until that marker says no more are coming
    /// (`awaitPrecomputed`).
    ///
    /// `transcribe.mjs` can launch a second copy of Deiko through LaunchServices for on-device timings,
    /// because TCC blames the responsible process. Here the code is already inside the app that holds
    /// the grant, so that launch is skipped. Holds run concurrently. Best-effort: a failure leaves no
    /// file and the script falls back to its own launch.
    ///
    /// A hold recognised live during the session already has its file and is left alone: the script
    /// reads whatever is on disk. It deletes a file it was not told to expect and relaunches the app to
    /// redo the work, which is why it is told (`DEIKO_TIMINGS_PENDING`).
    private static func precomputeTimings(sessionDir: String) async {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        let wavs = recordings(sessionDir: sessionDir)
        // Written even when nothing was recognised, so the script never waits past this point.
        defer { FileManager.default.createFile(atPath: audio.appendingPathComponent(doneMarker).path, contents: nil) }

        await withTaskGroup(of: Bool.self) { group in
            for wav in wavs {
                let out = URL(fileURLWithPath: wav.path + ".timing.json")
                // Recognised already: live, during the session, or by an earlier run of this pipeline
                // (the extend flow re-runs the whole thing).
                if FileManager.default.fileExists(atPath: out.path) { continue }
                group.addTask {
                    // The same locale `transcribe.mjs` reads from DEIKO_SPEECH_LOCALE, so the words cannot
                    // differ between this path and the script's own launch.
                    let result = await SpeechTiming.transcribe(
                        url: wav, localeIdentifier: SpeechLocale.selected
                    )
                    // Written even when recognition failed: a result carrying `error` is a real answer. The
                    // script reads it and takes the degraded path that keeps the transcript with estimated
                    // word times, instead of launching the app and waiting out the same silence again.
                    guard let data = try? JSONEncoder().encode(result) else {
                        Emit.log("timings: could not encode \(wav.lastPathComponent) — the script will launch the app")
                        return false
                    }
                    // Atomic for the same reason as the subcommand: the reader polls for existence and parses
                    // immediately.
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

    /// Written beside the WAVs when `precomputeTimings` is finished. Same name as `TIMINGS_DONE` in
    /// `packages/core/src/lib/session-io.mjs`; change both.
    private static let doneMarker = "timings.done"

    private static func recordings(sessionDir: String) -> [URL] {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        return ((try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
    }

    private static func hasRecordings(sessionDir: String) -> Bool { !recordings(sessionDir: sessionDir).isEmpty }

    /// Which holds a session has already transcribed, and what each one said. Read before an extra hold is
    /// recorded so the new text can be told apart and appended to a narration the developer had already
    /// corrected.
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

    /// Re-render only, used after the narration is edited: the transcript has not changed, so nothing is
    /// recognised again. It does not re-point the persona: the first render picks the default and after
    /// that the session owns its answer, because the review window can change it for one brief.
    static func rerender(sessionDir: String) async throws -> BriefDigest {
        try await run(.brief, sessionDir: sessionDir, extraEnvironment: briefEnvironment())
        return try digest(sessionDir: sessionDir)
    }

    /// Every task note, rebuilt now (after Forget or Edit on one). The
    /// "session" handed to the script is the board root.
    static func rebuildNotes() async {
        _ = try? await run(.notes, sessionDir: Collections.root)
    }

    /// The board's search by meaning as well as words: brief ids, best first, ranked as the memory helper
    /// ranks for agents (`packages/core/src/search-briefs.mjs`). Empty on any failure; the board's word
    /// filter still works on its own.
    @MainActor private static var searching: Task<String?, Never>?

    @MainActor static func search(query: String) async -> [String] {
        // One at a time: each search is a Node process that loads the meaning model, so a slow typist's
        // pauses would otherwise stack several. A newer query waits for the running one.
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
        // Remove an earlier export so it cannot be mistaken for this run's.
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

    /// Place the brief: which collection, which task it belongs to, how much work it looks like, written to
    /// `context.json` by the script. Nil when it decided nothing (no relay, a short narration, no network).
    ///
    /// Separate from `run`, like `summary`, because it is a network round trip the brief must not wait
    /// on. The caller re-renders afterwards so the prompt on disk carries what was placed.
    static func classify(sessionDir: String) async -> SessionContext? {
        _ = try? await run(.classify, sessionDir: sessionDir)
        return SessionContext.read(sessionDir: sessionDir)
    }

    /// Three lines about the session, for the developer to glance at. Nil when there is no summary (no API
    /// key, no network, a bad response).
    ///
    /// Separate from `run` because the brief is what the window exists to show and is ready in
    /// milliseconds, while the summary is a network round trip. Never throws: a missing summary is a
    /// smaller thing than an error dialog about one.
    static func summary(sessionDir: String) async -> String? {
        _ = try? await run(.summarize, sessionDir: sessionDir)

        // Read the file rather than the command's stdout, where the script prints progress and skip
        // reasons: a skip must read as "no summary", not as a summary whose text is an apology.
        let path = URL(fileURLWithPath: sessionDir).appendingPathComponent("review-summary.txt")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the drop hands over, in both forms a destination might need. `Handoff` picks one at the
    /// moment of release from the app under the cursor, so both must be in hand before the developer
    /// lets go.
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
        // Read from disk beside the prompt, for the same reason: the review window may have changed the
        // persona since the orb first appeared.
        let persona = Personas.browserText(forSession: sessionDir)
        let personaFile = Personas.file(forSession: sessionDir)
        // The two must fall back together. A session rendered by an older build has `brief.json` with
        // `cropPath` but no `prompt-attached.txt`. Read separately, that would paste N images under a text
        // block that still names their local paths, or announce "The 3 screenshots above" with nothing
        // attached and invite the model to describe pictures it was never given. So: no attached text, no
        // attaching. The path form works everywhere, and re-rendering produces both.
        guard let attached = try? String(
            contentsOf: dir.appendingPathComponent("prompt-attached.txt"), encoding: .utf8
        ) else {
            return Prompt(text: text, attachedText: text, images: [],
                          personaText: persona, personaFile: personaFile)
        }
        let images = (try? digest(sessionDir: sessionDir).cropPaths) ?? []
        // Same rule from the other side: attached text that numbers screenshots is only usable if there
        // are screenshots to number.
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
    /// Basenames, not paths: the session directory can be moved between capture and review. The renderer
    /// reads this file and drops the whole referent, because nulling its `cropPath` would ship the removed
    /// screenshot's text.
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

    /// Read a finished session's manifest. Internal because the main window lists sessions from this too;
    /// a second reader would be a second opinion about what a session is.
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

    /// One decimal, the same shape `transcribe.mjs` prints, so the two lines read as one measurement.
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
        // `-l` for the login profile (nvm), `-c` for the command. The `set -a` pair exports everything in
        // .env to the child; `[ -f .env ]` so a checkout without one fails in the transcriber with its own
        // clear message rather than a shell error.
        process.arguments = [
            "-lc",
            "cd \(quoted(repo.path)) && set -a && [ -f .env ] && . ./.env; set +a; \(command)",
        ]
        process.currentDirectoryURL = repo
        // Same environment as the bundled path. The `.env` this shell sources still wins for API keys, but
        // `DEIKO_APP_PATH` is in no `.env`, so the checkout is told where the app is too rather than
        // assuming `<repo>/build/Deiko.app`.
        process.environment = Credentials.childEnvironment().merging(extraEnvironment) { _, new in new }
        return try await capture(process, stage: stage)
    }

    /// A bundle: the executable and its arguments, with no shell in between.
    ///
    /// Nothing is quoted because nothing is parsed, so a session path containing a space, a quote or a
    /// `$` reaches the script exactly as written.
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
    /// Generous, because a long session's audio against a cold provider takes tens of seconds. It exists
    /// for the case that never arrives, most often a quarantined Node runtime: quarantine bites at exec,
    /// not at stat, so `isExecutableFile` cannot see it, and the child is spawned, refused by Gatekeeper,
    /// and the continuation is never resumed.
    private static let stageTimeout: DispatchTimeInterval = .seconds(180)

    /// Run a prepared process and collect everything it says.
    private static func capture(_ process: Process, stage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Read the pipe on a queue, not after waiting: output beyond the 64KB pipe buffer would block
            // the child with nobody draining it.
            let collected = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }

            // The watchdog resumes nothing; it only ends the process, so the termination handler fires on
            // its own and is the single way out of this continuation. `firedOnTime` explains a status that
            // would otherwise say only "exit 15".
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
/// Holds the process and two bools behind one lock, since the timer queue and the termination handler
/// both touch them. `@unchecked Sendable` because the lock is the checking. It never resumes anything:
/// ending the process is enough, since the termination handler stays the single exit from the
/// continuation.
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
            // SIGTERM is a request; a process wedged in an uninterruptible state ignores it, so escalate to
            // SIGKILL after five seconds.
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

/// Accumulates pipe output from the reader queue; a plain `var` captured by the handler would be a data race.
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
