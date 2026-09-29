/// The key that starts and stops a session. Configurable because Right Option
/// is AltGr on many non-US layouts.
///
/// Only two options are offered. `SessionGesture.press` stops a live session on
/// any press of the key and `Hotkey` fires it whatever else is held, so Right
/// Shift or Right Command would end a recording on a capital letter or ⌘C.
///
/// Masks are the per-key IOKit device bits (`NX_DEVICE*KEYMASK`). The combined
/// `.maskAlternate`-style flags stay set while either key of a pair is down and
/// cannot tell left from right. `kLeftOptionFlagMask` in `Hotkey.swift` is the
/// matching constant for the drawing key.
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
