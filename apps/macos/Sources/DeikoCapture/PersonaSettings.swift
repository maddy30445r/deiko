import AppKit
import SwiftUI
import DeikoHandoff

// ─────────────────────────────────────────────────────────────────────────────
// PERSONAS, IN SETTINGS
//
// The form is the product here. Somebody who writes QA tickets for a living
// should be able to say "P0–P3, Jira markup, no Environment field" without
// reading a prompt — so the controls are the vocabulary of the job, and the
// prose is generated from them. "Overwrite this persona" is the escape hatch
// for the person who would rather write the prompt themselves, and it takes
// over completely: no form, no merging, no help.
//
// Every row of this is also the vocabulary the board and the persona list in
// a future main window will be built from — a row, a chip, a default marker,
// a menu. It is worth more than a settings card.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class PersonaStore: ObservableObject {
    @Published private(set) var list: [Persona] = []
    @Published var defaultID: String = Personas.defaultID

    init() { reload() }

    /// Always from `Personas`, which adopts hand-edited files on the way past.
    /// Reading the stored form directly would quietly undo somebody's editing.
    func reload() {
        list = Personas.all()
        defaultID = Personas.defaultID
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

    /// "QA ticket v2" — the version somebody makes when the built-in is nearly
    /// right. It copies the options AND any hand-written text, because those
    /// are exactly what they are about to change.
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
        // A built-in has no delete — it has Reset. Deleting one would leave a
        // gap that seeding deliberately does not fill again.
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

// ── The pane ────────────────────────────────────────────────────────────────

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

            Text("Each persona is a file in ~/Documents/Deiko/personas. Edit it here, or open it in your own editor — Deiko uses whatever the file says.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open personas folder") { store.openFolder() }
                Spacer()
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona) { saved in
                store.update(saved)
                editing = nil
            } onCancel: { editing = nil }
        }
        .onAppear { store.reload() }
    }

    /// A row is the whole hit target, and the menu is the only thing inside it
    /// that is not "show me this one" — an arrangement the board will reuse.
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
                    .foregroundStyle(.secondary)
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
                .fill(DeikoStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DeikoStyle.insetRadius)
                        .strokeBorder(isSelected ? Color.primary.opacity(0.55) : DeikoStyle.hairline,
                                      lineWidth: 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: isSelected ? 13 : 8, x: 0, y: isSelected ? 7 : 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = persona.id }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The file itself, because that is what actually ships — a preview that
    /// paraphrased it would be a second thing to keep in sync.
    @ViewBuilder private var preview: some View {
        if let persona = selected {
            VStack(spacing: 0) {
                HStack {
                    Text(persona.overrideText == nil ? "What your agent will be asked" : "Your own wording, as written")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit…") { editing = persona }
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(DeikoStyle.paper)
                Divider()
                ScrollView {
                    Text(persona.markdown)
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

    private func tag(_ word: String) -> some View {
        Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DeikoStyle.mark)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DeikoStyle.accentSoft, in: Capsule())
    }
}

// ── The editor ──────────────────────────────────────────────────────────────

private struct PersonaEditor: View {
    @State private var draft: Persona
    @State private var overwriting: Bool
    @State private var text: String
    let onSave: (Persona) -> Void
    let onCancel: () -> Void

    init(persona: Persona, onSave: @escaping (Persona) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: persona)
        _overwriting = State(initialValue: persona.overrideText != nil)
        // The form's own rendering, so turning the switch on hands somebody
        // the real thing to edit rather than an empty box.
        _text = State(initialValue: persona.markdown)
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
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(PersonaForm.groups(for: draft.base)) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(group.title)
                                InsetCard {
                                    ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
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
                            // Turning it OFF returns to the form and drops the
                            // written text — said plainly in the line below,
                            // because it is the one destructive control here.
                            if on { text = draft.markdown } else { draft.overrideText = nil }
                        }
                    Text(overwriting
                        ? "The options above are ignored while this is on."
                        : "Write the whole prompt yourself instead of filling in the form.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
            }
            if let help = field.help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
