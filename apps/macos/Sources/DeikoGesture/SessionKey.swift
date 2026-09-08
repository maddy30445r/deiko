// ─────────────────────────────────────────────────────────────────────────────
// WHICH KEY STARTS A SESSION
//
// Right Option was hardcoded, and on a great many keyboards that key is not
// spare: under most non-US layouts it is AltGr, the modifier that types `@`,
// `#`, `[`, `]`, `{`, `}` and `|`. Deiko starts a session on a DOUBLE TAP of
// it within 350ms, so somebody writing an array literal on a German or Nordic
// layout could open a recording as a side effect of typing — and nothing in
// the app named the key, let alone let them change it.
//
// TWO options, not four, and the two that are missing are the finding.
//
// Right Command and Right Shift were offered first and are traps.
// `SessionGesture.press` stops a live session on ANY press of the chosen key —
// "a tap while capturing is never the first half of anything" — and `Hotkey`
// fires it whatever else is held. So with Right Shift selected, typing a single
// capital letter ends the recording; with Right Command, so does ⌘C. Starting is
// as bad: ⌘C then ⌘V inside 350ms is a double-tap. Offering those as the escape
// from an AltGr collision would have replaced a rare accident with a constant
// one, in a Settings row that actively recommends the switch.
//
// What is left is the two right-hand modifiers that do not participate in
// ordinary typing: Right Option (unused on US layouts, AltGr elsewhere) and
// Right Control (people chord with the LEFT one). Left Option is not a
// candidate at all — it is the drawing key.
//
// THE DEVICE BIT, NOT THE COMBINED MASK. `.maskAlternate`, `.maskCommand` and
// friends are set while EITHER key of a pair is down, so testing one cannot
// tell left from right — the bug that produced a hold which never ended, when
// releasing Right Option while Left Option was held left the combined bit set
// and the state machine saw no change. These are the per-key device bits from
// IOKit's `NX_DEVICE*KEYMASK`, and `kLeftOptionFlagMask` in `Hotkey.swift`
// (0x20, left Option) is the matching constant for the drawing key.
// ─────────────────────────────────────────────────────────────────────────────

public enum SessionKey: String, CaseIterable, Sendable {
    case rightOption
    case rightControl

    /// Virtual keycode, as `.keyboardEventKeycode` reports it.
    public var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightControl: 62
        }
    }

    /// `NX_DEVICER*KEYMASK` — the flag bit for this key alone.
    public var deviceMask: UInt64 {
        switch self {
        case .rightOption: 0x40     // NX_DEVICERALTKEYMASK
        case .rightControl: 0x2000  // NX_DEVICERCTLKEYMASK
        }
    }

    /// The glyph, for a keycap or a pill: "⌥⌥ to start".
    public var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightControl: "⌃"
        }
    }

    /// The name, for prose: "double-tap Right Option".
    public var name: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        }
    }

    public static let fallback = SessionKey.rightOption
}
