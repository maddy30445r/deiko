import Testing
@testable import DeikoGesture

// The table is what is pinned: a wrong keycode or mask shows up only as "the
// hotkey does nothing" on somebody's machine, since no test can drive the
// CGEvent tap.

@Test("each key carries the keycode and device bit for its own physical key")
func keyTable() {
    // Virtual keycodes, and the `NX_DEVICER*KEYMASK` bits from IOKit.
    #expect(SessionKey.rightOption.keyCode == 61)
    #expect(SessionKey.rightOption.deviceMask == 0x40)
    #expect(SessionKey.rightControl.keyCode == 62)
    #expect(SessionKey.rightControl.deviceMask == 0x2000)
}

@Test("no key that takes part in ordinary typing is offered")
func noTypingKeysAreOffered() {
    // Right Command (54 / 0x10) and Right Shift (60 / 0x04) are traps:
    // `SessionGesture.press` stops a live session on any press of the key, so a
    // capital letter or a ⌘C would end a recording. Anything added here must
    // survive that question.
    #expect(!SessionKey.allCases.contains { $0.keyCode == 54 })   // Right Command
    #expect(!SessionKey.allCases.contains { $0.keyCode == 60 })   // Right Shift
}

@Test("no two keys share a keycode or a device bit")
func keysAreDistinct() {
    // A duplicate means two entries that do the same thing, or one that answers
    // to the other's key.
    let codes = Set(SessionKey.allCases.map(\.keyCode))
    let masks = Set(SessionKey.allCases.map(\.deviceMask))
    #expect(codes.count == SessionKey.allCases.count)
    #expect(masks.count == SessionKey.allCases.count)
}

@Test("no session key collides with Left Option, which draws")
func leftOptionIsNotAvailable() {
    // `Hotkey` tracks Left Option separately as the lasso modifier (keycode 58,
    // mask 0x20). A session key sharing either would make one gesture two.
    #expect(!SessionKey.allCases.contains { $0.keyCode == 58 })
    #expect(!SessionKey.allCases.contains { $0.deviceMask == 0x20 })
}

@Test("every key has a distinct glyph and name for the strings that follow it")
func labelsAreUsable() {
    let symbols = Set(SessionKey.allCases.map(\.symbol))
    let names = Set(SessionKey.allCases.map(\.name))
    #expect(symbols.count == SessionKey.allCases.count)
    #expect(names.count == SessionKey.allCases.count)
    #expect(SessionKey.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.name.isEmpty })
}

@Test("the raw values round-trip, because they are what gets stored")
func rawValuesRoundTrip() {
    // These strings live in UserDefaults; renaming a case without a migration
    // would reset everybody to the default.
    for key in SessionKey.allCases {
        #expect(SessionKey(rawValue: key.rawValue) == key)
    }
    #expect(SessionKey(rawValue: "notAKey") == nil)
    #expect(SessionKey.fallback == .rightOption)
}
