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
    private static func run(_ stage: Stage, sessionDir: String) async throws -> String {
        guard let layout = Layout.resolve() else {
            throw BriefPipelineError.pipelineNotFound(Bundle.main.bundleURL.path)
        }
        switch layout {
        case .development(let repo):
            return try await shell(
                "make \(stage.makeTarget) SESSION=\(quoted(sessionDir))",
                in: repo,
                stage: stage.label
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
                stage: stage.label
            )
        }
    }

    /// Transcribe, then render. Returns the brief in short.
    static func run(sessionDir: String) async throws -> BriefDigest {
        try await run(.transcribe, sessionDir: sessionDir)
        try await run(.brief, sessionDir: sessionDir)
        return try digest(sessionDir: sessionDir)
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

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A checkout: through `make`, in a login shell, with `.env` sourced.
    @discardableResult
    private static func shell(_ command: String, in repo: URL, stage: String) async throws -> String {
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
        process.environment = Credentials.childEnvironment()
        return try await capture(process, stage: stage)
    }

    /// A bundle: the executable and its arguments, with no shell in between.
    ///
    /// Nothing is quoted because nothing is parsed — a session path containing a
    /// space, a quote or a `$` reaches the script exactly as written. The shell
    /// path above cannot offer that, which is one more reason it stays confined
    /// to the developer's own checkout.
    @discardableResult
    private static func exec(_ executable: URL, arguments: [String], stage: String) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Credentials.childEnvironment()
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
