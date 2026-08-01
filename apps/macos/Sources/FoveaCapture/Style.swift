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

    /// The capturing pill's body — deliberately NOT dynamic and NOT
    /// translucent: the one opaque surface Fovea draws, identical over any
    /// wallpaper, unchanged by Reduce Transparency because it was never
    /// transparent.
    static let pillRedNS = NSColor(srgbRed: 229 / 255, green: 56 / 255, blue: 46 / 255, alpha: 1)

    /// Region-capture pulses only — the lasso's "got it" ring. A point's ring
    /// is the accent; the two are distinguishable at a glance mid-session.
    static let regionTealNS = dynamic(
        light: NSColor(srgbRed: 0, green: 144 / 255, blue: 168 / 255, alpha: 1),
        dark: NSColor(srgbRed: 64 / 255, green: 203 / 255, blue: 224 / 255, alpha: 1)
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

// ── The menu-bar mark ───────────────────────────────────────────────────────

extension FoveaStyle {

    /// The fovea mark for the status item — the same ring-and-dot the orb's
    /// coin wears, so the menu bar and the orb are visibly the same object.
    ///
    /// Three states, each a SHAPE change so colour is never the only signal:
    ///   ready     — ring with a small centred dot (template, follows the bar)
    ///   capturing — the dot swells to fill the ring, in record red
    ///   blocked   — ring-and-dot with an orange `!` at the corner
    static func menuBarIcon(recording: Bool, blocked: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let stroke: CGFloat = 1.5
            let ring = NSRect(x: 2.5, y: 1.5, width: 13, height: 13).insetBy(dx: stroke / 2, dy: stroke / 2)

            if recording {
                // The swollen dot. Red is drawn literally — a template image
                // would flatten it to the bar colour, and this state must not
                // be mistakable for ready.
                recordRedNS.setStroke()
                recordRedNS.setFill()
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = stroke
                path.stroke()
                NSBezierPath(ovalIn: ring.insetBy(dx: 3, dy: 3)).fill()
            } else {
                // Ready ships as a template (black is the template convention);
                // blocked cannot be one — the `!` must stay orange — so its
                // ring uses labelColor, which the drawing handler re-resolves
                // per appearance every time the image is drawn.
                let ink: NSColor = blocked ? .labelColor : .black
                ink.setStroke()
                ink.setFill()
                let path = NSBezierPath(ovalIn: ring)
                path.lineWidth = stroke
                path.stroke()
                let dot = NSRect(x: ring.midX - 1.75, y: ring.midY - 1.75, width: 3.5, height: 3.5)
                NSBezierPath(ovalIn: dot).fill()
                if blocked {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                        .foregroundColor: needsYouNS,
                    ]
                    ("!" as NSString).draw(at: NSPoint(x: size.width - 4, y: size.height - 10), withAttributes: attrs)
                }
            }
            return true
        }
        // Template only while nothing is coloured: ready adapts to the bar,
        // capturing keeps its red, blocked keeps its orange.
        image.isTemplate = !recording && !blocked
        return image
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
