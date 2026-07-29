import Testing
@testable import FoveaGrounding

// Every row here is an element a real session actually resolved. Session
// 20260728-230442 in MongoDB Compass is where the furniture cases come from;
// the content cases are the ones that must keep working, which is the harder
// half — a predicate that calls everything furniture would "fix" that session
// and destroy grounding everywhere else.

@Test("a disclosure triangle's alt text is furniture")
func caretIsFurniture() {
    // Three referents in one session resolved to exactly this. The user was
    // pointing at the row; the hit-test landed on the expander in its margin.
    #expect(!groundsContent(role: "AXImage", description: "Caret Right Icon"))
    #expect(!groundsContent(role: "AXImage", description: "Caret Down Icon"))
}

@Test("a static text's value is content")
func staticTextIsContent() {
    #expect(groundsContent(role: "AXStaticText", value: "question_sets"))
}

@Test("a labelled button is content, not furniture")
func labelledButtonIsContent() {
    // The line the predicate must not cross. Controls carry meaning constantly
    // — this is the case that stops "be strict about ornaments" turning into
    // "throw away everything interactive".
    #expect(groundsContent(role: "AXButton", title: "Run Query"))
    #expect(groundsContent(role: "AXRadioButton", title: "Production"))
}

@Test("a radio button labelled 0 is still its label")
func numericLabelIsNotSpecialCased() {
    // This referent grounded badly in the real session, and it is NOT this
    // predicate's job to rescue it: a cell reading `0` is a fact about the
    // data, and no rule can tell the two apart from role and text alone.
    // Unconditional OCR is what covers it.
    #expect(groundsContent(role: "AXRadioButton", title: "0"))
}

@Test("an image with a real description is content")
func describedImageIsContent() {
    // Only PRESENTATIONAL roles have their description distrusted, and the set
    // is small on purpose. An AXCell describing itself is describing data.
    #expect(groundsContent(role: "AXCell", description: "identifier: 9b50a7e7"))
}

@Test("whitespace is not text")
func whitespaceIsNotText() {
    // An untrimmed check let a padded table cell count as grounded, which
    // suppressed the OCR that would have read it. Real regression.
    #expect(!groundsContent(role: "AXStaticText", value: "   "))
    #expect(!groundsContent(role: "AXStaticText", value: "\n\t "))
    #expect(!groundsContent(role: "AXGroup"))
}

@Test("a bare container grounds nothing")
func bareGroupIsNothing() {
    // Seven of twelve points in the real session came back exactly like this —
    // Chromium answering a hit-test with a layout container.
    #expect(!groundsContent(role: "AXGroup", value: nil, title: nil, description: nil))
}

@Test("selected text counts even when nothing else does")
func selectedTextIsContent() {
    #expect(groundsContent(role: "AXTextArea", selectedText: "getUserProficiency"))
}

@Test("an unknown role with a description is trusted")
func unknownRoleIsTrusted() {
    // The distrust list is an allowlist of things we know are decorative. A
    // role we have never seen gets the benefit of the doubt, because the cost
    // of a wrong "furniture" call is a lost referent.
    #expect(groundsContent(role: "AXSomeElectronThing", description: "Total: 412"))
    #expect(groundsContent(role: nil, description: "Total: 412"))
}
