import Foundation

/// One record per fling, with an outcome that can be grepped for. A refusal
/// throws a `HandoffError` that becomes a sentence in the orb and is then
/// dropped, so every fling, including one never armed or cancelled over empty
/// space, needs a terminal record.
///
/// Lives in the library because the executable target cannot be linked into a
/// test binary; the two functions worth guaranteeing are pure.
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
    /// Whether this fling issued the AXManualAccessibility poke or found the
    /// process already poked. Tells a slow Electron tree apart from a stale
    /// poke record.
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
    /// has already been polled to completion, so a focused element owned by
    /// another app means the read is stale.
    public static func treeIsReady(focusedPid: pid_t, targetPid: pid_t) -> Bool {
        focusedPid != 0 && focusedPid == targetPid
    }

    /// The single line `Diagnostics.report()` prints. Carries a slug, never the
    /// user-facing sentence: a refusal's message names the session's
    /// `prompt.txt`, and diagnostics get pasted into group chats, where a
    /// session id (a timestamp) records when somebody was working. Same rule as
    /// `SessionClaims`.
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
