import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// THE DESIGN SYSTEM — one file, in code, because there is no asset pipeline
//
// From the Claude Design canvas (mddocs/design-brief.md was the prompt):
// Deiko is a system service, not an app — nearer the volume HUD than a window.
// Glass, hairlines, system type, and a strict chroma budget:
//
//   RED means "watching you" — capturing, and NOTHING else, ever.
//   ORANGE means "needs you" — permissions and failures.
//   ONE accent hue means "Deiko itself". Everything else is grey.
//
// The accent is Deiko indigo — oklch(0.50 0.13 272) light, oklch(0.74 0.11 272)
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

enum DeikoStyle {

    // ── Colour ──────────────────────────────────────────────────────────────

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// "Deiko itself" — the only hue the product owns.
    /// oklch(0.50 0.13 272) light · oklch(0.74 0.11 272) dark.
    static let accentNS = dynamic(
        light: NSColor(srgbRed: 74 / 255, green: 91 / 255, blue: 172 / 255, alpha: 1),
        dark: NSColor(srgbRed: 146 / 255, green: 166 / 255, blue: 241 / 255, alpha: 1)
    )

    /// The ink drawn onto a crop's own pixels — fixed, not dynamic. The crop
    /// was captured under whatever appearance the SOURCE app was in, so the
    /// ink drawn onto it must not shift with Deiko's own light/dark setting.
    static let inkNS = NSColor(srgbRed: 74 / 255, green: 91 / 255, blue: 172 / 255, alpha: 1)

    /// The Deiko mark's stroke on the coin — brighter than the accent so it
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

    /// The menu bar's recording tint — deliberately NOT dynamic, for the same
    /// class of reason as `inkNS` and the pill below.
    ///
    /// THE MENU BAR IS NOT THE APP'S APPEARANCE. How dark it renders follows
    /// the desktop content behind it, while a dynamic NSColor resolves against
    /// the app's own effectiveAppearance — i.e. the system Light/Dark setting.
    /// In Light Mode with a dark window behind the bar, the two disagree: the
    /// bar is dark and the colour resolves to its LIGHT variant. Measured on
    /// `needsYouNS`, that is rgb(201,52,0) at 4.0:1 against a dark bar, versus
    /// 10.2:1 for the dark variant — which is exactly the "it looks blackish
    /// and disappears when another app is open" that was reported. A fixed
    /// bright value cannot fall into that gap.
    static let menuBarRecordingNS = NSColor(srgbRed: 255 / 255, green: 59 / 255, blue: 48 / 255, alpha: 1)

    /// The capturing pill's body — deliberately NOT dynamic and NOT
    /// translucent: the one opaque surface Deiko draws, identical over any
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

    // ── Surface ─────────────────────────────────────────────────────────────
    //
    // The studio white the site is built from, translated for a window that
    // has to survive dark mode. Light mode is the site's own paper and white;
    // dark mode is the same system rebuilt, NOT the light one dimmed — a card
    // is lighter than its ground in the dark, where in the light it is darker.

    /// A window's ground. Cards sit ON this, never the reverse.
    static let paperNS = dynamic(
        light: NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1),
        dark: NSColor(srgbRed: 30 / 255, green: 31 / 255, blue: 38 / 255, alpha: 1)
    )

    /// The card that holds rows — the grouping surface everywhere.
    static let cardNS = dynamic(
        light: NSColor.white,
        dark: NSColor(srgbRed: 38 / 255, green: 39 / 255, blue: 47 / 255, alpha: 1)
    )

    /// 1px, and never more. The site's whole border vocabulary.
    static let hairlineNS = dynamic(
        light: NSColor(srgbRed: 236 / 255, green: 236 / 255, blue: 239 / 255, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.09)
    )

    /// The tint behind indigo text and icons: chips, glyph tiles, the coin's
    /// socket, a selected row.
    static let accentSoftNS = dynamic(
        light: NSColor(srgbRed: 238 / 255, green: 241 / 255, blue: 255 / 255, alpha: 1),
        dark: NSColor(srgbRed: 146 / 255, green: 166 / 255, blue: 241 / 255, alpha: 0.16)
    )

    /// The primary button. Ink in the light, and the accent in the dark, where
    /// near-black on near-black would be a button you cannot find.
    static let buttonInkNS = dynamic(
        light: NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1),
        dark: NSColor(srgbRed: 146 / 255, green: 166 / 255, blue: 241 / 255, alpha: 1)
    )

    /// What sits on `buttonInk`.
    static let buttonInkTextNS = dynamic(
        light: NSColor.white,
        dark: NSColor(srgbRed: 26 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1)
    )

    /// The second voice: notes under a control, metadata, the sentence that
    /// explains a number.
    ///
    /// NOT `.secondary`. AppKit's secondary label is black at 50%, which
    /// composites to rgb(127,127,127) on white — a hard ceiling of 4.00:1 on
    /// a card and 3.94:1 on paper. Every explanatory line in the app sat under
    /// that ceiling at 11pt, in the appearance most people use in daylight,
    /// and no per-element fix could lift it because it is one system colour
    /// used everywhere. These two clear 4.5:1 on card, on paper AND on the
    /// lavender wall, in their own appearance.
    static let ink2NS = dynamic(
        light: NSColor(srgbRed: 100 / 255, green: 100 / 255, blue: 107 / 255, alpha: 1),
        dark: NSColor(srgbRed: 172 / 255, green: 172 / 255, blue: 182 / 255, alpha: 1)
    )

    /// Shadows are long, soft and tinted indigo — paper resting on a desk,
    /// never a hard offset.
    /// The site's card shadow is `0 24px 60px -28px` — a long fall with a
    /// NEGATIVE spread, which is what keeps it under the card instead of
    /// around it. SwiftUI has no spread, so the same shape is bought with a
    /// weaker colour and a lower offset; a stronger one here reads as a cloud.
    static let shadowNS = dynamic(
        light: NSColor(srgbRed: 30 / 255, green: 36 / 255, blue: 90 / 255, alpha: 0.15),
        dark: NSColor(white: 0, alpha: 0.4)
    )

    /// The lavender wall: the site's presentation surface, and the one place
    /// colour fills an area. It goes behind a header or a preview — NEVER
    /// behind a control, which is how it stays a backdrop instead of a theme.
    static var wall: LinearGradient {
        LinearGradient(
            colors: [Color(nsColor: wallTopNS), Color(nsColor: wallBottomNS)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static let wallTopNS = dynamic(
        light: NSColor(srgbRed: 223 / 255, green: 228 / 255, blue: 255 / 255, alpha: 1),
        dark: NSColor(srgbRed: 52 / 255, green: 58 / 255, blue: 99 / 255, alpha: 1)
    )

    static let wallBottomNS = dynamic(
        light: NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 255 / 255, alpha: 1),
        dark: NSColor(srgbRed: 38 / 255, green: 40 / 255, blue: 56 / 255, alpha: 1)
    )

    /// The tooltip: one slate with a lean towards the mark's indigo, the same
    /// in Light and Dark, so a tip looks like a tip wherever it pops. Dark
    /// enough to stand off white cards, light enough to lift off dark ones.
    static let tipFillNS = NSColor(srgbRed: 74 / 255, green: 76 / 255, blue: 92 / 255, alpha: 1)
    static let tipTextNS = NSColor(white: 1, alpha: 0.94)
    /// The mark's dot, lifted so it reads on the tooltip's dark fill.
    static let tipDotNS = NSColor(srgbRed: 160 / 255, green: 172 / 255, blue: 255 / 255, alpha: 1)

    static var accent: Color { Color(nsColor: accentNS) }
    static var paper: Color { Color(nsColor: paperNS) }
    static var card: Color { Color(nsColor: cardNS) }
    static var hairline: Color { Color(nsColor: hairlineNS) }
    static var accentSoft: Color { Color(nsColor: accentSoftNS) }
    static var buttonInk: Color { Color(nsColor: buttonInkNS) }
    static var buttonInkText: Color { Color(nsColor: buttonInkTextNS) }
    static var ink2: Color { Color(nsColor: ink2NS) }
    static var shadow: Color { Color(nsColor: shadowNS) }
    static var coinShine: Color { Color(nsColor: coinShineNS) }
    static var mark: Color { Color(nsColor: markNS) }
    static var coinFill: Color { Color(nsColor: coinFillNS) }
    static var needsYou: Color { Color(nsColor: needsYouNS) }
    static var sentGreen: Color { Color(nsColor: sentGreenNS) }
    static var tipFill: Color { Color(nsColor: tipFillNS) }
    static var tipText: Color { Color(nsColor: tipTextNS) }
    static var tipDot: Color { Color(nsColor: tipDotNS) }

    // ── Shape ───────────────────────────────────────────────────────────────

    /// 8 controls · 14 cards and rows · 18 floating panels · capsules for
    /// pills. Nested corners get smaller as they get deeper, never larger.
    static let controlRadius: CGFloat = 8
    static let insetRadius: CGFloat = 14
    static let panelRadius: CGFloat = 18

    // ── Type ────────────────────────────────────────────────────────────────
    //
    // TITLES ONLY, and this is the whole rule. Bricolage Grotesque carries
    // window titles, card headings and the orb's verdict line — the few words
    // that say whose app this is. Every control label, every sentence, and
    // anything read at 11pt stays in the system face, because that is the type
    // macOS hinted for small sizes and the type the rest of the Mac speaks.
    //
    // The face is registered into THIS PROCESS only (`.process` scope), so
    // Deiko never installs a font on someone's Mac. If the file is missing —
    // a build that forgot to copy it — `title` falls back to the system
    // semibold and every window still reads correctly, just in SF.

    /// The 12pt optical size at SemiBold: the cut drawn for small text, which
    /// is the only size this app uses it at. SIL OFL 1.1, see Bricolage-OFL.txt.
    private static let titleFace: String? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Bricolage.ttf"))
        }
        // `make dev` runs the bare binary straight out of `.build`, which has
        // no Resources directory at all. The compile-time path of this file is
        // the checkout it was built from — right for a developer's build, and
        // simply a path that does not exist in anybody else's, which is what
        // the `fileExists` below is for.
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Bricolage.ttf")
        )
        guard let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
              CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }()

    /// A title. Sentence case, always — the uppercase tracked label this app
    /// used to shout in is not in the design any more.
    static func title(_ size: CGFloat) -> Font {
        if let titleFace { return .custom(titleFace, size: size) }
        return .system(size: size, weight: .semibold)
    }

    /// -0.02em, the tracking the display face is drawn to be set at.
    static func titleTracking(_ size: CGFloat) -> CGFloat { -size * 0.02 }

    // ── Motion ──────────────────────────────────────────────────────────────

    /// Live, not cached: the user can flip Reduce Motion while the orb is on
    /// screen, and the next pulse should already obey it.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// ── Appearance ──────────────────────────────────────────────────────────────

/// Light, dark, or whatever the Mac is doing.
///
/// The design is built twice — every colour in `DeikoStyle` is a dynamic pair —
/// so following the system is the right default and costs nothing. The choice
/// exists because this app draws OVER other people's windows: somebody who
/// runs macOS light but codes in a dark editor all day has a real reason to
/// want the orb dark, and "match my editor, not my Finder" is not a preference
/// the system can express for them.
///
/// Applied to `NSApp`, which every window and every dynamic colour resolves
/// against — including the orb and the review panel, not just this window.
/// The capture pill is deliberately exempt: it is a fixed red that must look
/// identical over any wallpaper, in any appearance.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "Match macOS"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private static let key = "DEIKO_APPEARANCE"

    static var selected: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            newValue.apply()
        }
    }

    /// Nil means "stop deciding" — AppKit then follows the system, which is
    /// not the same as setting it to the system's current value: that one
    /// would freeze at whatever it was when the app launched.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// ── The shared modifiers ────────────────────────────────────────────────────

extension View {
    /// Bricolage at this size, tracked the way it is drawn to be set.
    func deikoTitle(_ size: CGFloat) -> some View {
        font(DeikoStyle.title(size)).tracking(DeikoStyle.titleTracking(size))
    }

    /// Paper resting on a desk: one long, soft, indigo-tinted shadow and a
    /// hairline. Offset downward, because a shadow with no offset is a glow.
    func deikoCard(radius: CGFloat = DeikoStyle.insetRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(DeikoStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
                )
                .shadow(color: DeikoStyle.shadow, radius: 13, x: 0, y: 7)
        )
    }
}

// ── The menu-bar mark ───────────────────────────────────────────────────────

extension DeikoStyle {

    /// The Deiko mark for the status item — the same ring-and-dot the orb's
    /// coin wears, so the menu bar and the orb are visibly the same object.
    ///
    /// Three states, each a SHAPE change so colour is never the only signal:
    ///   ready     — ring with a small centred dot
    ///   capturing — the dot swells to fill the ring
    ///   blocked   — ring-and-dot with an `!` at the corner
    ///
    /// ALWAYS a template image, always drawn in black. Colour arrives from the
    /// caller as `contentTintColor`, which AppKit resolves against the menu
    /// bar's real appearance. Drawing colours in here instead meant guessing
    /// that appearance from inside a drawing handler — and guessing wrong puts
    /// a dark ring on a dark menu bar.
    static func menuBarIcon(recording: Bool, blocked: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let stroke: CGFloat = 1.5
            let ring = NSRect(x: 2.5, y: 1.5, width: 13, height: 13).insetBy(dx: stroke / 2, dy: stroke / 2)

            NSColor.black.setStroke()
            NSColor.black.setFill()

            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = stroke
            path.stroke()

            if recording {
                // The dot swells to fill the ring — legible at 16pt in a way a
                // tint change alone is not.
                NSBezierPath(ovalIn: ring.insetBy(dx: 3, dy: 3)).fill()
            } else {
                let dot = NSRect(x: ring.midX - 1.75, y: ring.midY - 1.75, width: 3.5, height: 3.5)
                NSBezierPath(ovalIn: dot).fill()
                if blocked {
                    ("!" as NSString).draw(
                        at: NSPoint(x: size.width - 4.5, y: size.height - 10),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                            .foregroundColor: NSColor.black,
                        ]
                    )
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// ── The Deiko mark ──────────────────────────────────────────────────────────

// ── Keyboard focus ──────────────────────────────────────────────────────────

/// THE ONE PIECE OF CHROME THAT IGNORED THE DESIGN SYSTEM.
///
/// macOS draws its own focus ring: a system blue, at a system radius, with a
/// system inset — over a control whose colour, shape and corner this app
/// chose itself. On a sidebar row it lands as a rounded rectangle of the
/// wrong blue at the wrong radius, sitting a pixel outside the indigo wash
/// underneath it. Two shapes for one control, in two accent colours, on the
/// surface people look at first.
///
/// So the system effect is switched off and the ring is redrawn from the
/// palette, in the shape the control actually has. `DESIGN.md` already
/// assigns this colour: indigo marks what Deiko does, and focusing is on its
/// list.
///
/// THE RING IS NOT DELETED, which is the tempting one-line version and an
/// accessibility regression. Somebody driving this app from the keyboard —
/// Full Keyboard Access, or a switch device — has nothing but this ring to
/// tell them where they are. Deleting it would make the app look tidier in a
/// screenshot and unusable without a mouse.
///
/// 2pt, where every other border in this system is a 1pt hairline: a focus
/// ring is not a border. It has to be findable at a glance from across a
/// desk, and the hairline rule is about the edges of things at rest.
///
/// `.focused` binds to whatever focusability the control already had — this
/// never makes something focusable that was not, so the tab order is exactly
/// what it was before.
struct DeikoFocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay(
                shape
                    .strokeBorder(DeikoStyle.mark, lineWidth: 2)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// The app's own focus ring, in the shape this control draws.
    func deikoFocusRing<S: InsettableShape>(_ shape: S) -> some View {
        modifier(DeikoFocusRing(shape: shape))
    }

    /// The common case: a control with the standard corner.
    func deikoFocusRing(radius: CGFloat = DeikoStyle.controlRadius) -> some View {
        deikoFocusRing(RoundedRectangle(cornerRadius: radius))
    }

    /// A bare glyph or word with no background of its own. The ring needs a
    /// little room around the letterforms or it reads as a box drawn on top
    /// of them rather than around them.
    func deikoFocusRingLoose(radius: CGFloat = 6) -> some View {
        padding(4)
            .deikoFocusRing(RoundedRectangle(cornerRadius: radius))
            .padding(-4)
    }
}

/// A ring with a centred dot — the mark IS the product: "I'm pointing at
/// this." Two strokes,
/// scalable, and the same mark the menu bar will wear so the coin and the
/// status item are visibly the same object.
struct DeikoMark: View {
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
