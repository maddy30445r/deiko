import Foundation

/// Records that the previous run died, so the next launch can say so.
///
/// Deliberately not a crash SDK: it writes a marker file and one line to the launch log. It records
/// only the kind of death and the stack (no session ids, paths or transcript), as in `Diagnostics`.
enum CrashReport {

    private static let markerPath = Paths.launchLog + ".crashed"

    /// Whether the previous run ended badly. Read once at startup; clearing it is the caller's job.
    static func previousRunCrashed() -> Bool {
        FileManager.default.fileExists(atPath: markerPath)
    }

    static func clearPreviousRun() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    /// Catch what can be caught, and leave a note for the next launch.
    ///
    /// Signal handlers may only call async-signal-safe functions, which `Emit.event` and string
    /// interpolation are not. The signal path therefore writes a fixed byte to a marker file with raw
    /// POSIX calls, and the readable report is assembled on the next launch.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            // An ObjC exception is not a signal, so the process is still in a state where this is safe.
            Emit.event(CrashEvent(
                kind: "exception",
                reason: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                stack: exception.callStackSymbols.prefix(20).joined(separator: " | ")
            ))
            markCrashedFromException()
        }

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
            signal(sig) { received in
                // Async-signal-safe calls only past this point: no allocation, no Foundation, no
                // Swift runtime that might take a lock the crashing thread holds.
                markCrashedSignalSafe(received)
                // Restore the default and re-raise, so the process still dies as it would have
                // and macOS still writes its own .ips.
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
