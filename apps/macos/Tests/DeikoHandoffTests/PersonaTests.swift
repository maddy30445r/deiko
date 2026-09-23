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
        let text = persona.markdown()
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
    #expect(p.markdown() == "# Mine\n\nJust do what I say.\n")
}

// ── The form reaches the page ───────────────────────────────────────────────

@Test("turning a section off removes it, and leaves the others alone")
func sectionsFollowTheirToggles() {
    let on = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(on.markdown().contains("**Steps**"))

    var off = on
    off.options["f_steps"] = "0"
    #expect(!off.markdown().contains("**Steps**"))
    #expect(off.markdown().contains("**Title**"))
    #expect(off.markdown().contains(evidence))
}

@Test("a section that is off by default appears once it is asked for")
func defaultsOffStayOff() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(!p.markdown().contains("**Environment**"))
    p.options["f_environment"] = "1"
    #expect(p.markdown().contains("**Environment**"))
}

@Test("the severity scale is the team's, not ours")
func severityScaleIsHouseStyle() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(p.markdown().contains("Low, Medium or High"))
    p.options["severity_scale"] = "p"
    #expect(p.markdown().contains("P0, P1, P2 or P3"))
    #expect(!p.markdown().contains("Low, Medium or High"))
}

@Test("a destination adds where it goes, and leaves the sections alone")
func destinationAddsASection() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    let plain = p.markdown()
    #expect(!plain.contains("## Where it goes"))
    p.options["tracker"] = "jira"
    let jira = p.markdown()
    #expect(jira.contains("## Where it goes"))
    #expect(jira.contains("Jira wiki markup"))       // the in-chat fallback still formats
    // Same sections, same rules — the destination is additive.
    let sections = { (t: String) in t.components(separatedBy: "\n").filter { $0.hasPrefix("- **") } }
    #expect(sections(plain) == sections(jira))
}

@Test("code-change toggles add their line and only their line")
func codeChangeToggles() {
    var p = Persona(id: "code-change", name: "Code change", base: .codeChange)
    #expect(p.markdown().contains("smallest change"))
    #expect(!p.markdown().contains("Update the tests"))
    p.options["tests"] = "1"
    p.options["scope"] = "refactor"
    #expect(p.markdown().contains("Update the tests"))
    #expect(p.markdown().contains("tidy what is genuinely in the way"))
    #expect(!p.markdown().contains("smallest change"))
}

@Test("who it is for, and the tone, reach the opening line")
func voiceReachesTheOpening() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    p.options["audience"] = "the QA board"
    p.options["tone"] = "terse"
    let text = p.markdown()
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
    #expect(copy.markdown().contains("# QA ticket v2"))
    #expect(copy.markdown().contains(evidence))
}

@Test("a persona survives a round trip through its stored form")
func codableRoundTrip() throws {
    var p = Persona(id: "qa-ticket-v2", name: "QA ticket v2", base: .qaTicket)
    p.options["tracker"] = "linear"
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Persona.self, from: data)
    #expect(back == p)
    #expect(back.markdown() == p.markdown())
}

// ── What a browser chat gets ────────────────────────────────────────────────
//
// Measured, not assumed: Gemini pastes 839, 4,010 and 20,000 characters into
// the composer as text and never folds any of them into a tile. So the browser
// form has to be short by construction, and it still has to carry the rule
// that keeps a persona an instruction about shape.

@Test("the browser form is short, and still says use only what was said")
func browserFormIsShortAndHonest() {
    for persona in Persona.builtIns {
        let summary = try! #require(persona.summary())
        #expect(summary.count < 700, "\(persona.id) summary is \(summary.count) characters")
        #expect(summary.count < persona.markdown().count)
        #expect(summary.contains("not stated"))
        #expect(summary.contains("only what I said"))
        // No markdown scaffolding: it is pasted into a chat, not a file.
        #expect(!summary.contains("##"))
        #expect(!summary.contains("- **"))
    }
}

@Test("the browser form carries the house style, not just the shape")
func browserFormCarriesOptions() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    p.options["severity_scale"] = "p"
    p.options["tone"] = "terse"
    let summary = try! #require(p.summary())
    #expect(summary.contains("P0, P1, P2 or P3"))
    #expect(summary.contains("short and flat"))
}

@Test("a hand-written persona has no short form — its words travel whole")
func handWrittenHasNoSummary() {
    var p = Persona(id: "qa-ticket-v2", name: "QA ticket v2", base: .qaTicket)
    p.overrideText = "# Mine\n\nDo it my way, and here is the long version of why.\n"
    // Truncating somebody's own prompt would drop instructions silently; the
    // length of a hand-written persona is its author's call.
    #expect(p.summary() == nil)
}

// ── Where it goes ───────────────────────────────────────────────────────────
//
// The wording turns on one thing: whether this Mac can already reach the tool.
// Connected, it is an instruction. Not connected, it is conditional — never a
// flat "write it in the chat", because a browser chat's connectors are
// server-side and invisible from here, and somebody whose Claude.ai has
// Atlassian should still get their ticket filed.

private func filing(_ tracker: String, connected: Set<Tracker> = [], detail: (String, String)? = nil) -> String {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    p.options["tracker"] = tracker
    if let detail { p.options[detail.0] = detail.1 }
    return p.markdown(connected: connected)
}

@Test("a connected tool is an instruction, not an offer")
func connectedReadsAsAnInstruction() {
    let text = filing("jira", connected: [.jira])
    #expect(text.contains("Create it with your Jira tools"))
    #expect(text.contains("reply with the key and a link"))
    #expect(!text.contains("if you have Jira tools"))
}

@Test("nothing connected stays quiet about setting anything up")
func notConnectedStaysQuiet() {
    let text = filing("jira")
    #expect(text.contains("if you have Jira tools"))
    #expect(text.contains("Do not ask me to set anything up"))
    // The commands live in Deiko's window, never in somebody's brief.
    #expect(!text.contains("claude mcp add"))
    #expect(!text.contains("mcp.atlassian.com"))
}

@Test("the detail names the board, and a blank one leaves no dangling in")
func detailOrNothing() {
    #expect(filing("jira", detail: ("jira_project", "ABC")).contains("Jira issue in project ABC"))
    #expect(filing("linear", detail: ("linear_team", "Platform")).contains("in the Platform team"))
    let blank = filing("jira")
    #expect(blank.contains("File this as a Jira issue if you have"))
    #expect(!blank.contains(" in ."))
    #expect(!blank.contains("in project ."))
}

@Test("a destination the base does not allow is ignored")
func destinationMustBeAllowed() {
    // A QA ticket duplicated into an analysis keeps `tracker` in its options,
    // and an analysis has no business filing a GitHub issue.
    var p = Persona(id: "analysis", name: "Analysis", base: .analysis)
    p.options["tracker"] = "github"
    #expect(p.destination == nil)
    #expect(!p.markdown().contains("## Where it goes"))

    p.options["tracker"] = "confluence"
    #expect(p.destination == .confluence)
    #expect(p.markdown().contains("Confluence page"))
}

@Test("the browser form carries the destination but never a command")
func browserFormCarriesDestination() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    p.options["tracker"] = "jira"
    p.options["jira_project"] = "ABC"
    let summary = try! #require(p.summary(connected: [.jira]))
    #expect(summary.contains("Jira issue in project ABC"))
    // No setup commands — a browser cannot run one, and its connectors are
    // invisible from here anyway. (Backticks are fine: the Jira markup line
    // has carried them since the form first had a tracker.)
    #expect(!summary.contains("claude mcp add"))
    #expect(!summary.contains("codex mcp add"))
    #expect(!summary.contains("mcp.atlassian.com"))
    #expect(summary.contains("not stated"))
}

// ── In your own words ───────────────────────────────────────────────────────

@Test("notes are carried exactly as typed")
func notesAreVerbatim() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    #expect(!p.markdown().contains("## In your own words"))

    // Two lines, leading and trailing space: trimmed at the ends, untouched in
    // the middle. Nothing is reflowed and no markdown is stripped — it is the
    // author's sentence, not ours.
    p.options["notes"] = "  Never touch billing.\nLink the Figma. "
    let text = p.markdown()
    #expect(text.contains("## In your own words\n\nNever touch billing.\nLink the Figma."))
    #expect(try! #require(p.summary()).contains("Never touch billing.\nLink the Figma."))
}

@Test("every persona can be written in your own words")
func everyBaseHasNotes() {
    for base in Persona.Base.allCases {
        let ids = PersonaForm.fields(for: base).map(\.id)
        #expect(ids.contains("notes"), "\(base) has nowhere to write freely")
    }
}

// ── Conditional fields ──────────────────────────────────────────────────────

@Test("a tracker's detail field appears only for that tracker")
func detailFieldsAreConditional() {
    var p = Persona(id: "qa-ticket", name: "QA ticket", base: .qaTicket)
    let fields = PersonaForm.fields(for: .qaTicket)
    let jiraProject = try! #require(fields.first { $0.id == "jira_project" })
    let linearTeam = try! #require(fields.first { $0.id == "linear_team" })

    p.options["tracker"] = "jira"
    #expect(p.shows(jiraProject))
    #expect(!p.shows(linearTeam))

    // The VALUE survives switching away and back: hiding a control is a
    // question about the screen, not about storage.
    p.options["jira_project"] = "ABC"
    p.options["tracker"] = "linear"
    #expect(!p.shows(jiraProject))
    #expect(p.value("jira_project") == "ABC")
}

// ── The cut base ────────────────────────────────────────────────────────────

@Test("a persona saved as a bug report still decodes, and can be deleted")
func bugReportPersonasSurvive() {
    // The danger this guards: `Personas.stored()` decodes the whole list with
    // `try?` and falls back to the built-ins when ANY element fails, so an
    // unknown base would have silently deleted every persona somebody wrote.
    let json = """
    [{"id":"bug-report","name":"Bug report","base":"bugReport","options":{"f_actual":"1"}},
     {"id":"mine","name":"Mine","base":"qaTicket","options":{}}]
    """
    let list = try! JSONDecoder().decode([Persona].self, from: Data(json.utf8))
    #expect(list.count == 2)
    #expect(list[0].base == .qaTicket)          // read as the surviving shape
    #expect(list[0].name == "Bug report")       // and keeps the name its author saw
    #expect(!list[0].isBuiltIn)                 // so its row offers Delete, not Reset
    #expect(list[1].name == "Mine")             // the custom persona beside it survives
}
