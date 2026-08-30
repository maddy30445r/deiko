import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// IS THERE A NEWER DEIKO
//
// Every build shipped before this one is PERMANENT: there was no update path at
// all, so a bug fixed today never reaches the copy somebody installed last week
// unless they happen to come back and look. That is tolerable for three
// teammates and not for a stranger, so this ships before any stranger installs.
//
// It NOTIFIES, it does not install. One GET at launch, and a menu item that
// opens the download page if there is something newer. No appcast, no signing
// key, no framework, no background daemon, nothing that can corrupt an install
// halfway through.
//
// The answer is a static `version.json` beside the DMG on the site — NOT the
// GitHub releases API, which would be free bandwidth but is a second place to
// publish and rate-limits unauthenticated callers at 60/hour PER IP. A team
// behind one NAT would share that budget for a check that must never fail
// loudly.
//
// ponytail: notify-and-open, not silent install. Swap for Sparkle when shipping
// often enough that users lag — Sparkle needs a Developer ID to be worth
// anything anyway, so it belongs with notarisation and not before it.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum Update {

    struct Release: Sendable {
        let version: String
        let page: URL
    }

    /// Nil until the check finishes, and nil forever when this build is current
    /// or the check failed. The menu reads it; nothing waits on it.
    private(set) static var available: Release?

    /// Where the site lives, or nil when this build has none — which is the
    /// state until a domain exists. `DEIKO_SITE_URL` in the environment
    /// overrides it, which is how this gets tested against a local file server.
    ///
    /// The same shape as `Credentials.relayURL`, for the same reason: a constant
    /// that has to be edited before every release is a constant that is wrong in
    /// somebody's local build.
    private static var siteURL: URL? {
        let override = ProcessInfo.processInfo.environment["DEIKO_SITE_URL"]
        let configured = override?.isEmpty == false
            ? override
            : Bundle.main.object(forInfoDictionaryKey: "DeikoSiteURL") as? String
        guard let configured, !configured.isEmpty else { return nil }
        return URL(string: configured)
    }

    /// Ask once, at launch.
    ///
    /// Failure is silence. No site configured, no network, a malformed file or a
    /// release with no version all mean "carry on" — an app that interrupts a
    /// developer to report that it could not check for updates has made their
    /// day worse to no purpose.
    static func check() async {
        guard let site = siteURL,
              let mine = semver(DeikoVersion.current)
        else { return }

        var request = URLRequest(
            url: site.appendingPathComponent("download/version.json")
        )
        // Short, because nothing depends on the answer. The default 60s would
        // keep a task alive long after the user has stopped caring.
        request.timeoutInterval = 10
        // The file is small and changes on release; a cached copy would keep
        // reporting the version that was current when the app last checked.
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

    /// `download/version.json`. `url` is optional so the file can stay a single
    /// line — the site's own root is a fine place to send somebody.
    private struct Published: Decodable {
        let version: String
        let url: URL?
    }

    /// `v0.4.0` or `0.4.0` → `[0, 4, 0]`, and nil for anything else.
    ///
    /// Compared as NUMBERS, not as text: `"0.10.0" < "0.9.0"` is true as
    /// strings and false as versions, and that bug only appears at the tenth
    /// release — long after anybody is still looking at this code.
    ///
    /// Nil for `0.0.0-dev`, which is what `DeikoVersion` reports for a SwiftPM
    /// binary run straight out of `.build`. So a checkout never offers to update
    /// itself, and that falls out of the parse rather than needing its own case.
    ///
    /// ponytail: no unit test, because this target is not testable — `main.swift`
    /// is top-level code that dispatches on load, so linking `DeikoCapture` into
    /// a test binary would RUN the app. That is why every pure decision layer in
    /// this package lives in its own target. One function does not earn a target;
    /// the trap cases (`0.10.0` vs `0.9.0`, the `v` prefix, `0.0.0-dev`,
    /// unparseable versions) were checked by hand against this exact code, and
    /// the worst failure is one wrong menu item. Move it out and test it properly
    /// if it ever grows a second caller.
    private static func semver(_ text: String) -> [Int]? {
        let parts = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = parts.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        return numbers.compactMap { $0 }
    }
}
