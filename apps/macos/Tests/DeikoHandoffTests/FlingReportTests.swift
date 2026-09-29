import Testing
import Foundation
@testable import DeikoHandoff

// The two functions on `FlingReport` worth guaranteeing: one decides whether a
// fling proceeds, the other is what a user pastes into a group chat.

@Test("a focused element belonging to the target is what readiness means")
func readyOnlyForTheTarget() {
    #expect(FlingReport.treeIsReady(focusedPid: 500, targetPid: 500))
}

@Test("focus owned by another app is a stale read, not readiness")
func notReadyForSomebodyElse() {
    // A pid comparison rather than `focusedElement() != nil`: activation has
    // already been polled to completion, so focus on a different app means the
    // reading is stale, and a bare non-nil check would accept it.
    #expect(!FlingReport.treeIsReady(focusedPid: 501, targetPid: 500))
}

@Test("pid zero is never ready")
func notReadyForNothing() {
    // `AXUIElementGetPid` leaves the out-param at 0 on failure, so a failed
    // read must not be able to look like a match against an equally absent pid.
    #expect(!FlingReport.treeIsReady(focusedPid: 0, targetPid: 0))
    #expect(!FlingReport.treeIsReady(focusedPid: 0, targetPid: 500))
}

@Test("every outcome names itself first")
func outcomeLeadsTheLine() {
    for outcome in [FlingReport.Outcome.delivered, .refused, .cancelled, .notArmed] {
        let line = FlingReport(outcome: outcome, elapsedMs: 1200).diagnosticLine
        #expect(line.hasPrefix(outcome.rawValue), "\(outcome) should lead its own line")
    }
}

@Test("the line carries no session path and no timestamp")
func linesCarryNothingFromASession() {
    // A refusal's user-facing message names the session's prompt.txt, and this
    // line goes into diagnostics people paste into group chats, where a session
    // id (a timestamp) records when somebody was working.
    let line = FlingReport(
        outcome: .refused,
        appName: "Code",
        pid: 37143,
        bundleID: "com.microsoft.VSCode",
        pokeIssued: true,
        treeAnsweredMs: 1420,
        elapsedMs: 3100,
        reason: "no-focus"
    ).diagnosticLine

    #expect(!line.contains("/"), "a path got into the diagnostics line: \(line)")
    #expect(line.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) == nil,
            "a session id got into the diagnostics line: \(line)")
    #expect(line.contains("no-focus"))
    #expect(line.contains("com.microsoft.VSCode"))
}

@Test("a silent tree is said out loud, not left blank")
func silentTreeIsNamed() {
    // nil means the tree never answered within the deadline and the fling went
    // ahead blind; a blank would hide that.
    let silent = FlingReport(outcome: .refused, treeAnsweredMs: nil, elapsedMs: 2500).diagnosticLine
    #expect(silent.contains("silent"))
    let answered = FlingReport(outcome: .delivered, treeAnsweredMs: 340, elapsedMs: 900).diagnosticLine
    #expect(answered.contains("340ms"))
}

@Test("a reused poke is distinguishable from an issued one")
func pokeProvenanceSurvives() {
    // A slow Electron tree and a stale poke record look identical in the field;
    // this tells them apart.
    #expect(FlingReport(outcome: .delivered, pokeIssued: true, elapsedMs: 1).diagnosticLine.contains("poke issued"))
    #expect(FlingReport(outcome: .delivered, pokeIssued: false, elapsedMs: 1).diagnosticLine.contains("poke reused"))
}
