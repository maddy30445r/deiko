import Foundation
import Testing
@testable import DeikoHandoff

private func rows(_ data: Data?) throws -> [Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
}

@Test("a rename changes one row and writes every other back as it was, even ones the app cannot read")
func renameKeepsEveryOtherRow() throws {
    let existing = Data("""
    [{"id":"t-1","title":"Price bug","from":"narration","later":"a key the app does not know"},
     {"id":"t-2","title":"Chart drop","from":"summary"},
     "not a row at all",
     {"id":5}]
    """.utf8)
    let out = try rows(TaskTitles.renaming(existing, id: "t-2", to: "Signup chart"))
    #expect(out.count == 4)
    let first = try #require(out[0] as? [String: String])
    #expect(first == ["id": "t-1", "title": "Price bug", "from": "narration", "later": "a key the app does not know"])
    let renamed = try #require(out[1] as? [String: String])
    #expect(renamed == ["id": "t-2", "title": "Signup chart", "from": "you"])
    #expect(out[2] as? String == "not a row at all")
    #expect((out[3] as? [String: Int]) == ["id": 5])
}

@Test("a task nobody named yet gets a row, even before there is a file")
func renameAddsARow() throws {
    let out = try rows(TaskTitles.renaming(nil, id: "t-3", to: "Cart total"))
    #expect((out.first as? [String: String]) == ["id": "t-3", "title": "Cart total", "from": "you"])
}

@Test("a file that is not a list is refused, never overwritten")
func renameRefusesAnUnreadableFile() {
    #expect(TaskTitles.renaming(Data("{\"id\":\"t-1\"}".utf8), id: "t-1", to: "x") == nil)
    #expect(TaskTitles.renaming(Data("[{\"id\":".utf8), id: "t-1", to: "x") == nil)
}
