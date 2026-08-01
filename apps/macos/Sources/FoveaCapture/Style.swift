import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// THE DESIGN SYSTEM — one file, in code, because there is no asset pipeline
//
// From the Claude Design canvas (mddocs/design-brief.md was the prompt):
// Fovea is a system service, not an app — nearer the volume HUD than a window.
// Glass, hairlines, system type, and a strict chroma budget:
//
//   RED means "watching you" — capturing, and NOTHING else, ever.
//   ORANGE means "needs you" — permissions and failures.
//   ONE accent hue means "Fovea itself". Everything else is grey.
//
// The accent is Fovea indigo — oklch(0.50 0.13 272) light, oklch(0.74 0.11 272)
// dark — desaturated enough not to glow over code, and far from every system
// semantic colour so red and orange keep their meanings even for users whose
// macOS accent is blue. The sRGB values below are those oklch coordinates
// converted; the comments keep the originals so a future adjustment starts
// from the design's coordinates, not from hex archaeology.
//
// Colours are NSColor first and Color second: the capture overlay draws in
// Core Graphics, and a palette expressed only as SwiftUI Color would never
// reach the cursor ring or the recording pill.
// ─────────────────────────────────────────────────────────────────────────────

enum FoveaStyle {

    // ── Colour ──────────────────────────────────────────────────────────────

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// "Fovea itself" — the only hue the product owns.
    /// oklch(0.50 0.13 272) light · oklch(0.74 0.11 272) dark.
    static let accentNS = dynamic(
        light: NSColor(srgbRed: 74 / 255, green: 91 / 255, blue: 172 / 255, alpha: 1),
        dark: NSColor(srgbRed: 146 / 255, green: 166 / 255, blue: 241 / 255, alpha: 1)
    )

    /// The fovea mark's stroke on the coin — brighter than the accent so it
    /// reads against the coin's accent-washed fill.
    /// oklch(0.46 0.13 272) light · oklch(0.82 0.09 272) dark.
    static let markNS = dynamic(
        light: NSColor(srgbRed: 64 / 255, green: 80 / 255, blue: 160 / 255, alpha: 1),
        dark: NSColor(srgbRed: 175 / 255, green: 193 / 255, blue: 255 / 255, alpha: 1)
    )

    /// The coin's body. Light mode washes the accent; dark mode uses a deeper
    /// indigo — oklch(0.45 0.10 272) at half strength — so the coin has weight
    /// over a dark terminal without glowing.
    static let coinFillNS = dynamic(
        light: NSColor(srgbRed: 74 / 255, green: 91 / 255, blue: 172 / 255, alpha: 0.14),
        dark: NSColor(srgbRed: 66 / 255, green: 80 / 255, blue: 140 / 255, alpha: 0.50)
    )

    /// "Needs you" — permissions and failures. Never used for recording.
    static let needsYouNS = dynamic(
        light: NSColor(srgbRed: 201 / 255, green: 52 / 255, blue: 0, alpha: 1),
        dark: NSColor(srgbRed: 255 / 255, green: 159 / 255, blue: 10 / 255, alpha: 1)
    )

    /// The sent checkmark, and nothing else.
    static let sentGreenNS = dynamic(
        light: NSColor(srgbRed: 36 / 255, green: 138 / 255, blue: 61 / 255, alpha: 1),
        dark: NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
    )

    /// "Watching you" — the capturing pill and the menu-bar dot. If this
    /// colour appears anywhere that is not evidence of recording, that is a
    /// bug in the design, not a styling choice.
    static let recordRedNS = dynamic(
        light: NSColor(srgbRed: 255 / 255, green: 59 / 255, blue: 48 / 255, alpha: 1),
        dark: NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
    )

    /// The rim light across the coin's top half — what makes it read as a
    /// physical object that can be picked up rather than a filled circle.
    static let coinShineNS = dynamic(
        light: NSColor(white: 1, alpha: 0.5),
        dark: NSColor(white: 1, alpha: 0.12)
    )

    static var accent: Color { Color(nsColor: accentNS) }
    static var coinShine: Color { Color(nsColor: coinShineNS) }
    static var mark: Color { Color(nsColor: markNS) }
    static var coinFill: Color { Color(nsColor: coinFillNS) }
    static var needsYou: Color { Color(nsColor: needsYouNS) }
    static var sentGreen: Color { Color(nsColor: sentGreenNS) }

    // ── Shape ───────────────────────────────────────────────────────────────

    /// 6 controls · 10 inset cards · 16 floating panels · capsules for pills.
    static let controlRadius: CGFloat = 6
    static let insetRadius: CGFloat = 10
    static let panelRadius: CGFloat = 16

    // ── Motion ──────────────────────────────────────────────────────────────

    /// Live, not cached: the user can flip Reduce Motion while the orb is on
    /// screen, and the next pulse should already obey it.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// ── The fovea mark ──────────────────────────────────────────────────────────

/// A ring with a centred dot — the fovea is the point of the retina that sees
/// detail, so the mark IS the product: "I'm pointing at this." Two strokes,
/// scalable, and the same mark the menu bar will wear so the coin and the
/// status item are visibly the same object.
struct FoveaMark: View {
    /// Outer diameter of the ring.
    var diameter: CGFloat = 20
    var color: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: diameter / 10)
            Circle()
                .fill(color)
                .frame(width: diameter / 4, height: diameter / 4)
        }
        .frame(width: diameter, height: diameter)
    }
}
