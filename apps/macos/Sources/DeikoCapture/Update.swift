import AppKit
import Foundation

/// Checks for a newer release and offers to open the download page. It notifies; it never installs.
///
/// One GET at launch for a static `version.json` beside the DMG on the site, not the GitHub releases API,
/// which is a second place to publish and rate-limits unauthenticated callers per IP. Swap for Sparkle if
/// releases become frequent enough that users lag.
@MainActor
enum Update {

    struct Release: Sendable {
        let version: String
        let page: URL
    }

    /// Nil until the check finishes, and nil forever when this build is current
    /// or the check failed. The menu reads it; nothing waits on it.
    private(set) static var available: Release?

    /// The site to check, or nil when this build has none. Resolved by `Credentials.siteURL` so this
    /// check, the licence card's links and the review panel's "Get Pro" agree.
    private static var siteURL: URL? { Credentials.siteURL }

    /// Ask once, at launch. Failure is silence: no site, no network, a malformed file or a release
    /// with no version all mean "carry on".
    static func check() async {
        guard let site = siteURL,
              let mine = semver(DeikoVersion.current)
        else { return }

        var request = URLRequest(
            url: site.appendingPathComponent("download/version.json")
        )
        // Short, because nothing depends on the answer.
        request.timeoutInterval = 10
        // The file is small and changes on release; a cached copy would report a stale version.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(Published.self, from: data),
              let theirs = semver(latest.version),
              mine.lexicographicallyPrecedes(theirs)
        else { return }

        available = Release(
            version: latest.version,
            page: latest.url ?? site
        )
    }

    static func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.page)
    }

    /// `download/version.json`. `url` is optional; the site root is the fallback.
    private struct Published: Decodable {
        let version: String
        let url: URL?
    }

    /// `v0.4.0` or `0.4.0` → `[0, 4, 0]`, and nil for anything else.
    ///
    /// Compared as numbers, not text (`"0.10.0" < "0.9.0"` as strings). Nil for `0.0.0-dev`, what a
    /// SwiftPM binary run from `.build` reports, so a checkout never offers to update itself.
    ///
    /// Untested: `main.swift` is top-level code, so linking `DeikoCapture` into a test binary would run the app.
    private static func semver(_ text: String) -> [Int]? {
        let parts = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = parts.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        return numbers.compactMap { $0 }
    }
}
