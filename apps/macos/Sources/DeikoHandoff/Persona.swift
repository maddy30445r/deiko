import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PERSONAS — "write it up like this"
//
// A persona is the paragraph a developer would otherwise type at the bottom of
// every brief: who they are, and what shape they want the answer in. It is a
// markdown file on disk (`~/Documents/Deiko/personas/<id>.md`) that travels
// with the brief — read by path where the agent can open files, pasted beside
// it where it cannot.
//
// WHAT A PERSONA IS NOT: it is not a second renderer. `prompt.mjs` is emphatic
// that the pipeline hands over what was said and shown and never writes the
// task — the one hand-written brief that phrased work as imperatives presumed
// work that already existed. A persona asks for a SHAPE; the evidence rule at
// the bottom of every built-in is what keeps that from becoming an invitation
// to invent the contents. Every template ends with it, and `render` appends it
// whether or not the author remembered to.
//
// THE FORM IS THE PRODUCT, not the file. Somebody who writes QA tickets for a
// living should be able to say "P0–P3, Jira markup, no Environment field"
// without reading a prompt, so the options below are the vocabulary of the job
// rather than of the model. `overrideText` is the escape hatch for the person
// who wants the prose itself, and it wins completely when set — a form that
// silently re-shaped somebody's hand-written prompt would be the worst of both.
//
// Pure logic, no file system: `Personas` in the app target owns the folder, the
// seeding and the hand-edit detection. This is the part that can be tested.
// ─────────────────────────────────────────────────────────────────────────────

public struct Persona: Codable, Identifiable, Equatable, Sendable {

    /// The four shapes a brief is asked to take. The base picks the form's
    /// fields and the template; the name is free text, so "QA ticket v2" is
    /// still a `.qaTicket` underneath and keeps its options.
    public enum Base: String, Codable, CaseIterable, Sendable {
        case qaTicket, codeChange, bugReport, analysis

        public var displayName: String {
            switch self {
            case .qaTicket: return "QA ticket"
            case .codeChange: return "Code change"
            case .bugReport: return "Bug report"
            case .analysis: return "Analysis"
            }
        }

        /// One line under the name in the picker — what this shape is FOR,
        /// not what it contains.
        public var purpose: String {
            switch self {
            case .qaTicket: return "for the board: what broke, where, and how to see it"
            case .codeChange: return "for the agent: the change, and nothing around it"
            case .bugReport: return "for whoever fixes it: expected, actual, evidence"
            case .analysis: return "for a decision: what is going on, and the options"
            }
        }

        /// The id a freshly seeded built-in gets. Also the file name.
        public var builtInID: String {
            switch self {
            case .qaTicket: return "qa-ticket"
            case .codeChange: return "code-change"
            case .bugReport: return "bug-report"
            case .analysis: return "analysis"
            }
        }
    }

    public var id: String
    public var name: String
    public var base: Base
    /// Field id → value. Missing keys fall back to the field's default, so a
    /// persona written by an older build keeps working when a field is added.
    public var options: [String: String]
    /// The whole file, hand-written. When set, the form is ignored entirely.
    public var overrideText: String?

    public init(
        id: String, name: String, base: Base,
        options: [String: String] = [:], overrideText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.base = base
        self.options = options
        self.overrideText = overrideText
    }

    /// The four Deiko ships with, in the order they are offered.
    public static var builtIns: [Persona] {
        Base.allCases.map {
            Persona(id: $0.builtInID, name: $0.displayName, base: $0)
        }
    }

    public var isBuiltIn: Bool { Base.allCases.contains { $0.builtInID == id } }

    /// What this persona reads as on disk.
    public var markdown: String {
        overrideText ?? PersonaTemplate.render(self)
    }

    /// The same instruction, in a few lines, for a chat that cannot open a
    /// file and will not fold a long paste away.
    ///
    /// MEASURED, NOT ASSUMED. The plan for this feature said browsers fold a
    /// long paste into a "pasted text" tile, so the whole file could travel.
    /// Gemini does not: 839, 4,010 and 20,000 characters all went into the
    /// composer as text. A brief is supposed to look like something a person
    /// typed, so what travels to a browser is this — the shape, the house
    /// style and the evidence rule, and none of the markdown scaffolding.
    ///
    /// A hand-written persona has no summary: those are somebody's own words
    /// and truncating them would drop instructions silently, so the whole
    /// thing travels and the length is their call.
    public var summary: String? {
        overrideText == nil ? PersonaTemplate.summarise(self) : nil
    }

    /// The value in force for a field: what was set, else the field's default.
    public func value(_ fieldID: String) -> String {
        if let set = options[fieldID] { return set }
        return PersonaForm.fields(for: base).first { $0.id == fieldID }?.defaultValue ?? ""
    }

    public func isOn(_ fieldID: String) -> Bool { value(fieldID) == "1" }
}

// ── The form ────────────────────────────────────────────────────────────────

/// The options a persona exposes, in the language of the job rather than of
/// the prompt. Rendered as a form in Settings; consumed by `PersonaTemplate`.
public enum PersonaForm {

    public struct Choice: Equatable, Sendable {
        public let value: String
        public let label: String
        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// "1" or "0".
            case toggle
            case choice([Choice])
            /// One short line — a team name, a repo convention.
            case text(placeholder: String)
        }

        public let id: String
        public let label: String
        /// The sentence under a control, where one earns its place. Never a
        /// restatement of the label.
        public let help: String?
        public let kind: Kind
        public let defaultValue: String

        public init(
            id: String, label: String, help: String? = nil,
            kind: Kind, defaultValue: String
        ) {
            self.id = id
            self.label = label
            self.help = help
            self.kind = kind
            self.defaultValue = defaultValue
        }
    }

    /// A group of fields under one heading — the form is long enough that a
    /// flat list of fourteen controls would be a wall.
    public struct Group: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let fields: [Field]
    }

    // The sections everything shares. Language is deliberately NOT a list of
    // languages: `prompt.mjs` already asks for a reply language from the
    // narration setting, and a second, contradictory answer here is how a
    // Hinglish brief comes back in a language nobody picked.
    private static var voice: Group {
        Group(id: "voice", title: "Voice", fields: [
            Field(
                id: "tone", label: "Tone",
                kind: .choice([
                    Choice("plain", "Plain"),
                    Choice("formal", "Formal"),
                    Choice("terse", "Terse"),
                ]),
                defaultValue: "plain"
            ),
            Field(
                id: "length", label: "Length",
                help: "How much the write-up may add around what you said.",
                kind: .choice([
                    Choice("short", "Short"),
                    Choice("standard", "Standard"),
                    Choice("detailed", "Detailed"),
                ]),
                defaultValue: "standard"
            ),
            Field(
                id: "audience", label: "Written for",
                help: "Named in the brief, so the level lands right. Optional.",
                kind: .text(placeholder: "my team, a client, whoever picks this up"),
                defaultValue: ""
            ),
        ])
    }

    public static func groups(for base: Persona.Base) -> [Group] {
        switch base {
        case .qaTicket:
            return [
                Group(id: "fields", title: "Sections to include", fields: [
                    sectionField("f_title", "Title", on: true),
                    sectionField("f_where", "Where", on: true),
                    sectionField("f_steps", "Steps to see it", on: true),
                    sectionField("f_seen", "What I saw", on: true),
                    sectionField("f_want", "What I want", on: true),
                    sectionField("f_severity", "Severity", on: true),
                    sectionField("f_environment", "Environment", on: false),
                ]),
                Group(id: "house", title: "House style", fields: [severity, tracker]),
                voice,
            ]
        case .bugReport:
            return [
                Group(id: "fields", title: "Sections to include", fields: [
                    sectionField("f_title", "Title", on: true),
                    sectionField("f_expected", "Expected", on: true),
                    sectionField("f_actual", "Actual", on: true),
                    sectionField("f_where", "Where", on: true),
                    sectionField("f_repro", "How to reproduce", on: true),
                    sectionField("f_severity", "Severity", on: true),
                    sectionField("f_environment", "Environment", on: false),
                ]),
                Group(id: "house", title: "House style", fields: [severity, tracker]),
                voice,
            ]
        case .codeChange:
            return [
                Group(id: "how", title: "How to work", fields: [
                    Field(
                        id: "scope", label: "Scope",
                        kind: .choice([
                            Choice("smallest", "The smallest change that does it"),
                            Choice("refactor", "Refactor around it if that is cleaner"),
                        ]),
                        defaultValue: "smallest"
                    ),
                    Field(
                        id: "untouched", label: "Leave everything else alone",
                        help: "Nothing I did not point at gets edited.",
                        kind: .toggle, defaultValue: "1"
                    ),
                    Field(
                        id: "tests", label: "Update the tests too",
                        kind: .toggle, defaultValue: "0"
                    ),
                    Field(
                        id: "explain", label: "Say what changed, in a line",
                        kind: .toggle, defaultValue: "1"
                    ),
                ]),
                voice,
            ]
        case .analysis:
            return [
                Group(id: "how", title: "How to answer", fields: [
                    Field(
                        id: "depth", label: "Depth",
                        kind: .choice([
                            Choice("quick", "A quick read"),
                            Choice("thorough", "Go through it properly"),
                        ]),
                        defaultValue: "quick"
                    ),
                    Field(
                        id: "tradeoffs", label: "Give me options with trade-offs",
                        kind: .toggle, defaultValue: "1"
                    ),
                    Field(
                        id: "wait", label: "Change nothing until I say",
                        help: "The answer is the deliverable, not a patch.",
                        kind: .toggle, defaultValue: "1"
                    ),
                ]),
                voice,
            ]
        }
    }

    public static func fields(for base: Persona.Base) -> [Field] {
        groups(for: base).flatMap(\.fields)
    }

    private static func sectionField(_ id: String, _ label: String, on: Bool) -> Field {
        Field(id: id, label: label, kind: .toggle, defaultValue: on ? "1" : "0")
    }

    private static var severity: Field {
        Field(
            id: "severity_scale", label: "Severity scale",
            kind: .choice([
                Choice("words", "Low · Medium · High"),
                Choice("p", "P0 – P3"),
                Choice("blocker", "Blocker · Major · Minor"),
            ]),
            defaultValue: "words"
        )
    }

    private static var tracker: Field {
        Field(
            id: "tracker", label: "Formatted for",
            help: "Only changes the markup, never what the ticket says.",
            kind: .choice([
                Choice("plain", "Plain markdown"),
                Choice("jira", "Jira"),
                Choice("linear", "Linear"),
                Choice("github", "GitHub issue"),
            ]),
            defaultValue: "plain"
        )
    }
}

// ── The file a persona becomes ──────────────────────────────────────────────

/// Renders a persona's options into the markdown that ships beside the brief.
///
/// THE LAST SECTION IS NOT OPTIONAL. Every persona ends with the same evidence
/// rule, appended here rather than written into each template, because it is
/// the one thing that keeps a persona an instruction about SHAPE. `prompt.mjs`
/// hands over what was said and shown and never writes the task; a QA ticket
/// with invented reproduction steps would undo that from the other end, and a
/// rule the author has to remember is a rule that goes missing.
public enum PersonaTemplate {

    /// The browser form: one instruction, the format as a single line, and
    /// the evidence rule. Built from the same options as `render`, so a
    /// persona cannot say one thing to Claude Code and another to a chat.
    public static func summarise(_ p: Persona) -> String {
        var out = [opening(p)]
        let shape = self.shape(p)
            .map { $0.replacingOccurrences(of: "- ", with: "")
                     .replacingOccurrences(of: "**", with: "") }
        if !shape.isEmpty {
            out.append(p.base == .qaTicket || p.base == .bugReport
                ? "Sections: " + shape.joined(separator: "; ")
                : shape.joined(separator: " "))
        }
        out.append("Use only what I said and what the screenshots show — if something cannot be filled from that, write \"not stated\" rather than guessing.")
        return out.joined(separator: "\n\n")
    }

    public static func render(_ p: Persona) -> String {
        if let text = p.overrideText { return text }

        var out = ["# \(p.name)", ""]
        out.append(opening(p))
        out.append("")
        out.append("## How to write it")
        out.append("")
        out += shape(p)
        out.append("")
        out.append("## Rules")
        out.append("")
        out += rules(p)
        return out.joined(separator: "\n") + "\n"
    }

    /// First person, because that is who the brief is from. A persona that
    /// addresses the agent in the third person ("the user wants…") reads as a
    /// system prompt, and the whole point is that this is the paragraph the
    /// developer would have typed themselves.
    static func opening(_ p: Persona) -> String {
        var line: String
        switch p.base {
        case .qaTicket:
            line = "Take what I said and what I pointed at, and write it up as a QA ticket."
        case .codeChange:
            line = "Take what I said and what I pointed at, and make the change."
        case .bugReport:
            line = "Take what I said and what I pointed at, and write it up as a bug report."
        case .analysis:
            line = "Take what I said and what I pointed at, and tell me what is going on."
        }
        let audience = p.value("audience").trimmingCharacters(in: .whitespaces)
        if !audience.isEmpty { line += " It is for \(audience)." }
        switch p.value("tone") {
        case "formal": line += " Keep it formal."
        case "terse": line += " Keep it short and flat — no throat-clearing."
        default: line += " Plain words, the way I said it."
        }
        switch p.value("length") {
        case "short": line += " Shorter than you think it needs to be."
        case "detailed": line += " Spell it out; I would rather read a paragraph than guess."
        default: break
        }
        return line
    }

    static func shape(_ p: Persona) -> [String] {
        switch p.base {
        case .qaTicket, .bugReport:
            let labels: [(String, String)] = p.base == .qaTicket
                ? [("f_title", "**Title** — one line, what is wrong"),
                   ("f_where", "**Where** — the screen, file or element I pointed at"),
                   ("f_steps", "**Steps** — what I did, in the order I did it"),
                   ("f_seen", "**What I saw** — the behaviour I am complaining about"),
                   ("f_want", "**What I want** — the behaviour I expect instead"),
                   ("f_severity", "**Severity** — \(severityWords(p))"),
                   ("f_environment", "**Environment** — only what the screenshots actually show")]
                : [("f_title", "**Title** — one line, what is broken"),
                   ("f_expected", "**Expected** — what should happen"),
                   ("f_actual", "**Actual** — what happens instead"),
                   ("f_where", "**Where** — the screen, file or element I pointed at"),
                   ("f_repro", "**How to reproduce** — the steps I described"),
                   ("f_severity", "**Severity** — \(severityWords(p))"),
                   ("f_environment", "**Environment** — only what the screenshots actually show")]
            var lines = labels.filter { p.isOn($0.0) }.map { "- \($0.1)" }
            switch p.value("tracker") {
            case "jira": lines.append("- Use Jira wiki markup: `h3.` headings, `*bold*`, `{code}` blocks.")
            case "linear": lines.append("- Plain markdown, Linear-flavoured: a `##` title line, then the body.")
            case "github": lines.append("- A GitHub issue: markdown headings, a task list if there are several parts.")
            default: lines.append("- Plain markdown, no ticket-system markup.")
            }
            return lines
        case .codeChange:
            var lines = [
                p.value("scope") == "refactor"
                    ? "- Make the change, and tidy what is genuinely in the way while you are there."
                    : "- The smallest change that does it. No drive-by edits.",
            ]
            if p.isOn("untouched") { lines.append("- Do not touch anything I did not point at.") }
            if p.isOn("tests") { lines.append("- Update the tests that cover it, in the same pass.") }
            if p.isOn("explain") { lines.append("- End with one line saying what changed and why.") }
            return lines
        case .analysis:
            var lines = [
                p.value("depth") == "thorough"
                    ? "- Go through it properly: read the surrounding code before answering."
                    : "- A quick read is enough — first impressions, clearly labelled as such.",
            ]
            if p.isOn("tradeoffs") { lines.append("- Give me the options, with what each one costs.") }
            if p.isOn("wait") { lines.append("- Change nothing until I say so. The answer is the deliverable.") }
            return lines
        }
    }

    private static func severityWords(_ p: Persona) -> String {
        switch p.value("severity_scale") {
        case "p": return "P0, P1, P2 or P3"
        case "blocker": return "Blocker, Major or Minor"
        default: return "Low, Medium or High"
        }
    }

    /// The floor. Same words for every persona, including a hand-written one
    /// that forgot them — see the type's comment.
    private static func rules(_ p: Persona) -> [String] {
        [
            "- Use only what I said and what the screenshots show. This is evidence, not a starting point for guesses.",
            "- If a section cannot be filled from that, write \"not stated\" and move on. Do not invent steps, versions or severities.",
            "- Quote text off the screenshots exactly as it appears.",
            "- The brief is what I am asking for; the screenshots are what I was looking at.",
        ]
    }
}
