import Foundation
import Testing
@testable import DeikoHandoff

@Test func memoryEditsForgetAndRewordAndReadTheScriptsShape() throws {
    let o = BoardTimeline.outcome("## Decided\n- It's the cache.\n- Keep the toast.\n## Open\n- Check Safari.\n")
    let e = try JSONDecoder().decode(MemoryEdits.self, from: Data(#"{"forget":["It's the cache."],"edit":{"Check Safari.":"Check Safari 17 and 18."}}"#.utf8))
    let fixed = e.applied(to: o)
    #expect(fixed.decided == ["Keep the toast."])
    #expect(fixed.open == ["Check Safari 17 and 18."])
    #expect(e.original(of: "Check Safari 17 and 18.") == "Check Safari.")
    #expect(e.original(of: "Keep the toast.") == "Keep the toast.")
    // A file with only one field, or a wrong one, corrects nothing it can't read.
    let partial = try JSONDecoder().decode(MemoryEdits.self, from: Data(#"{"forget":"oops"}"#.utf8))
    #expect(partial.isEmpty)
    #expect(partial.applied(to: o) == o)
}

@Test func outcomeWithWindowsLineEndingsReadsLikeAnyOther() {
    let o = BoardTimeline.outcome("## Decided\r\n- Keep the toast.\r\n## Open\r\n- Listing page.\r\n")
    #expect(o.decided == ["Keep the toast."])
    #expect(o.open == ["Listing page."])
}
