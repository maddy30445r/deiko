import AppKit
import SwiftUI
import DeikoHandoff

// The Personas settings pane. The form's controls are the vocabulary of the job
// and the persona prose is generated from them. "Overwrite this persona" is the
// escape hatch: it takes over completely, with no form and no merging.

@MainActor
final class PersonaStore: ObservableObject {
    @Published private(set) var list: [Persona] = []
    @Published var defaultID: String = Personas.defaultID
    /// Which agents on this Mac name which trackers. Read off their MCP
    /// configs; empty until the first scan lands.
    @Published private(set) var connected: [Tracker: Set<AgentClient>] = AgentConfigs.connected

    init() { reload() }

    /// Always from `Personas`, which adopts hand-edited files on the way past.
    /// Reading the stored form directly would quietly undo somebody's editing.
    func reload() {
        list = Personas.all()
        defaultID = Personas.defaultID
        // Off the main actor: `~/.claude.json` can be megabytes.
        Task.detached(priority: .utility) {
            let fresh = AgentConfigs.refresh()
            await MainActor.run { self.connected = fresh }
        }
        if !list.contains(where: { $0.id == defaultID }), let first = list.first {
            makeDefault(first)
        }
    }

    func makeDefault(_ persona: Persona) {
        Personas.defaultID = persona.id
        defaultID = persona.id
    }

    func update(_ persona: Persona) {
        guard let index = list.firstIndex(where: { $0.id == persona.id }) else { return }
        list[index] = persona
        Personas.save(list)
        Personas.write(persona)
    }

    func add(base: Persona.Base) {
        let persona = Persona(id: freeID(base.builtInID), name: base.displayName, base: base)
        list.append(persona)
        Personas.save(list)
        Personas.write(persona)
        makeDefault(persona)
    }

    /// A copy for when the built-in is nearly right. It copies the options and
    /// any hand-written text, since those are what is about to change.
    func duplicate(_ persona: Persona) {
        var copy = persona
        copy.id = freeID(persona.id)
        copy.name = nextName(persona.name)
        list.append(copy)
        Personas.save(list)
        Personas.write(copy)
        makeDefault(copy)
    }

    /// Back to the form, and back to ours. The only way out of an override.
    func reset(_ persona: Persona) {
        var fresh = persona
        fresh.overrideText = nil
        fresh.options = [:]
        update(fresh)
    }

    func remove(_ persona: Persona) {
        // A built-in has no delete, only Reset: deleting one would leave a gap
        // that seeding does not refill.
        guard !persona.isBuiltIn else { return }
        list.removeAll { $0.id == persona.id }
        Personas.save(list)
        try? FileManager.default.removeItem(at: Personas.file(for: persona.id))
        if defaultID == persona.id, let first = list.first { makeDefault(first) }
    }

    func reveal(_ persona: Persona) {
        Personas.write(persona)
        NSWorkspace.shared.activateFileViewerSelecting([Personas.file(for: persona.id)])
    }

    func openFolder() {
        let url = URL(fileURLWithPath: Personas.root)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func freeID(_ base: String) -> String {
        var n = 2
        while list.contains(where: { $0.id == "\(base)-v\(n)" }) { n += 1 }
        return "\(base)-v\(n)"
    }

    private func nextName(_ name: String) -> String {
        var n = 2
        let stem = name.replacingOccurrences(of: #"\s+v\d+$"#, with: "", options: .regularExpression)
        while list.contains(where: { $0.name == "\(stem) v\(n)" }) { n += 1 }
        return "\(stem) v\(n)"
    }
}

struct PersonasPane: View {
    @StateObject private var store = PersonaStore()
    @State private var selectedID: String?
    @State private var editing: Persona?

    private var selected: Persona? {
        store.list.first { $0.id == selectedID } ?? store.list.first
    }

    var body: some View {
        PaneScroll(
            title: "Personas",
            lede: "How a brief gets written up once your agent has it.",
            trailing: {
                Menu("New persona…") {
                    ForEach(Persona.Base.allCases, id: \.self) { base in
                        Button("\(base.displayName) — \(base.purpose)") { store.add(base: base) }
                    }
                }
                .frame(width: 140)
            }
        ) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ForEach(store.list) { persona in row(persona) }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                preview
                    .frame(maxWidth: .infinity, alignment: .top)
            }

            connectedTools

            Text("Each persona is a file on this Mac. Edit it here, or open it in your own editor — Deiko uses whatever the file says.")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open personas folder") { store.openFolder() }
                Spacer()
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona, connected: Set(store.connected.keys)) { saved in
                store.update(saved)
                editing = nil
            } onCancel: { editing = nil }
        }
        .onAppear { store.reload() }
    }

    /// The whole row is the hit target.
    private func row(_ persona: Persona) -> some View {
        let isSelected = selected?.id == persona.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(persona.name).deikoTitle(14)
                    if persona.overrideText != nil { tag("Your own text") }
                    if store.defaultID == persona.id { tag("Default") }
                }
                Text(persona.base.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                if let t = persona.destination {
                    // Where it goes, and whether anything here can take it. Neutral
                    // colour: not having connected a tracker is not a failure.
                    Text(filingLine(t))
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                }
            }
            Spacer()
            Menu {
                Button("Edit…") { editing = persona }
                if store.defaultID != persona.id {
                    Button("Use for new briefs") { store.makeDefault(persona) }
                }
                Button("Duplicate") { store.duplicate(persona) }
                Button("Show in Finder") { store.reveal(persona) }
                Divider()
                if persona.isBuiltIn {
                    Button("Reset to Deiko's wording") { store.reset(persona) }
                } else {
                    Button("Delete", role: .destructive) { store.remove(persona) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                // Same selection language as the sidebar: accent wash means
                // "where I am".
                .fill(isSelected ? DeikoStyle.accentSoft : DeikoStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .strokeBorder(isSelected ? DeikoStyle.accent : DeikoStyle.hairline,
                                      lineWidth: 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: isSelected ? 13 : 8, x: 0, y: isSelected ? 7 : 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = persona.id }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The file itself, because that is what ships; a preview that paraphrased
    /// it would be a second thing to keep in sync.
    @ViewBuilder private var preview: some View {
        if let persona = selected {
            VStack(spacing: 0) {
                HStack {
                    Text(persona.overrideText == nil ? "What your agent will be asked" : "Your own wording, as written")
                        .font(.system(size: 12))
                        .foregroundStyle(DeikoStyle.ink2)
                    Spacer()
                    Button("Edit…") { editing = persona }
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(DeikoStyle.paper)
                Divider()
                ScrollView {
                    Text(persona.markdown(connected: Set(store.connected.keys)))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(minHeight: 260, maxHeight: 420)
            }
            .background(DeikoStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: DeikoStyle.insetRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                    .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
            )
            .shadow(color: DeikoStyle.shadow, radius: 13, x: 0, y: 7)
        } else {
            EmptyPane(
                title: "No personas",
                line: "Make one and every brief after it gets written up that way."
            )
        }
    }

    /// The setup nudge lives here rather than in the persona file, so a brief
    /// never advertises a tool, and a command can be copied instead of read
    /// aloud by somebody's own agent.
    private var connectedTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Connected tools")
            InsetCard {
                ForEach(Array(Tracker.allCases.enumerated()), id: \.element) { index, t in
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    HStack(spacing: 10) {
                        Text(t.displayName)
                            .font(.system(size: 13))
                            .frame(width: 92, alignment: .leading)
                        let agents = (store.connected[t] ?? []).map(\.displayName).sorted()
                        if agents.isEmpty {
                            Text("not connected")
                                .font(.system(size: 12))
                                .foregroundStyle(DeikoStyle.ink2)
                            Spacer()
                            Button("Copy setup command") { copySetup(t) }
                                .font(.system(size: 12))
                        } else {
                            Text(agents.joined(separator: ", "))
                                .font(.system(size: 12))
                                .foregroundStyle(DeikoStyle.ink2)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            Text("Read from your agents' MCP configs on this Mac. Browser chats keep their connectors server-side, so those cannot be seen from here — a persona asks for them rather than assuming.")
                .font(.system(size: 11))
                .foregroundStyle(DeikoStyle.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every agent's line at once: Deiko cannot know which one somebody is
    /// about to paste into, and four short lines are cheaper than a guess.
    private func copySetup(_ t: Tracker) {
        let text = t.setup.map { "\($0.agent): \($0.how)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Files to Jira · connected in Claude Code, Codex".
    private func filingLine(_ t: Tracker) -> String {
        let agents = (store.connected[t] ?? []).map(\.displayName).sorted()
        guard !agents.isEmpty else { return "Files to \(t.displayName) · not connected on this Mac" }
        return "Files to \(t.displayName) · connected in " + agents.joined(separator: ", ")
    }

    private func tag(_ word: String) -> some View {
        Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DeikoStyle.mark)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DeikoStyle.accentSoft, in: Capsule())
    }
}

private struct PersonaEditor: View {
    @State private var draft: Persona
    @State private var overwriting: Bool
    @State private var text: String
    /// What this Mac can reach, so the preview and the saved file agree.
    private let connected: Set<Tracker>
    let onSave: (Persona) -> Void
    let onCancel: () -> Void

    init(
        persona: Persona, connected: Set<Tracker>,
        onSave: @escaping (Persona) -> Void, onCancel: @escaping () -> Void
    ) {
        self.connected = connected
        _draft = State(initialValue: persona)
        _overwriting = State(initialValue: persona.overrideText != nil)
        // The form's own rendering, so turning the switch on hands somebody
        // the real thing to edit rather than an empty box.
        _text = State(initialValue: persona.markdown(connected: connected))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(draft.name).deikoTitle(19)
                Spacer()
                Text(draft.base.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeikoStyle.mark)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DeikoStyle.accentSoft, in: Capsule())
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InsetCard {
                        HStack(spacing: 10) {
                            Text("Name").font(.system(size: 13)).frame(width: 90, alignment: .leading)
                            TextField("QA ticket", text: $draft.name).font(.system(size: 13))
                        }
                        .padding(14)
                    }

                    if overwriting {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Your prompt")
                            TextEditor(text: $text)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 260)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .deikoCard()
                            Text("Deiko adds nothing to this. It is handed to the agent exactly as written, under your brief.")
                                .font(.system(size: 11))
                                .foregroundStyle(DeikoStyle.ink2)
                        }
                    } else {
                        ForEach(PersonaForm.groups(for: draft.base)) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(group.title)
                                InsetCard {
                                    // Filter before enumerating, or the dividers
                                    // count fields nobody can see.
                                    let shown = group.fields.filter { draft.shows($0) }
                                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, field in
                                        if index > 0 { Divider().padding(.horizontal, 14) }
                                        control(field).padding(.horizontal, 14).padding(.vertical, 9)
                                    }
                                }
                            }
                        }
                    }

                    Toggle("Overwrite this persona?", isOn: $overwriting)
                        .font(.system(size: 13))
                        .onChange(of: overwriting) { _, on in
                            if on { text = draft.markdown(connected: connected); return }
                            // Ask first, because it is a deletion: turning this off
                            // returns to the form and discards any hand-written prompt.
                            guard draft.overrideText != nil
                                    || text != draft.markdown(connected: connected) else {
                                draft.overrideText = nil
                                return
                            }
                            let alert = NSAlert()
                            alert.alertStyle = .warning
                            alert.messageText = "Go back to the form?"
                            alert.informativeText =
                                "The prompt you wrote is replaced by one built from the options. "
                                + "Your text is not kept."
                            alert.addButton(withTitle: "Discard my text")
                            alert.addButton(withTitle: "Keep editing")
                            if alert.runModal() == .alertFirstButtonReturn {
                                draft.overrideText = nil
                                text = draft.markdown(connected: connected)
                            } else {
                                overwriting = true
                            }
                        }
                    Text(overwriting
                        ? "The options above are ignored while this is on."
                        : "Write the whole prompt yourself instead of filling in the form.")
                        .font(.system(size: 11))
                        .foregroundStyle(DeikoStyle.ink2)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    draft.overrideText = overwriting ? text : nil
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(InkButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 620)
        .background(DeikoStyle.paper)
    }

    @ViewBuilder private func control(_ field: PersonaForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch field.kind {
            case .toggle:
                Toggle(field.label, isOn: Binding(
                    get: { draft.isOn(field.id) },
                    set: { draft.options[field.id] = $0 ? "1" : "0" }
                ))
                .font(.system(size: 13))
            case .choice(let choices):
                HStack(spacing: 10) {
                    Text(field.label).font(.system(size: 13)).frame(width: 118, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { draft.value(field.id) },
                        set: { draft.options[field.id] = $0 }
                    )) {
                        ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    Spacer()
                }
            case .text(let placeholder):
                HStack(spacing: 10) {
                    Text(field.label).font(.system(size: 13)).frame(width: 118, alignment: .leading)
                    TextField(placeholder, text: Binding(
                        get: { draft.value(field.id) },
                        set: { draft.options[field.id] = $0 }
                    ))
                    .font(.system(size: 13))
                }
            case .paragraph(let placeholder):
                // Body font, not mono: this is a sentence somebody types.
                TextEditor(text: Binding(
                    get: { draft.value(field.id) },
                    set: { draft.options[field.id] = $0 }
                ))
                .font(.system(size: 13))
                .frame(minHeight: 76)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DeikoStyle.controlRadius)
                        .fill(DeikoStyle.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: DeikoStyle.controlRadius)
                                .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
                        )
                )
                .overlay(alignment: .topLeading) {
                    if draft.value(field.id).isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(DeikoStyle.ink2)
                            .padding(.top, 14).padding(.leading, 11)
                            .allowsHitTesting(false)
                    }
                }
            }
            if let help = field.help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(DeikoStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
