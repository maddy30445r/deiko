import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE APP ICON, DRAWN FROM THE SAME MARK EVERYTHING ELSE WEARS
//
// The mark — a ring with a centred dot — is the product's whole thesis in
// one shape: this one, here. The orb's
// coin draws it in SwiftUI (`DeikoMark`), the menu bar draws it in AppKit
// (`DeikoStyle.menuBarIcon`), and this draws it into an `.iconset`. An icon
// that drifted from the coin would make the Dock and the orb look like two
// apps, so all three live in one binary and one of them cannot silently rot.
//
// This used to be a Node script with a hand-written PNG encoder — a CRC32
// table, IHDR/IDAT chunking, a zlib stream and an analytic rasteriser, ~200
// lines to draw two circles on a rounded rectangle. AppKit already draws and
// already encodes PNG, so all that is left is the geometry.
//
// Generated rather than designed in a tool, and the resulting `.icns` is
// COMMITTED, so `make bundle` needs nothing but a copy. Re-run `make icon`
// after changing the geometry below.
// ─────────────────────────────────────────────────────────────────────────────

// ── Geometry, as fractions of the canvas ────────────────────────────────────
//
// macOS icons are a rounded rectangle inset inside a transparent canvas — the
// system draws shadows in that margin, so filling the whole square makes an app
// look subtly larger and cheaper than every icon beside it.

private let inset = 0.098        // Apple's macOS template: ~824/1024 content
private let cornerRatio = 0.225  // Apple's template: 185.4 radius on an 824 rect
private let ringOuter = 0.245    // the mark's ring, from the canvas centre
private let ringWidth = 0.046
private let dotRadius = 0.061

// Indigo, the one hue the product owns. A vertical gradient rather than a flat
// fill, matching the coin's rim light. Fixed sRGB rather than `DeikoStyle`'s
// dynamic colours: an icon file has no appearance to resolve against, and the
// Dock renders the same pixels in light and dark mode.
private let plateTop = NSColor(srgbRed: 0x5a / 255, green: 0x6b / 255, blue: 0xc4 / 255, alpha: 1)
private let plateBottom = NSColor(srgbRed: 0x37 / 255, green: 0x44 / 255, blue: 0x8c / 255, alpha: 1)
private let markColor = NSColor(srgbRed: 0xee / 255, green: 0xf1 / 255, blue: 0xff / 255, alpha: 1)

/// The names `iconutil` expects. Each logical size twice, at 1× and at 2× —
/// which means only six distinct pixel sizes: `icon_32x32.png` and
/// `icon_16x16@2x.png` are the same 32px image under two names.
private let wanted: [(size: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

/// Draw the icon at `size` and return it as PNG data.
private func iconPNG(size: Int) -> Data? {
    let n = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let margin = n * inset
    let plate = NSRect(x: margin, y: margin, width: n - 2 * margin, height: n - 2 * margin)
    let corner = plate.width * cornerRatio

    let rounded = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)
    // Top-to-bottom in screen terms, which is bottom-to-top in this flipped-off
    // coordinate space — hence the reversed stops.
    NSGradient(starting: plateBottom, ending: plateTop)?.draw(in: rounded, angle: 90)

    markColor.setStroke()
    markColor.setFill()

    let outer = n * ringOuter
    let stroke = n * ringWidth
    let centre = NSPoint(x: n / 2, y: n / 2)
    // `strokeBorder` semantics: inset by half the line width so the stroke sits
    // INSIDE `ringOuter` rather than straddling it, matching `DeikoMark`.
    let ringRect = NSRect(
        x: centre.x - outer + stroke / 2, y: centre.y - outer + stroke / 2,
        width: (outer - stroke / 2) * 2, height: (outer - stroke / 2) * 2
    )
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = stroke
    ring.stroke()

    let dot = n * dotRadius
    NSBezierPath(ovalIn: NSRect(
        x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2
    )).fill()

    return rep.representation(using: .png, properties: [:])
}

/// `deiko-capture icon --out <Deiko.iconset>` — a build step, not a runtime one.
@MainActor
func renderIconset(_ args: Args) {
    guard let out = args.string("out") else {
        Emit.event(ErrorEvent("icon needs --out <dir>", hint: "e.g. --out build/Deiko.iconset"))
        exit(2)
    }

    let fm = FileManager.default
    try? fm.removeItem(atPath: out)
    do {
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    } catch {
        Emit.event(ErrorEvent("could not create \(out): \(error.localizedDescription)"))
        exit(1)
    }

    var cache: [Int: Data] = [:]
    for (size, name) in wanted {
        guard let png = cache[size] ?? iconPNG(size: size) else {
            Emit.event(ErrorEvent("could not render the icon at \(size)px"))
            exit(1)
        }
        cache[size] = png
        do {
            try png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        } catch {
            Emit.event(ErrorEvent("could not write \(name): \(error.localizedDescription)"))
            exit(1)
        }
    }

    Emit.log("✓ \(wanted.count) pngs → \(out)")
}
