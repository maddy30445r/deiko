import AppKit
import ImageIO
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// CROP THUMBNAILS, DECODED ONCE AND SMALL
//
// A crop is a full-resolution Retina screenshot of whatever was circled — a
// multi-megabyte PNG. The board drew them with `NSImage(contentsOfFile:)`
// inside a view's `body`, which means the main thread decoded every visible
// card's PNG at full size, again on every scroll pass that rebuilt a cell, and
// again for every state change anywhere in the window. At five sessions that
// is invisible. At three hundred it is the whole grid stuttering.
//
// `ReviewWindow` already learned this lesson for the review card and says so
// at length; this is the same fix for the board, with two additions it needs
// and the review card does not: a DOWNSAMPLE (a 96pt tile does not need 3000
// pixels) and a CACHE (the same crop is drawn by the dashboard, the board, and
// again after every reload).
//
// ImageIO rather than NSImage: `kCGImageSourceThumbnailMaxPixelSize` decodes
// straight to the size asked for, so a 12MB PNG never exists in memory at full
// size. Decoding with NSImage and then scaling in the view does the expensive
// half of the work anyway.
// ─────────────────────────────────────────────────────────────────────────────

/// NOT OBSERVABLE. It used to be, and every decode that landed told every
/// thumbnail on the board to redraw; with a 240-image cap and more cards than
/// that, redrawing re-requested evicted images, which landed, which redrew
/// everything again. Each `CropThumbnail` now waits for its own image.
@MainActor
final class Thumbnails {

    static let shared = Thumbnails()

    /// Keyed by path AND size: the dashboard's 96pt tiles and the board's
    /// 210pt cards are different images of the same file. `NSCache` evicts
    /// the least recently used first, and gives memory back under pressure.
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
    /// One decode per image however many cards ask at once.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    static func key(_ path: String, maxPoints: CGFloat) -> String {
        "\(path)#\(Int(maxPoints * (NSScreen.main?.backingScaleFactor ?? 2)))"
    }

    /// Already decoded — the first frame of a card that has been drawn before.
    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// The thumbnail, decoded off the main thread if it is not cached.
    func image(_ path: String, maxPoints: CGFloat) async -> NSImage? {
        let key = Self.key(path, maxPoints: maxPoints)
        if let hit = cached(key) { return hit }
        if let running = inFlight[key] { return await running.value }
        let pixels = maxPoints * (NSScreen.main?.backingScaleFactor ?? 2)
        let task = Task { await Self.decode(path: path, pixels: pixels) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// `nonisolated` so the decode runs off the main actor — the whole point.
    private nonisolated static func decode(path: String, pixels: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// One crop, at the size it is actually drawn.
///
/// The placeholder is the wall rather than a spinner: a grid of spinners is
/// noisier than the images it is standing in for, and the decode is fast
/// enough that a spinner would mostly be a flash.
struct CropThumbnail: View {
    let path: String
    var width: CGFloat?
    let height: CGFloat
    var radius: CGFloat = 9

    @State private var loaded: NSImage?

    private var maxPoints: CGFloat { max(width ?? height * 2, height) }
    private var key: String { Thumbnails.key(path, maxPoints: maxPoints) }

    var body: some View {
        let image = loaded ?? Thumbnails.shared.cached(key)
        return Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                DeikoStyle.wall
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius))
        // THE CLIP IS ONLY VISUAL. `.fill` makes the image larger than its
        // frame, and SwiftUI hit-tests the whole image, not the clipped part:
        // a tall screenshot reached a hundred points above its card and took
        // the hover and the clicks meant for the card above it.
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
        )
        .accessibilityHidden(true)
        .task(id: key) { loaded = await Thumbnails.shared.image(path, maxPoints: maxPoints) }
    }
}
