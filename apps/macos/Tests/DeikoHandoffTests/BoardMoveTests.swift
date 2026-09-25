import Foundation
import Testing
@testable import DeikoHandoff

@Test("the board moves out of Documents once, its paths rewritten, nothing overwritten")
func boardMove() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("deiko-move-\(UUID().uuidString)").path
    let old = "\(home)/Documents/Deiko", new = "\(home)/Library/Application Support/Deiko"
    let session = "\(old)/20260919-140321"
    try fm.createDirectory(atPath: "\(session)/crops", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(new)/models", withIntermediateDirectories: true)
    try Data("png".utf8).write(to: URL(fileURLWithPath: "\(session)/crops/h01-r001.png"))
    try #"{"cropPath":"\#(session)/crops/h01-r001.png"}"#.write(toFile: "\(session)/brief.json", atomically: true, encoding: .utf8)
    try "{}".write(toFile: "\(old)/tasks.json", atomically: true, encoding: .utf8)
    try "mine".write(toFile: "\(new)/tasks.json", atomically: true, encoding: .utf8)

    #expect(BoardMove.run(from: old, to: new) == 1, "the session moves; tasks.json is already there")
    let brief = try String(contentsOfFile: "\(new)/20260919-140321/brief.json", encoding: .utf8)
    #expect(brief == #"{"cropPath":"\#(new)/20260919-140321/crops/h01-r001.png"}"#)
    #expect(fm.fileExists(atPath: "\(new)/20260919-140321/crops/h01-r001.png"))
    #expect(try String(contentsOfFile: "\(new)/tasks.json", encoding: .utf8) == "mine", "never overwritten")
    #expect(fm.fileExists(atPath: "\(old)/tasks.json"), "left where it was, so the old folder stays")
    #expect(fm.fileExists(atPath: "\(new)/models"))

    try fm.removeItem(atPath: "\(old)/tasks.json")
    #expect(BoardMove.run(from: old, to: new) == 0)
    #expect(!fm.fileExists(atPath: old), "an empty old folder goes")
    #expect(BoardMove.run(from: old, to: new) == 0, "and a second launch does nothing")
    try? fm.removeItem(atPath: home)
}
