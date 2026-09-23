import Foundation
import Testing
@testable import DeikoHandoff

// A persona is a prompt that ships beside somebody's brief, so these tests are
// about one property above all others: whatever the form says, the rendered
// file still tells the agent to use only what was said and shown. Everything
// else here is about the form actually reaching the page.

private let evidence = "Use only what I said and what the screenshots show"

// ── The floor ───────────────────────────────────────────────────────────────

@Test("every built-in renders, and every one of them carries the evidence rule")
func builtInsCarryTheRule() {
    for persona in Persona.builtIns {
        let text = persona.markdown
        #expect(text.contains("# \(persona.name)"))
        #expect(text.contains(evidence), "\(persona.id) dropped the evidence rule")
        #expect(text.contains("not stated"), "\(persona.id) lost the do-not-guess instruction")
        #expect(text.contains("## How to write it"))
    }
}

@Test("a hand-written persona is used exactly as written, form and all")
func overrideWinsOutright() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket, options: ["f_steps": "0"])
    p.overrideText = "# Mine\n\nJust do what I say.\n"
    // Not "mostly": the whole point of the escape hatch is that nothing is
    // appended, reordered or helpfully corrected behind the author's back.
    #expect(p.markdown == "# Mine\n\nJust do what I say.\n")
}

// ── The form reaches the page ───────────────────────────────────────────────

@Test("turning a section off removes it, and leaves the others alone")
func sectionsFollowTheirToggles() {
    let on = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(on.markdown.contains("**Steps**"))

    var off = on
    off.options["f_steps"] = "0"
    #expect(!off.markdown.contains("**Steps**"))
    #expect(off.markdown.contains("**Title**"))
    #expect(off.markdown.contains(evidence))
}

@Test("a section that is off by default appears once it is asked for")
func defaultsOffStayOff() {
    var p = Persona(id: "bug-report", name: "Bug report", base: .bugReport)
    #expect(!p.markdown.contains("**Environment**"))
    p.options["f_environment"] = "1"
    #expect(p.markdown.contains("**Environment**"))
}

@Test("the severity scale is the team's, not ours")
func severityScaleIsHouseStyle() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(p.markdown.contains("Low, Medium or High"))
    p.options["severity_scale"] = "p"
    #expect(p.markdown.contains("P0, P1, P2 or P3"))
    #expect(!p.markdown.contains("Low, Medium or High"))
}

@Test("the tracker changes the markup and nothing else")
func trackerOnlyChangesMarkup() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    let plain = p.markdown
    p.options["tracker"] = "jira"
    let jira = p.markdown
    #expect(jira.contains("Jira wiki markup"))
    // Same sections, same rules — only the formatting line differs.
    let sections = { (t: String) in t.components(separatedBy: "\n").filter { $0.hasPrefix("- **") } }
    #expect(sections(plain) == sections(jira))
}

@Test("code-change toggles add their line and only their line")
func codeChangeToggles() {
    var p = Persona(id: "code-change", name: "Code change", base: .codeChange)
    #expect(p.markdown.contains("smallest change"))
    #expect(!p.markdown.contains("Update the tests"))
    p.options["tests"] = "1"
    p.options["scope"] = "refactor"
    #expect(p.markdown.contains("Update the tests"))
    #expect(p.markdown.contains("tidy what is genuinely in the way"))
    #expect(!p.markdown.contains("smallest change"))
}

@Test("who it is for, and the tone, reach the opening line")
func voiceReachesTheOpening() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    p.options["audience"] = "the QA board"
    p.options["tone"] = "terse"
    let text = p.markdown
    #expect(text.contains("It is for the QA board."))
    #expect(text.contains("short and flat"))
}

// ── Values and identity ─────────────────────────────────────────────────────

@Test("an option nobody set falls back to the field's own default")
func unsetOptionsFallBack() {
    // A persona stored by an older build has none of a newly added field's
    // keys, and must keep rendering as though it had the defaults.
    let p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket, options: [:])
    #expect(p.value("severity_scale") == "words")
    #expect(p.isOn("f_title"))
    #expect(!p.isOn("f_environment"))
    #expect(p.value("nonexistent-field") == "")
}

@Test("a duplicate is not a built-in, however it was seeded")
func duplicatesAreNotBuiltIn() {
    let original = Persona.builtIns[0]
    #expect(original.isBuiltIn)
    let copy = Persona(id: "qa-ticket-v2", name: "QA ticket v2", base: .qaTicket)
    #expect(!copy.isBuiltIn)
    // and it still renders the full thing, not an empty shell
    #expect(copy.markdown.contains("# QA ticket v2"))
    #expect(copy.markdown.contains(evidence))
}

@Test("a persona survives a round trip through its stored form")
func codableRoundTrip() throws {
    var p = Persona(id: "qa-ticket-v2", name: "QA ticket v2", base: .qaTicket)
    p.options["tracker"] = "linear"
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Persona.self, from: data)
    #expect(back == p)
    #expect(back.markdown == p.markdown)
}
