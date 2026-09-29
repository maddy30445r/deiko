import AppKit
import CoreGraphics
import Foundation
import ImageIO
import DeikoGesture
import UniformTypeIdentifiers

// Draws the user's stroke onto a finished crop, plus a numbered badge.
// Additive: every captured pixel survives underneath the stroke overlay.
// Runs after `Capture.crop`, so OCR reads the clean image and the agent reads
// this one.

enum InkRenderer {

    static func ink(
        file path: String, strokePath: [Point], cropRect: Frame,
        kind: StrokeKind, number: Int
    ) {
        guard cropRect.width > 0, cropRect.height > 0,
              let src = loadPNG(path),
              let inked = draw(on: src, strokePath: strokePath, cropRect: cropRect,
                               kind: kind, number: number)
        else { return }
        Capture.writePNG(inked, to: path)
    }

    /// Split from `ink` so the demo subcommand can run it on a synthetic image.
    static func draw(
        on src: CGImage, strokePath: [Point], cropRect: Frame,
        kind: StrokeKind, number: Int
    ) -> CGImage? {
        let w = src.width, h = src.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

        // The one top-left → bottom-left flip in this file. The crop was taken
        // at backing scale, so pixels-per-point comes from the image itself.
        let sx = Double(w) / cropRect.width
        let sy = Double(h) / cropRect.height
        func px(_ p: Point) -> CGPoint {
            CGPoint(x: (p.x - cropRect.x) * sx, y: Double(h) - (p.y - cropRect.y) * sy)
        }
        let scale = max(1.0, sx)
        // A scribble runs back and forth across the thing it emphasises, so at
        // full strength it would strike out the text. Highlighter weight keeps it
        // legible; every other kind outlines.
        let ink = DeikoStyle.inkNS.withAlphaComponent(kind == .emphasis ? 0.35 : 0.9).cgColor

        let points = strokePath.map(px)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(3 * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch kind {
        case .point:
            // A dot where the tap landed, ringed so it reads on any background.
            let c = px(strokePath.first ?? Point(x: cropRect.center.x, y: cropRect.center.y))
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: c.x - 6 * scale, y: c.y - 6 * scale,
                                       width: 12 * scale, height: 12 * scale))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5 * scale)
            ctx.strokeEllipse(in: CGRect(x: c.x - 6 * scale, y: c.y - 6 * scale,
                                         width: 12 * scale, height: 12 * scale))
        case .lasso, .emphasis, .trace, .connector:
            guard points.count >= 2 else { break }
            ctx.beginPath()
            ctx.move(to: points[0])
            for p in points.dropFirst() { ctx.addLine(to: p) }
            if kind == .lasso { ctx.closePath() }
            ctx.strokePath()
            if kind == .connector || kind == .trace {
                arrowhead(ctx, from: points[points.count - 2], to: points[points.count - 1],
                          color: ink, scale: scale)
            }
        }

        badge(ctx, number: number, strokeBBox: bbox(of: points),
              imageSize: CGSize(width: w, height: h), scale: scale)
        return ctx.makeImage()
    }

    /// Two barbs at ±30° off the final segment's direction.
    private static func arrowhead(
        _ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor, scale: Double
    ) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let len = 12 * scale
        ctx.setStrokeColor(color)
        for side in [-1.0, 1.0] {
            let barb = angle + .pi + side * (.pi / 6)
            ctx.beginPath()
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x + len * cos(barb), y: b.y + len * sin(barb)))
            ctx.strokePath()
        }
    }

    /// The badge sits just outside the stroke's own box — never on the marked
    /// pixels — at whichever corner leaves it fully inside the image.
    private static func badge(
        _ ctx: CGContext, number: Int, strokeBBox: CGRect,
        imageSize: CGSize, scale: Double
    ) {
        let r = 11 * scale
        let gap = 4 * scale
        let candidates = [
            CGPoint(x: strokeBBox.minX - r - gap, y: strokeBBox.maxY + r + gap),  // top-left (CG y-up)
            CGPoint(x: strokeBBox.maxX + r + gap, y: strokeBBox.maxY + r + gap),
            CGPoint(x: strokeBBox.minX - r - gap, y: strokeBBox.minY - r - gap),
            CGPoint(x: strokeBBox.maxX + r + gap, y: strokeBBox.minY - r - gap),
        ]
        let inside = { (p: CGPoint) -> Bool in
            p.x - r >= 0 && p.y - r >= 0
                && p.x + r <= imageSize.width && p.y + r <= imageSize.height
        }
        // A crop hugging its stroke may fit no corner. Clamp the first candidate
        // inside the image so the badge is never cut off, even if it touches the
        // stroke box.
        let c = candidates.first(where: inside) ?? CGPoint(
            x: min(max(candidates[0].x, r), imageSize.width - r),
            y: min(max(candidates[0].y, r), imageSize.height - r)
        )

        ctx.setFillColor(DeikoStyle.inkNS.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

        // Text via NSGraphicsContext so NSString can draw into the CG context.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let label = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13 * scale),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                   withAttributes: attrs)
        NSGraphicsContext.current = previous
    }

    private static func bbox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func loadPNG(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil
        ) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
