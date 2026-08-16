import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// WHEN FOVEA DIES, SAY SO NEXT TIME.
//
// There was nothing here at all: an uncaught exception or a signal took the
// menu-bar app down without a trace, and since it has no Dock icon and no
// window, "it disappeared" is the entire bug report a user can write. macOS
// keeps a .ips in ~/Library/DiagnosticReports, which nobody who is not already
// a developer will ever find, and which "Reveal log" does not point at.
//
// DELIBERATELY NOT A CRASH SDK. Sentry or Crashlytics would mean a network
// pipeline, a DSN to configure, a privacy surface to describe in PAYMENTS.md,
// and a dependency — for an invited beta whose users are in a chat window with
// the people who wrote this. One line in the log the app already writes, plus
// an offer to copy it on the next launch, is the whole of what is needed until
// the inbox proves otherwise.
//
// What it records is deliberately thin: the kind of death, and the stack. No
// session ids (timestamps are a record of when somebody was working), no
// paths, no transcript. The same rule `Diagnostics` documents at length.
// ─────────────────────────────────────────────────────────────────────────────

enum CrashReport {

    private static let markerPath = Paths.launchLog + ".crashed"

    /// Did the previous run end badly?
    ///
    /// Read once at startup, and clearing it is the caller's job — the menu
    /// bar decides whether it is worth saying anything about.
    static func previousRunCrashed() -> Bool {
        FileManager.default.fileExists(atPath: markerPath)
    }

    static func clearPreviousRun() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    /// Catch what can be caught, and leave a note for the next launch.
    ///
    /// Signal handlers may only call async-signal-safe functions, which
    /// `Emit.event` and `String` interpolation emphatically are not. The
    /// honest options are to write with `write(2)` and nothing else, or to
    /// accept that a handler doing more than that USUALLY works and sometimes
    /// deadlocks instead of reporting. This takes the first: the signal path
    /// writes a fixed byte string to a marker file with raw POSIX calls, and
    /// the readable half is assembled on the NEXT launch, where every API is
    /// legal again.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            // An ObjC exception is not a signal — the process is still in a
            // state where this is safe, and the reason is worth having.
            Emit.event(CrashEvent(
                kind: "exception",
                reason: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                stack: exception.callStackSymbols.prefix(20).joined(separator: " | ")
            ))
            markCrashedFromException()
        }

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
            signal(sig) { received in
                // ASYNC-SIGNAL-SAFE ONLY past this point. No allocation, no
                // Foundation, no Swift runtime that might take a lock the
                // crashing thread already holds.
                markCrashedSignalSafe(received)
                // Restore the default and re-raise, so the process still dies
                // the way it was going to and macOS still writes its own .ips.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

}

/// A free function, not a static: `NSSetUncaughtExceptionHandler` takes a bare
/// C function pointer, and referencing anything through `Self` inside that
/// closure counts as capturing context and will not compile.
private func markCrashedFromException() {
    FileManager.default.createFile(
        atPath: Paths.launchLog + ".crashed", contents: Data("1".utf8))
}

/// Written from a signal handler, so it may touch nothing but POSIX.
///
/// The path is built once, at load, into a C string that already exists by the
/// time a signal can arrive — computing it inside the handler would allocate.
private let crashMarkerCPath: [CChar] = {
    let path = Paths.launchLog + ".crashed"
    return path.cString(using: .utf8) ?? []
}()

private func markCrashedSignalSafe(_ sig: Int32) {
    guard !crashMarkerCPath.isEmpty else { return }
    let fd = crashMarkerCPath.withUnsafeBufferPointer {
        open($0.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    }
    guard fd >= 0 else { return }
    // One digit, no formatting: which signal, as a single byte.
    var byte = UInt8(48 + min(9, Int(sig % 10)))
    _ = write(fd, &byte, 1)
    close(fd)
}

/// One line in the launch log. Same shape as every other event: a type, and
/// nothing that identifies the person or their work.
private struct CrashEvent: Encodable {
    let type = "crash"
    let kind: String
    let reason: String
    let stack: String
}
