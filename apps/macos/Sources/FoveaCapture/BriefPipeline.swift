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
}

private struct BriefManifest: Codable {
    struct Referent: Codable {
        let cropPath: String?
        let cropWithheld: String?
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
}

enum BriefPipelineError: LocalizedError {
    case pipelineNotFound(String)
    case nodeNotFound
    case commandFailed(stage: String, output: String)
    case noManifest(String)

    var errorDescription: String? {
        switch self {
        case .pipelineNotFound(let path):
            return "Could not find Fovea's pipeline, in the app bundle or beside it (looked at \(path))."
        case .nodeNotFound:
            return "Could not find Node on this Mac. Fovea needs it to transcribe and render a brief."
        case .commandFailed(let stage, let output):
            return "\(stage) failed.\n\n\(output)"
        case .noManifest(let path):
            return "The brief rendered but \(path) is missing."
        }
    }
}

enum BriefPipeline {

    /// One stage of the pipeline: a Node script, and the `make` target that
    /// wraps it in a checkout.
    ///
    /// The two spellings exist because the development path must keep going
    /// through `make`: those targets build the TypeScript packages first
    /// (`npm run build -w @fovea/alignment`), and a script run directly against
    /// a stale or absent `dist/` fails in a way that looks like a bug in the
    /// script. A bundle ships `dist/` already built, so there is nothing to
    /// build and nothing to wrap.
    private enum Stage {
        case transcribe, brief, summarize, send

        var script: String {
            switch self {
            case .transcribe: return "transcribe.mjs"
            case .brief: return "render-brief.mjs"
            case .summarize: return "summarize.mjs"
            case .send: return "send-brief.mjs"
            }
        }

        var makeTarget: String {
            switch self {
            case .transcribe: return "transcribe"
            case .brief: return "brief"
            case .summarize: return "summarize"
            case .send: return "send"
            }
        }

        /// What the orb says while this is running.
        var label: String {
            switch self {
            case .transcribe: return "Transcribing"
            case .brief: return "Rendering the brief"
            case .summarize: return "Summarising"
            case .send: return "Sending"
            }
        }
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

        let precomputed = await precomputeTimings(sessionDir: sessionDir)
        mark("precompute")
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
            // Only claimed when a file was actually written. Asserting it
            // unconditionally would make the script trust a file that is not
            // there for holds we failed to recognise, and the launch fallback
            // is exactly what should happen then.
            extraEnvironment: precomputed ? ["FOVEA_TIMINGS_READY": "1"] : [:]
        )
        mark("transcribe")
        // The script's own per-stage breakdown, which says which half of the
        // transcribe leg was slow — the app's single number cannot.
        if let line = transcribeOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.contains("timing:") })?
            .trimmingCharacters(in: .whitespaces) {
            Emit.log("transcribe: \(line)")
        }
        try await run(.brief, sessionDir: sessionDir)
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
    /// `FOVEA_KEEP_AUDIO=1` keeps them, and it earns its place: the WAV has
    /// twice been the only evidence that explained a failure in this project.
    /// The "Apple heard nothing" diagnosis was made by feeding the file to
    /// Sarvam by hand and finding the speech perfectly audible — the real cause
    /// was a 27% input volume, and nothing else on disk could have shown that.
    /// Shipped users get deletion; whoever is debugging keeps the choice.
    ///
    /// Only the app deletes. `make transcribe` is the diagnostic path and
    /// leaves the evidence alone.
    private static func discardAudio(sessionDir: String) {
        guard ProcessInfo.processInfo.environment["FOVEA_KEEP_AUDIO"] != "1" else {
            Emit.log("audio: kept (FOVEA_KEEP_AUDIO=1)")
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
    /// of Fovea through LaunchServices — because TCC blames the *responsible*
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
        for file in files where file.lastPathComponent.hasSuffix(".timing.json") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Returns whether at least one timing file is NOW ON DISK — not whether
    /// this function put it there.
    ///
    /// That distinction is the whole contract. The caller uses the answer to set
    /// `FOVEA_TIMINGS_READY`, and the script reads a precomputed file only when
    /// that is set; without it, it *deletes* any file it finds and launches a
    /// second copy of the app to redo the work. So reporting "I wrote nothing"
    /// for a session whose holds were all recognised live would throw away every
    /// one of those results and take the slowest path available — the exact
    /// opposite of what recognising during capture is for.
    ///
    /// Safe when only some holds have files: the script checks per hold and
    /// falls back to launching for the ones that do not.
    private static func precomputeTimings(sessionDir: String) async -> Bool {
        let audio = URL(fileURLWithPath: sessionDir).appendingPathComponent("audio")
        guard let wavs = try? FileManager.default.contentsOfDirectory(
            at: audio, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "wav" }), !wavs.isEmpty else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            var alreadyPresent = false
            for wav in wavs {
                let out = URL(fileURLWithPath: wav.path + ".timing.json")
                // Recognised already: live, during the session, or by an earlier
                // run of this pipeline (the extend flow re-runs the whole thing).
                if FileManager.default.fileExists(atPath: out.path) {
                    alreadyPresent = true
                    continue
                }
                group.addTask {
                    // `en-IN` because that is `transcribe.mjs`'s own default
                    // for `--locale`. Recognising here under a different locale
                    // would quietly change the words compared with the CLI.
                    let result = await SpeechTiming.transcribe(
                        url: wav, localeIdentifier: "en-IN"
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
            var any = alreadyPresent
            for await wrote in group where wrote { any = true }
            return any
        }
    }

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
    static func rerender(sessionDir: String) async throws -> BriefDigest {
        try await run(.brief, sessionDir: sessionDir)
        return try digest(sessionDir: sessionDir)
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

    /// Hand the brief to Claude Code. THE approval step — `send-brief.mjs` owns
    /// the outbox rules (one pending brief at a time, and why), and is spawned
    /// rather than reimplemented so those rules have exactly one home.
    static func send(sessionDir: String) async throws {
        try await run(.send, sessionDir: sessionDir)
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

    // ── Plumbing ────────────────────────────────────────────────────────────

    private static func digest(sessionDir: String) throws -> BriefDigest {
        let manifestPath = URL(fileURLWithPath: sessionDir).appendingPathComponent("brief.json")
        guard let data = try? Data(contentsOf: manifestPath) else {
            throw BriefPipelineError.noManifest(manifestPath.path)
        }
        let manifest = try JSONDecoder().decode(BriefManifest.self, from: data)
        return BriefDigest(
            sessionDir: sessionDir,
            summary: manifest.summary,
            cropsReleased: manifest.referents.filter { $0.cropPath != nil }.count,
            cropsWithheld: manifest.referents.filter { $0.cropWithheld != nil }.count
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
        // sources still wins for the API keys — but `FOVEA_APP_PATH` is not in
        // any `.env`, so the checkout gets told where the app is too, rather
        // than relying on it happening to sit at `<repo>/build/Fovea.app`.
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

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = collected.text()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BriefPipelineError.commandFailed(
                        stage: stage,
                        output: output.isEmpty ? "exit \(proc.terminationStatus)" : output
                    ))
                }
            }

            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
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
