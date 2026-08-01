import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// FINDING NODE
//
// The transcribe-and-render work is Node, and a shipped app cannot assume the
// machine has any. One resolver answers "which node" for everything: the
// pipeline the app runs itself, AND the `command` written into a client's MCP
// config when the user connects one — so the bridge Claude Code spawns is the
// same runtime the app used, rather than whatever that process happens to find
// on its PATH.
//
// The order matters and is deliberate:
//
//   1. BUNDLED  — `Contents/Resources/node`, present only in `make dist` builds.
//      Wins outright: if we shipped a runtime, that is the one we tested against.
//   2. PATH     — a plain `node`, for a developer running from Terminal.
//      Also the case for anyone who installed Node the ordinary way.
//   3. LOGIN SHELL — `zsh -lc 'command -v node'`. An app launched from Finder
//      inherits none of a terminal's environment, and on this machine node lives
//      under nvm at a version-specific path that only the login profile knows.
//
// Deciding the bundle later costs nothing because of this file: `make dist`
// drops a binary into Resources and step 1 starts winning. Nothing else changes.
// ─────────────────────────────────────────────────────────────────────────────

enum NodeRuntime {

    /// Where Node is, or nil if this machine has none we can find.
    ///
    /// A lazy `static let` rather than a hand-rolled cache: Swift initialises it
    /// exactly once, thread-safely, on first use. The login-shell probe spawns a
    /// process and the pipeline asks for this on every stage of every session,
    /// so "once" matters.
    private static let resolved: URL? = bundled() ?? onPath() ?? viaLoginShell()

    static func resolve() -> URL? { resolved }

    private static func bundled() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("node")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func onPath() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The nvm case. `command -v` rather than `which`: it is a shell builtin, so
    /// it reports what the shell would actually run, including a shell function
    /// nvm may have installed.
    private static func viaLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// WHERE THE PIPELINE LIVES
//
// Two answers, and the DEVELOPMENT one wins when both are available.
//
// That order is the point. This project's loop is `make bundle && open
// build/Fovea.app`, and a bundled copy that shadowed the checkout would mean
// every edit to a script needed a re-bundle before it could be seen — the exact
// slow loop the app was built to avoid. A developer's app runs the developer's
// scripts; everyone else's runs the ones inside the bundle.
// ─────────────────────────────────────────────────────────────────────────────

enum Layout {
    /// `<repo>/build/Fovea.app` — a Makefile sits beside the bundle.
    case development(repo: URL)
    /// Scripts and built packages live in `Contents/Resources`.
    case bundled(resources: URL)

    static func resolve() -> Layout? {
        let fm = FileManager.default

        // `<repo>/build/Fovea.app` → up two → `<repo>`.
        let beside = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if fm.fileExists(atPath: beside.appendingPathComponent("Makefile").path) {
            return .development(repo: beside)
        }

        if let resources = Bundle.main.resourceURL,
           fm.fileExists(atPath: resources.appendingPathComponent("scripts").path) {
            return .bundled(resources: resources)
        }
        return nil
    }
}
