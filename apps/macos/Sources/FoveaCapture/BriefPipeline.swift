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
    case repoNotFound(String)
    case commandFailed(stage: String, output: String)
    case noManifest(String)

    var errorDescription: String? {
        switch self {
        case .repoNotFound(let path):
            return "Could not find the Fovea repo from the app bundle (looked at \(path)). "
                + "The app has to sit in the repo's build/ folder to run the pipeline."
        case .commandFailed(let stage, let output):
            return "\(stage) failed.\n\n\(output)"
        case .noManifest(let path):
            return "The brief rendered but \(path) is missing."
        }
    }
}

enum BriefPipeline {

    /// The repo this app was built into: `<repo>/build/Fovea.app`.
    ///
    /// Derived from the bundle rather than configured, so a fresh clone works
    /// with no setup — and so moving the app somewhere else fails loudly here
    /// instead of silently running against the wrong checkout.
    static func repoRoot() -> URL? {
        let root = Bundle.main.bundleURL          // <repo>/build/Fovea.app
            .deletingLastPathComponent()          // <repo>/build
            .deletingLastPathComponent()          // <repo>
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Makefile").path)
            ? root
            : nil
    }

    /// Transcribe, then render. Returns the brief in short.
    static func run(sessionDir: String) async throws -> BriefDigest {
        guard let repo = repoRoot() else {
            throw BriefPipelineError.repoNotFound(Bundle.main.bundleURL.path)
        }

        try await shell("make transcribe SESSION=\(quoted(sessionDir))", in: repo, stage: "Transcribing")
        try await shell("make brief SESSION=\(quoted(sessionDir))", in: repo, stage: "Rendering the brief")
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
        guard let repo = repoRoot() else {
            throw BriefPipelineError.repoNotFound(Bundle.main.bundleURL.path)
        }
        try await shell("make brief SESSION=\(quoted(sessionDir))", in: repo, stage: "Rendering the brief")
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
        guard let repo = repoRoot() else { return nil }
        try? await shell("make summarize SESSION=\(quoted(sessionDir))", in: repo, stage: "Summarising")

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
        guard let repo = repoRoot() else {
            throw BriefPipelineError.repoNotFound(Bundle.main.bundleURL.path)
        }
        try await shell("make send SESSION=\(quoted(sessionDir))", in: repo, stage: "Sending")
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

    @discardableResult
    private static func shell(_ command: String, in repo: URL, stage: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
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
