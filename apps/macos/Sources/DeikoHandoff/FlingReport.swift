import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ONE RECORD PER FLING, WITH AN OUTCOME YOU CAN GREP FOR
//
// Everything a fling knew used to be prose: 22 `note(...)` lines through
// `Handoff.trace` into the log, narrating each step. Good for reading a failure
// once you already suspect one — and useless for the question actually asked in
// the field, which is "how often does this work, and when it doesn't, why".
//
// Worse, the failing case was the quiet one. A refusal throws a `HandoffError`
// that becomes a sentence in the orb and is then dropped; no terminal line was
// ever written, so a log could end mid-narration with nothing saying how it
// came out. A fling that was never armed, or cancelled over empty space, said
// nothing at all.
//
// This lives in the library rather than beside `Handoff` because the executable
// target cannot be linked into a test binary — the same reason `SessionClaims`
// is here, and the same payoff: the two functions worth guaranteeing are pure.
// ─────────────────────────────────────────────────────────────────────────────

public struct FlingReport: Codable, Sendable, Equatable {

    public enum Outcome: String, Codable, Sendable {
        /// The prompt reached the target and Cmd+V was posted.
        case delivered
        /// Deiko stopped on purpose — focus was unverifiable, the target moved,
        /// or it could not be brought forward. Nothing was sent.
        case refused
        /// Released over nothing sendable.
        case cancelled
        /// Pressed while there was nothing to throw.
        case notArmed = "not-armed"
    }

    public var outcome: Outcome
    public var appName: String?
    public var pid: Int32?
    public var bundleID: String?
    /// Whether THIS fling issued the AXManualAccessibility poke, or found the
    /// process already poked. The distinction is what tells a slow Electron
    /// tree apart from a stale poke record — they look identical otherwise.
    public var pokeIssued: Bool
    /// How long the target's accessibility tree took to answer, in ms. Nil
    /// means it never did within the deadline and the fling proceeded blind.
    public var treeAnsweredMs: Double?
    public var focusBefore: String?
    public var focusAfter: String?
    public var elapsedMs: Double
    /// A short slug — `no-focus`, `moved`, `focus-elsewhere` — never the
    /// user-facing sentence. See `diagnosticLine`.
    public var reason: String?

    public init(
        outcome: Outcome,
        appName: String? = nil,
        pid: Int32? = nil,
        bundleID: String? = nil,
        pokeIssued: Bool = false,
        treeAnsweredMs: Double? = nil,
        focusBefore: String? = nil,
        focusAfter: String? = nil,
        elapsedMs: Double = 0,
        reason: String? = nil
    ) {
        self.outcome = outcome
        self.appName = appName
        self.pid = pid
        self.bundleID = bundleID
        self.pokeIssued = pokeIssued
        self.treeAnsweredMs = treeAnsweredMs
        self.focusBefore = focusBefore
        self.focusAfter = focusAfter
        self.elapsedMs = elapsedMs
        self.reason = reason
    }

    /// Is a system-wide focus reading good enough to act on?
    ///
    /// "Belongs to the target", not merely "something is focused". Activation
    /// has already been polled to completion by the time this is asked, so a
    /// focused element owned by another app means the read is stale — and a
    /// bare non-nil check would accept exactly that and click anyway.
    public static func treeIsReady(focusedPid: pid_t, targetPid: pid_t) -> Bool {
        focusedPid != 0 && focusedPid == targetPid
    }

    /// The single line `Diagnostics.report()` prints.
    ///
    /// CARRIES A SLUG, NEVER THE SENTENCE, and that is the whole reason this is
    /// a function rather than string interpolation at the call site. A refusal's
    /// message names the session's `prompt.txt` so the developer can find their
    /// work — and the diagnostics block is pasted into group chats. Session ids
    /// are timestamps, and a timestamp is a record of when somebody was working.
    /// Same rule this file's neighbour `SessionClaims` is built around.
    public var diagnosticLine: String {
        var parts: [String] = [outcome.rawValue]
        if let appName { parts.append("→ \(appName)") }
        if let bundleID { parts.append("(\(bundleID))") }
        if let reason { parts.append("· \(reason)") }
        parts.append(treeAnsweredMs.map { "· tree \(Int($0))ms" } ?? "· tree silent")
        parts.append("· poke \(pokeIssued ? "issued" : "reused")")
        parts.append("· \(String(format: "%.1f", elapsedMs / 1000))s")
        return parts.joined(separator: " ")
    }
}
