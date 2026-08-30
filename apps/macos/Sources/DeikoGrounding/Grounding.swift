import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// IS THIS ELEMENT CONTENT, OR IS IT FURNITURE?
//
// The accessibility element under the cursor is what makes Deiko better than a
// screenshot — it is the difference between "the user pointed at pixels near
// (579, 551)" and "the user pointed at the field `question_sets`". So the
// question of whether an element actually names something is load-bearing, and
// until now it was answered twice, differently, by two files that disagreed.
//
// Both answers were "does it have any non-empty string?", and that is wrong in
// a way that costs referents. Measured on session 20260728-230442, in MongoDB
// Compass: three referents resolved to an `AXImage` whose only text was
// `"Caret Right Icon"` — the alt text of a disclosure triangle — and one to an
// `AXRadioButton` labelled `"0"`. All four passed "has text". The descent
// stopped there because the app had apparently "answered properly", and OCR was
// skipped because accessibility had "already got it". Those four referents
// reached the aligner carrying nothing about what the user meant.
//
// The distinction that matters is not presence, it is PROVENANCE:
//
//   • `value` and `selectedText` are what an element CONTAINS. A text field's
//     value is the text the user is looking at. Always content.
//   • `title` is usually content too — a static text's title is its text, a
//     button's title is what the button says, and "Run Query" is exactly the
//     kind of thing worth grounding on.
//   • `description` (AXDescription) is an author-supplied LABEL. On a
//     presentational role it describes the widget, not the data: "Caret Right
//     Icon", "Close", "Loading spinner". That is furniture.
//
// That rule catches the three carets. It deliberately does NOT catch the radio
// button labelled "0": a radio's title genuinely is its label, and radios are
// often labelled with things worth grounding on ("Production", "Staging").
// Deciding that short or numeric labels are furniture would be a guess that
// throws away real content — a cell containing `0` is a fact about the data.
// That referent is saved instead by running OCR unconditionally, which is the
// other half of this fix.
//
// Erring on the side of "furniture" is safe here in a way it usually is not,
// because the caller degrades gracefully: the descent simply keeps looking, and
// the crop is read either way.
// ─────────────────────────────────────────────────────────────────────────────

/// Roles whose `description` is a label for a control rather than the content
/// of one. Deliberately short: every role added here is a role whose alt text
/// we stop trusting, and most controls DO carry meaningful labels.
private let presentationalRoles: Set<String> = [
    "AXImage",
    "AXDisclosureTriangle",
]

/// Whether this element's text identifies content the user could have meant.
///
/// Takes plain strings rather than an `AXUIElement` so it can be tested — the
/// same reason `DeikoGesture` and `DeikoVoice` are separate targets. The caller
/// does the four attribute reads; this decides what they mean.
public func groundsContent(
    role: String?,
    value: String? = nil,
    title: String? = nil,
    description: String? = nil,
    selectedText: String? = nil
) -> Bool {
    // Whitespace is not text. An untrimmed check let a padded table cell and an
    // indentation-only line count as grounded, and both reached the aligner
    // with nothing in them.
    func present(_ s: String?) -> Bool {
        s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    if present(value) || present(selectedText) || present(title) { return true }

    // Only `description` is left. Trust it unless the role says it is describing
    // a widget.
    guard present(description) else { return false }
    return !presentationalRoles.contains(role ?? "")
}
