import AppKit
import ImageIO
import SwiftUI

/// Decodes crop thumbnails once, downsampled, and caches them.
///
/// `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode straight to the requested size, so a large
/// Retina PNG never exists in memory at full size. Deliberately not observable: each `CropThumbnail`
/// awaits its own image, which avoids redraw loops when the cache evicts on a large board.
@MainActor
final class Thumbnails {

    static let shared = Thumbnails()

    /// Keyed by path and size: the dashboard's 96pt tiles and the board's 210pt cards are different
    /// images of the same file.
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

    /// The cached image, so a card drawn before shows it on its first frame.
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

    /// `nonisolated` so the decode runs off the main actor.
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

/// One crop, at the size it is actually drawn. The placeholder is the wall rather than a spinner,
/// which would mostly be a flash.
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
        // The clip is visual only: `.fill` makes the image larger than its frame and SwiftUI
        // hit-tests the whole image, so the content shape must match the frame.
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(DeikoStyle.hairline, lineWidth: 1)
        )
        .accessibilityHidden(true)
        .task(id: key) { loaded = await Thumbnails.shared.image(path, maxPoints: maxPoints) }
    }
}
