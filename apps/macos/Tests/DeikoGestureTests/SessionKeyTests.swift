import Testing
@testable import DeikoGesture

// The table itself is the thing worth pinning. Every value here is consumed by
// a CGEvent tap that no test can drive, so a wrong keycode or mask shows up
// only as "the hotkey does nothing" on somebody's machine — the exact failure
// the app already had to grow a menu line to explain.

@Test("each key carries the keycode and device bit for its own physical key")
func keyTable() {
    // Virtual keycodes, and the `NX_DEVICER*KEYMASK` bits from IOKit. Right
    // Option's pair (61 / 0x40) is the one the shipped app already used, so it
    // is the anchor the other three were read against.
    #expect(SessionKey.rightOption.keyCode == 61)
    #expect(SessionKey.rightOption.deviceMask == 0x40)
    #expect(SessionKey.rightControl.keyCode == 62)
    #expect(SessionKey.rightControl.deviceMask == 0x2000)
}

@Test("no key that takes part in ordinary typing is offered")
func noTypingKeysAreOffered() {
    // Right Command (54 / 0x10) and Right Shift (60 / 0x04) were offered once
    // and are traps: `SessionGesture.press` stops a live session on ANY press
    // of the chosen key, so a capital letter or a ⌘C would end a recording
    // mid-demonstration. Anything added here must survive that question.
    #expect(!SessionKey.allCases.contains { $0.keyCode == 54 })   // Right Command
    #expect(!SessionKey.allCases.contains { $0.keyCode == 60 })   // Right Shift
}

@Test("no two keys share a keycode or a device bit")
func keysAreDistinct() {
    // A duplicate here means two menu entries that do the same thing, or worse,
    // one that silently answers to the other's key.
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
    // These strings live in UserDefaults. Renaming a case without a migration
    // would silently reset everybody to the default — which is the AltGr key
    // this setting exists to escape.
    for key in SessionKey.allCases {
        #expect(SessionKey(rawValue: key.rawValue) == key)
    }
    #expect(SessionKey(rawValue: "notAKey") == nil)
    #expect(SessionKey.fallback == .rightOption)
}
