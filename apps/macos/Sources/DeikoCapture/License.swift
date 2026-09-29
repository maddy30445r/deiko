import Foundation
import os

// The licence is not an account: a key pasted into Settings, sent to the relay
// as the bearer token. There is no sign-in or session; the relay asks Polar
// whether the key is still paid for.
//
// No device binding, so no activation against Polar's activation API. The
// monthly audio cap is per licence, so a key shared across several Macs uses
// one allowance faster rather than costing more, and a device limit would
// protect nothing.

// Deliberately not `@MainActor`: `childEnvironment()` builds the pipeline's
// environment on the cooperative pool, and `MainActor.assumeIsolated` from there
// is a precondition that traps. Everything here touches only thread-safe surface
// (`UserDefaults`, `Date`, `URLSession`), as `Credentials` does, so the compiler
// checks callers instead.
enum License {

    private static let keyName = "DEIKO_LICENSE_KEY"
    private static let tierName = "DEIKO_LICENSE_TIER"
    private static let checkedName = "DEIKO_LICENSE_CHECKED_AT"
    private static let quotaName = "DEIKO_QUOTA_CACHE"

    /// The key the user pasted, or nil. Stored in the keychain beside the Groq
    /// key; a key still in preferences moves across the first time it is read.
    ///
    /// Read once per launch: a keychain miss is not cached below, so every
    /// Settings redraw and menu open would otherwise hit the keychain.
    static var key: String? {
        if let known = memo.withLock({ $0 }) { return known }
        let defaults = UserDefaults.standard
        if let old = defaults.string(forKey: keyName) {
            defaults.removeObject(forKey: keyName)
            if !old.isEmpty { Credentials.store(old, for: keyName) }
        }
        let value = Credentials.value(for: keyName)
        memo.withLock { $0 = .some(value) }
        return value
    }

    /// `key`, once read: nil until then, `.some(nil)` for "no key".
    private static let memo = OSAllocatedUnfairLock<String??>(initialState: nil)

    /// Store or clear. Clearing forgets the cached verdict too, so a removed key
    /// does not leave the app believing it is still Pro.
    static func store(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        Credentials.store(trimmed, for: keyName)
        memo.withLock { $0 = .some(trimmed.isEmpty ? nil : trimmed) }
        defaults.removeObject(forKey: keyName)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: tierName)
            defaults.removeObject(forKey: checkedName)
            defaults.removeObject(forKey: quotaName)
            return
        }
        // The tier is not assumed here: whether this key is worth anything is
        // the relay's answer, and `refresh()` asks.
        defaults.removeObject(forKey: tierName)
        defaults.removeObject(forKey: checkedName)
        // The old subject's numbers belong to the old subject; keeping them
        // would show the device token's spent trial on a freshly pasted licence
        // until the refresh lands.
        defaults.removeObject(forKey: quotaName)
    }

    /// The last answer the relay gave, for surfaces that must not make a network
    /// call to draw themselves (the menu bar rebuilds on every open).
    ///
    /// Cached for free installs too, unlike the tier: it is a readout, not an
    /// entitlement, so a stale copy never gates anything.
    static var cachedQuota: Quota? {
        get {
            guard let data = UserDefaults.standard.data(forKey: quotaName) else { return nil }
            return try? JSONDecoder().decode(Quota.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: quotaName)
                return
            }
            UserDefaults.standard.set(data, forKey: quotaName)
        }
    }

    /// The bearer the pipeline sends.
    ///
    /// The prefix is load-bearing. A Polar licence key and a Deiko device token
    /// are both v4-shaped UUIDs, so without it the relay cannot tell them apart:
    /// it would send every free user's token to Polar and meter every paying
    /// customer as a free trial. The relay still reads a bare, unprefixed value
    /// as a device token, for older builds.
    static func bearerToken() -> String {
        if let key { return "lic_\(key)" }
        return "dev_\(Credentials.deviceToken())"
    }

    /// How long a Pro verdict survives without being re-confirmed.
    ///
    /// Gates no feature; it only decides what Settings says while the relay is
    /// unreachable, so a paying customer offline does not read as Free.
    private static let graceSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Is this install entitled to the paid features the client owns?
    ///
    /// Tolerant on purpose: an unreachable relay leaves the last verdict standing
    /// for a week, so a paying user on bad wifi is never silently downgraded. The
    /// relay still decides every transcription itself.
    static var isPro: Bool {
        guard key != nil,
              UserDefaults.standard.string(forKey: tierName) == "pro"
        else { return false }
        let checkedAt = UserDefaults.standard.double(forKey: checkedName)
        guard checkedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - checkedAt < graceSeconds
    }

    struct Quota: Sendable, Codable {
        let tier: String
        let usedSeconds: Int
        let capSeconds: Int
        let remainingSeconds: Int

        var isPro: Bool { tier == "pro" }

        /// Whether there is any allowance left to spend.
        var isSpent: Bool { remainingSeconds < 60 }

        /// How full the bar is. Clamped: the relay increments a counter before
        /// judging it, so a session can end a few seconds past the cap.
        var usedFraction: Double {
            guard capSeconds > 0 else { return 0 }
            return min(1, Double(usedSeconds) / Double(capSeconds))
        }

        /// "12 min", "3h 40m", "5 hours". The one place seconds become words,
        /// so the bar's caption and the menu line agree.
        static func clock(_ seconds: Int) -> String {
            let minutes = max(0, seconds) / 60
            if minutes >= 60 {
                let hours = minutes / 60
                let rest = minutes % 60
                return rest == 0
                    ? "\(hours) hour\(hours == 1 ? "" : "s")"
                    : "\(hours)h \(rest)m"
            }
            if minutes > 0 { return "\(minutes) min" }
            return "none"
        }

        /// "3h 40m left" — what Settings and the menu line show.
        var remainingSentence: String {
            isSpent ? "nothing left" : "\(Self.clock(remainingSeconds)) left"
        }

        /// "12 min of 30 min used" — the caption under the bar.
        var usedSentence: String {
            "\(Self.clock(usedSeconds)) of \(Self.clock(capSeconds)) used"
        }

        /// "resets 1 October (UTC)".
        ///
        /// Computed here rather than asked of the relay, so it works offline.
        /// Mirrors `monthKey` in `services/relay/src/quota.mjs` (the UTC month);
        /// change both. UTC is named because the reset lands mid-afternoon for
        /// most of the world.
        static var resetSentence: String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            guard let startOfMonth = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: Date())),
                  let next = calendar.date(byAdding: .month, value: 1, to: startOfMonth)
            else { return "Resets at the start of next month (UTC)" }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "d MMMM"
            return "Resets \(formatter.string(from: next)) (UTC)"
        }
    }

    enum Failure: Error {
        /// This build has no relay, so there is nothing to ask.
        case noRelay
        case unreachable(String)
        case refused(Int)
    }

    /// Asks the relay what this install is and what is left of it. Also confirms
    /// that a pasted key worked before any session has run, which is why
    /// `/v1/quota` is a route rather than a header on a transcription response.
    @discardableResult
    static func refresh() async throws -> Quota {
        guard let relay = Credentials.relayURL, let base = URL(string: relay) else {
            throw Failure.noRelay
        }

        // Whose answer this is, captured with the request. The reply is cached
        // against this bearer, not whatever `key` is when it lands: otherwise a
        // licence pasted while a device-token request is in flight would have the
        // trial's "free" verdict written against it.
        let sentBearer = bearerToken()

        var request = URLRequest(url: base.appendingPathComponent("v1/quota"))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(sentBearer)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status) }

        let decoded = try JSONDecoder().decode(Wire.self, from: data)
        let quota = Quota(
            tier: decoded.tier,
            usedSeconds: decoded.usedSeconds,
            capSeconds: decoded.capSeconds,
            remainingSeconds: decoded.remainingSeconds,
        )

        // A reply that no longer describes this install is not cached; see
        // `sentBearer`.
        guard sentBearer == bearerToken() else { return quota }

        // The tier is cached only when there is a key to cache it against. A
        // free install re-asks every time, so `isPro` is never true for an
        // unexplained reason.
        if key != nil {
            UserDefaults.standard.set(quota.tier, forKey: tierName)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkedName)
        }
        // The numbers are cached either way; see `cachedQuota`.
        cachedQuota = quota
        return quota
    }

    private struct Wire: Decodable {
        let tier: String
        let usedSeconds: Int
        let capSeconds: Int
        let remainingSeconds: Int
    }
}
