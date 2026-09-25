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

@MainActor
final class Thumbnails: ObservableObject {

    static let shared = Thumbnails()

    /// Keyed by path AND size: the dashboard's 96pt tiles and the board's
    /// 210pt cards are different images of the same file.
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    /// Oldest first, so the cap evicts what was drawn longest ago.
    private var order: [String] = []

    /// About a screenful of board at any reasonable window size. A real LRU
    /// would track use rather than arrival; this is a cap, not a cache policy,
    /// and the cost of a miss is one downsample.
    // ponytail: FIFO cap, make it an LRU if profiling ever says it matters
    private let limit = 240

    /// The thumbnail if we have it; otherwise nil, and a decode is started.
    /// Callers re-render when it lands, because this is an ObservableObject.
    func image(_ path: String, maxPoints: CGFloat) -> NSImage? {
        let pixels = maxPoints * (NSScreen.main?.backingScaleFactor ?? 2)
        let key = "\(path)#\(Int(pixels))"
        if let hit = cache[key] { return hit }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        Task {
            let image = await Self.decode(path: path, pixels: pixels)
            inFlight.remove(key)
            guard let image else { return }
            cache[key] = image
            order.append(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            objectWillChange.send()
        }
        return nil
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

    @ObservedObject private var thumbnails = Thumbnails.shared

    var body: some View {
        let image = thumbnails.image(path, maxPoints: max(width ?? height * 2, height))
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
    }
}
