import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PERSONAS — "write it up like this"
//
// A persona is the paragraph a developer would otherwise type at the bottom of
// every brief: who they are, and what shape they want the answer in. It is a
// markdown file on disk (`<board>/personas/<id>.md`) that travels
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

    /// The three shapes a brief is asked to take. The base picks the form's
    /// fields and the template; the name is free text, so "QA ticket v2" is
    /// still a `.qaTicket` underneath and keeps its options.
    ///
    /// THERE WAS A FOURTH. "Bug report" was the same artefact as a QA ticket in
    /// a second vocabulary — Expected/Actual where the other said Want/Saw —
    /// and two built-ins that produce the same document is a choice nobody can
    /// make well. It is gone; `init(from:)` below is what keeps that from
    /// costing anybody their personas.
    public enum Base: String, Codable, CaseIterable, Sendable {
        case qaTicket, codeChange, analysis

        /// A value this build does not know becomes a QA ticket.
        ///
        /// NOT A NICETY. `Personas.stored()` decodes the whole list with
        /// `try?` and falls back to the built-ins when ANY element fails, so a
        /// leftover `"bugReport"` would have silently deleted every persona
        /// somebody had written. Decoding leniently costs six lines; the
        /// alternative costs somebody their work.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Base(rawValue: raw) ?? .qaTicket
        }

        public var displayName: String {
            switch self {
            case .qaTicket: return "QA ticket"
            case .codeChange: return "Code change"
            case .analysis: return "Analysis"
            }
        }

        /// One line under the name in the picker — what this shape is FOR,
        /// not what it contains.
        public var purpose: String {
            switch self {
            case .qaTicket: return "for the board: what broke, where, and how to see it"
            case .codeChange: return "for the agent: the change, and nothing around it"
            case .analysis: return "for a decision: what is going on, and the options"
            }
        }

        /// The id a freshly seeded built-in gets. Also the file name.
        public var builtInID: String {
            switch self {
            case .qaTicket: return "qa-ticket"
            case .codeChange: return "code-change"
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

    /// The three Deiko ships with, in the order they are offered.
    public static var builtIns: [Persona] {
        Base.allCases.map {
            Persona(id: $0.builtInID, name: $0.displayName, base: $0)
        }
    }

    public var isBuiltIn: Bool { Base.allCases.contains { $0.builtInID == id } }

    /// What this persona reads as on disk.
    public func markdown(connected: Set<Tracker> = []) -> String {
        overrideText ?? PersonaTemplate.render(self, connected: connected)
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
    public func summary(connected: Set<Tracker> = []) -> String? {
        overrideText == nil ? PersonaTemplate.summarise(self, connected: connected) : nil
    }

    /// The value in force for a field: what was set, else the field's default.
    public func value(_ fieldID: String) -> String {
        if let set = options[fieldID] { return set }
        return PersonaForm.fields(for: base).first { $0.id == fieldID }?.defaultValue ?? ""
    }

    public func isOn(_ fieldID: String) -> Bool { value(fieldID) == "1" }

    /// Whether a field's conditions are met — see `Field.onlyWhen`.
    public func shows(_ field: PersonaForm.Field) -> Bool {
        field.onlyWhen.allSatisfy { value($0.key) == $0.value }
    }

    /// The destination this persona files to, or nil for the chat.
    ///
    /// Checked against what the base ALLOWS, not just what is stored: a QA
    /// ticket duplicated into an analysis keeps `tracker = "github"` in its
    /// options, and an analysis has no business filing a GitHub issue.
    public var destination: Tracker? {
        guard let t = Tracker(rawValue: value("tracker")),
              Tracker.allowed(for: base).contains(t) else { return nil }
        return t
    }
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
            /// Several lines, in the author's own words, carried into the
            /// prompt exactly as typed.
            case paragraph(placeholder: String)
        }

        public let id: String
        public let label: String
        /// The sentence under a control, where one earns its place. Never a
        /// restatement of the label.
        public let help: String?
        public let kind: Kind
        public let defaultValue: String
        /// Other fields' values this one waits for — `["tracker": "jira"]`
        /// means "only when the destination is Jira". Empty means always.
        ///
        /// The form keeps every field's VALUE regardless: hiding a control is
        /// a question about the screen, not about storage, so switching from
        /// Jira to Linear and back finds the project key still there.
        public let onlyWhen: [String: String]

        public init(
            id: String, label: String, help: String? = nil,
            kind: Kind, defaultValue: String, onlyWhen: [String: String] = [:]
        ) {
            self.id = id
            self.label = label
            self.help = help
            self.kind = kind
            self.defaultValue = defaultValue
            self.onlyWhen = onlyWhen
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
                Group(id: "house", title: "House style", fields: [severity]),
                destination(for: .qaTicket),
                voice,
                notesGroup,
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
                notesGroup,
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
                    Field(
                        id: "shape_of_answer", label: "Write it as",
                        kind: .choice([
                            Choice("summary", "A plain summary"),
                            Choice("table", "A comparison table"),
                            Choice("decision", "A decision record — what was decided, and why"),
                        ]),
                        defaultValue: "summary"
                    ),
                ]),
                destination(for: .analysis),
                voice,
                notesGroup,
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

    /// WHERE THE WRITE-UP GOES, which used to be only how it was FORMATTED.
    ///
    /// The id is still `tracker`, so a persona saved by the previous build
    /// keeps its answer: the values `plain`, `jira`, `linear` and `github`
    /// meant the same places then as they do now.
    private static func destination(for base: Persona.Base) -> Group {
        let places = Tracker.allowed(for: base)
        let field = Field(
            id: "tracker", label: "Files to",
            help: "If your agent has the tool, it files it there; otherwise it writes it in the chat.",
            kind: .choice([Choice("plain", "Chat only")] + places.map { Choice($0.rawValue, $0.artefact) }),
            defaultValue: "plain"
        )
        return Group(id: "destination", title: "Where it goes", fields: [field] + places.map(detail))
    }

    /// The one thing a tracker needs to know beyond "file it": which board.
    /// Each waits on its own destination being chosen.
    private static func detail(_ t: Tracker) -> Field {
        switch t {
        case .jira:
            return Field(id: "jira_project", label: "Project key",
                         kind: .text(placeholder: "ABC"), defaultValue: "",
                         onlyWhen: ["tracker": t.rawValue])
        case .confluence:
            return Field(id: "confluence_space", label: "Space",
                         kind: .text(placeholder: "Engineering"), defaultValue: "",
                         onlyWhen: ["tracker": t.rawValue])
        case .linear:
            return Field(id: "linear_team", label: "Team",
                         kind: .text(placeholder: "Platform"), defaultValue: "",
                         onlyWhen: ["tracker": t.rawValue])
        case .github:
            return Field(id: "github_repo", label: "Repository",
                         kind: .text(placeholder: "owner/repo"), defaultValue: "",
                         onlyWhen: ["tracker": t.rawValue])
        case .notion:
            return Field(id: "notion_parent", label: "Database or page",
                         kind: .text(placeholder: "Bugs"), defaultValue: "",
                         onlyWhen: ["tracker": t.rawValue])
        }
    }

    /// The escape hatch that is not an escape: everything the form cannot ask
    /// for, in the author's own words, carried through untouched.
    private static var notesGroup: Group {
        Group(id: "notes", title: "In your own words", fields: [
            Field(
                id: "notes", label: "In your own words",
                help: "Anything the form cannot say. It goes into the prompt exactly as written.",
                kind: .paragraph(placeholder: "e.g. always link the design file; never touch the billing service"),
                defaultValue: ""
            ),
        ])
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
    public static func summarise(_ p: Persona, connected: Set<Tracker> = []) -> String {
        var out = [opening(p)]
        let shape = self.shape(p)
            .map { $0.replacingOccurrences(of: "- ", with: "")
                     .replacingOccurrences(of: "**", with: "") }
        if !shape.isEmpty {
            out.append(p.base == .qaTicket
                ? "Sections: " + shape.joined(separator: "; ")
                : shape.joined(separator: " "))
        }
        if let where_ = whereItGoes(p, connected: connected) { out.append(where_) }
        out.append("Use only what I said and what the screenshots show — if something cannot be filled from that, write \"not stated\" rather than guessing.")
        if let notes = notes(p) { out.append(notes) }
        return out.joined(separator: "\n\n")
    }

    /// `connected` is PASSED IN, never read from disk here.
    ///
    /// What the file says depends on what this Mac can reach — if Jira is
    /// already set up, telling somebody how to set it up is noise. But a
    /// renderer that went and looked would be untestable, would do I/O on the
    /// path that writes a brief, and would make the file's digest depend on
    /// the weather. So the caller looks, and this stays a function of its
    /// arguments.
    public static func render(_ p: Persona, connected: Set<Tracker> = []) -> String {
        if let text = p.overrideText { return text }

        var out = ["# \(p.name)", ""]
        out.append(opening(p))
        out.append("")
        out.append("## How to write it")
        out.append("")
        out += shape(p)
        if let where_ = whereItGoes(p, connected: connected) {
            out.append("")
            out.append("## Where it goes")
            out.append("")
            out.append(where_)
        }
        out.append("")
        out.append("## Rules")
        out.append("")
        out += rules(p)
        if let notes = notes(p) {
            out.append("")
            out.append("## In your own words")
            out.append("")
            out.append(notes)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The filing instruction, in one paragraph, or nil for the chat.
    ///
    /// TWO WORDINGS, AND THE DIFFERENCE IS WHETHER WE NAG. When the tool is
    /// already connected somewhere on this Mac, the sentence is an
    /// instruction. When nothing is connected it becomes conditional — never
    /// "write it in the chat", because a browser chat's connectors are
    /// server-side and invisible from here, and somebody whose Claude.ai has
    /// Atlassian should still get their ticket filed. Either way the file says
    /// nothing about how to set anything up: that belongs in Deiko's own
    /// window, where it can be copied, not in the middle of somebody's brief.
    static func whereItGoes(_ p: Persona, connected: Set<Tracker>) -> String? {
        guard let t = p.destination else { return nil }
        let place = self.place(p, t)
        if connected.contains(t) {
            return "File this as a \(t.artefact)\(place). Create it with your "
                + "\(t.displayName) tools and reply with the key and a link. If you cannot "
                + "reach \(t.displayName), write it here in full instead."
        }
        return "File this as a \(t.artefact)\(place) if you have \(t.displayName) tools; "
            + "otherwise write it here in full, formatted for \(t.displayName). "
            + "Do not ask me to set anything up."
    }

    /// " in project ABC" — or nothing at all, rather than a dangling "in".
    private static func place(_ p: Persona, _ t: Tracker) -> String {
        let detail: String
        switch t {
        case .jira: detail = p.value("jira_project")
        case .confluence: detail = p.value("confluence_space")
        case .linear: detail = p.value("linear_team")
        case .github: detail = p.value("github_repo")
        case .notion: detail = p.value("notion_parent")
        }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        switch t {
        case .jira: return " in project \(trimmed)"
        case .confluence: return " in the \(trimmed) space"
        case .linear: return " in the \(trimmed) team"
        case .github: return " in \(trimmed)"
        case .notion: return " in \(trimmed)"
        }
    }

    /// Whatever the author typed, trimmed at the ends and otherwise untouched —
    /// no reflowing, no markdown stripping. It is their sentence.
    static func notes(_ p: Persona) -> String? {
        let text = p.value("notes").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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
        case .qaTicket:
            let labels: [(String, String)] = [
                ("f_title", "**Title** — one line, what is wrong"),
                ("f_where", "**Where** — the screen, file or element I pointed at"),
                ("f_steps", "**Steps** — what I did, in the order I did it"),
                ("f_seen", "**What I saw** — the behaviour I am complaining about"),
                ("f_want", "**What I want** — the behaviour I expect instead"),
                ("f_severity", "**Severity** — \(severityWords(p))"),
                ("f_environment", "**Environment** — only what the screenshots actually show"),
            ]
            var lines = labels.filter { p.isOn($0.0) }.map { "- \($0.1)" }
            // The markup still matters when nothing files it: this is what the
            // ticket looks like pasted into the chat.
            switch p.destination {
            case .jira: lines.append("- Use Jira wiki markup: `h3.` headings, `*bold*`, `{code}` blocks.")
            case .linear: lines.append("- Plain markdown, Linear-flavoured: a `##` title line, then the body.")
            case .github: lines.append("- A GitHub issue: markdown headings, a task list if there are several parts.")
            case .notion, .confluence: lines.append("- Plain markdown; the page keeps the headings and lists.")
            case nil: lines.append("- Plain markdown, no ticket-system markup.")
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
            switch p.value("shape_of_answer") {
            case "table": lines.append("- Lay the comparison out as a table, one row per option.")
            case "decision": lines.append("- Write it as a decision record: what was decided, what it rules out, and why.")
            default: break
            }
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
