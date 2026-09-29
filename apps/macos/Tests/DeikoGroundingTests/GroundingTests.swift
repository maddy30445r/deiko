import Testing
@testable import DeikoGrounding

// Each row is an element shape a real session resolved. The content cases
// matter most: a predicate that calls everything furniture would destroy
// grounding everywhere else.

@Test("a disclosure triangle's alt text is furniture")
func caretIsFurniture() {
    // The hit-test lands on the expander in the row's margin.
    #expect(!groundsContent(role: "AXImage", description: "Caret Right Icon"))
    #expect(!groundsContent(role: "AXImage", description: "Caret Down Icon"))
}

@Test("a static text's value is content")
func staticTextIsContent() {
    #expect(groundsContent(role: "AXStaticText", value: "question_sets"))
}

@Test("a labelled button is content, not furniture")
func labelledButtonIsContent() {
    // The line the predicate must not cross: controls carry meaning.
    #expect(groundsContent(role: "AXButton", title: "Run Query"))
    #expect(groundsContent(role: "AXRadioButton", title: "Production"))
}

@Test("a radio button labelled 0 is still its label")
func numericLabelIsNotSpecialCased() {
    // Not this predicate's job: a cell reading `0` is a fact about the data,
    // and no rule can tell the two apart from role and text alone. Unconditional
    // OCR covers it.
    #expect(groundsContent(role: "AXRadioButton", title: "0"))
}

@Test("an image with a real description is content")
func describedImageIsContent() {
    // Only presentational roles have their description distrusted, and the set
    // is small on purpose: an AXCell describing itself is describing data. The
    // value is synthetic.
    #expect(groundsContent(role: "AXCell", description: "identifier: 00000000"))
}

@Test("whitespace is not text")
func whitespaceIsNotText() {
    // A padded table cell must not count as grounded, or the OCR that would
    // read it is suppressed.
    #expect(!groundsContent(role: "AXStaticText", value: "   "))
    #expect(!groundsContent(role: "AXStaticText", value: "\n\t "))
    #expect(!groundsContent(role: "AXGroup"))
}

@Test("a bare container grounds nothing")
func bareGroupIsNothing() {
    // Chromium answers a hit-test with a layout container like this.
    #expect(!groundsContent(role: "AXGroup", value: nil, title: nil, description: nil))
}

@Test("selected text counts even when nothing else does")
func selectedTextIsContent() {
    #expect(groundsContent(role: "AXTextArea", selectedText: "getUserProficiency"))
}

@Test("an unknown role with a description is trusted")
func unknownRoleIsTrusted() {
    // The distrust list covers known decorative roles only. An unseen role
    // gets the benefit of the doubt, since a wrong "furniture" call loses a
    // referent.
    #expect(groundsContent(role: "AXSomeElectronThing", description: "Total: 412"))
    #expect(groundsContent(role: nil, description: "Total: 412"))
}
