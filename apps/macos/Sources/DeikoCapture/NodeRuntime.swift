import Foundation

/// Finds the `node` the pipeline runs on, in order:
///  1. `Contents/Resources/node`, present only in `make dist` builds; a bundled runtime is the one that was tested.
///  2. A plain `node` on `PATH`.
///  3. `zsh -lc 'command -v node'`: an app launched from Finder inherits none of a terminal's environment,
///     and nvm installs node at a version-specific path only the login profile knows.
enum NodeRuntime {

    /// Where Node is, or nil if none can be found. A lazy `static let` so the login-shell probe,
    /// which spawns a process, runs once however many stages ask.
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

    /// The nvm case. `command -v` rather than `which`: as a shell builtin it reports what the shell
    /// would run, including a shell function nvm may have installed.
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

/// Where the pipeline lives. The development layout wins when both apply, so a developer's app runs
/// the checkout's scripts and edits show up without re-bundling.
enum Layout {
    /// `<repo>/build/Deiko.app` — a Makefile sits beside the bundle.
    case development(repo: URL)
    /// Scripts and built packages live in `Contents/Resources`.
    case bundled(resources: URL)

    static func resolve() -> Layout? {
        let fm = FileManager.default

        // Checks this checkout's shape, not merely a Makefile: a shipped app in `~/Applications` with a
        // `~/Makefile` two folders up must not run that `make` and source the `.env` beside it.
        let build = Bundle.main.bundleURL.deletingLastPathComponent()
        let beside = build.deletingLastPathComponent()
        if build.lastPathComponent == "build",
           fm.fileExists(atPath: beside.appendingPathComponent("Makefile").path),
           fm.fileExists(atPath: beside.appendingPathComponent("apps/macos/Package.swift").path) {
            return .development(repo: beside)
        }

        if let resources = Bundle.main.resourceURL,
           fm.fileExists(atPath: resources.appendingPathComponent("scripts").path) {
            return .bundled(resources: resources)
        }
        return nil
    }
}
