import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE LICENCE — WHICH IS NOT AN ACCOUNT
//
// A key, pasted into Settings, sent to the relay as the bearer token. There is
// no sign-in, no password, no email in our systems, no session to expire. The
// only thing Deiko knows about a paying user is a string they gave it, and the
// only thing the relay does with that string is ask Polar whether it is
// still paid for.
//
// NOT IN THE KEYCHAIN, for the reason already written out at length in
// `Credentials.deviceToken()`: a keychain read DECRYPTS, decryption is checked
// against an ACL pinned to one exact cdhash, and every app update mints a new
// one — so a keychain-stored licence would demand the login password on the
// first session after every update, at the worst possible moment. A licence key
// is no more secret than the device token; both are readable out of any shipped
// client. Preferences, therefore, and no prompt.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO: activate/deactivate against Polar's
// activation API, and therefore does not enforce a per-licence device
// limit. That machinery exists to stop one key being shared across a team, and
// here it would protect nothing — the monthly audio cap is PER LICENCE, so four
// people sharing one key do not cost us four allowances, they exhaust one
// allowance four times faster. A device limit would be code, a stored
// instance id, and a failure mode ("this key is already on three Macs") in
// exchange for a saving of zero.
//
// ponytail: no device binding. Add it if a shared key ever turns out to cost
// something the per-licence cap does not already bound.
// ─────────────────────────────────────────────────────────────────────────────

// NOT `@MainActor`, and that is load-bearing rather than an omission.
//
// It was, briefly, and it crashed the app on every session. `childEnvironment()`
// builds the pipeline's environment on the cooperative pool, so reaching a
// main-actor `License` from there needed `MainActor.assumeIsolated` — which is
// a PRECONDITION, not a hop. It traps when the assumption is false, and it was
// false every single time: SIGTRAP in `_dispatch_assert_queue_fail`, the moment
// "Transcribing…" appeared.
//
// The annotation was never earned. Everything here touches `UserDefaults`,
// `Date` and `URLSession` — the same thread-safe surface `Credentials` reads,
// which is why that enum is nonisolated too. Dropping it means the compiler
// checks what the precondition used to assert, and a caller on the wrong actor
// is now a build error instead of a crash in front of a user.
enum License {

    // ── Storage ─────────────────────────────────────────────────────────────

    private static let keyName = "DEIKO_LICENSE_KEY"
    private static let tierName = "DEIKO_LICENSE_TIER"
    private static let checkedName = "DEIKO_LICENSE_CHECKED_AT"
    private static let quotaName = "DEIKO_QUOTA_CACHE"

    /// The key the user pasted, or nil.
    static var key: String? {
        let stored = UserDefaults.standard.string(forKey: keyName)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Store or clear. Clearing forgets the cached verdict too — a removed key
    /// must not leave the app believing it is still Pro for a week.
    static func store(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: keyName)
            defaults.removeObject(forKey: tierName)
            defaults.removeObject(forKey: checkedName)
            defaults.removeObject(forKey: quotaName)
            return
        }
        defaults.set(trimmed, forKey: keyName)
        // The tier is NOT assumed here. Whether this key is worth anything is
        // the relay's answer, and `refresh()` is what asks.
        defaults.removeObject(forKey: tierName)
        defaults.removeObject(forKey: checkedName)
        // The old subject's numbers belong to the old subject. Leaving them
        // would show the device token's spent trial on a licence that has just
        // been pasted, until the refresh lands a moment later.
        defaults.removeObject(forKey: quotaName)
    }

    /// The last answer the relay gave, for surfaces that must not make a
    /// network call to draw themselves — the menu bar rebuilds on every open.
    ///
    /// Cached for FREE installs too, unlike the tier: this is a readout, not an
    /// entitlement. Nothing is gated on it, so a stale copy costs a slightly
    /// old number on a menu line and never a wrong decision about what somebody
    /// is allowed to do.
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

    // ── What the relay is told ──────────────────────────────────────────────

    /// The bearer the pipeline sends.
    ///
    /// THE PREFIX IS LOAD-BEARING. A Polar licence key and a Deiko device token
    /// are both v4-shaped UUIDs, so without it the relay cannot tell them
    /// apart — it would send every free user's token to Polar for
    /// validation and meter every paying customer as a free trial. The relay
    /// reads a bare, unprefixed value as a device token, which is what every
    /// build up to 0.3.0 sends.
    static func bearerToken() -> String {
        if let key { return "lic_\(key)" }
        return "dev_\(Credentials.deviceToken())"
    }

    // ── What the app believes ───────────────────────────────────────────────

    /// How long a Pro verdict survives without being re-confirmed.
    ///
    /// This gates NO feature any more. The one thing the client owned was
    /// whether the key box in Settings was editable, and bringing a key is free
    /// now; everything on the paid path is decided by the relay per request.
    /// What is left is what Settings SAYS while the relay cannot be reached: a
    /// paying customer on a plane must not read as Free.
    private static let graceSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// Is this install entitled to the paid features the CLIENT owns?
    ///
    /// Deliberately tolerant: an unreachable relay leaves the last verdict
    /// standing for a week. The failure the other way — silently downgrading
    /// somebody who has paid, because their café wifi is bad — is the one worth
    /// avoiding, and it costs nothing to avoid because the relay still decides
    /// every transcription on its own.
    static var isPro: Bool {
        guard key != nil,
              UserDefaults.standard.string(forKey: tierName) == "pro"
        else { return false }
        let checkedAt = UserDefaults.standard.double(forKey: checkedName)
        guard checkedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - checkedAt < graceSeconds
    }

    // ── Asking ──────────────────────────────────────────────────────────────

    struct Quota: Sendable, Codable {
        let tier: String
        let usedSeconds: Int
        let capSeconds: Int
        let remainingSeconds: Int

        var isPro: Bool { tier == "pro" }

        /// Whether there is any allowance left to spend.
        var isSpent: Bool { remainingSeconds < 60 }

        /// How full the bar is. CLAMPED, because the relay increments a
        /// counter before it judges it — a session can legitimately end a few
        /// seconds past the cap, and a progress bar past 1.0 draws as a glitch.
        var usedFraction: Double {
            guard capSeconds > 0 else { return 0 }
            return min(1, Double(usedSeconds) / Double(capSeconds))
        }

        /// "12 min", "3h 40m", "5 hours". The ONE place a span of seconds
        /// becomes words, so the bar's caption and the menu's line cannot
        /// disagree about the same number.
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
        /// Computed here rather than asked of the relay: a Pro month's row key
        /// is the UTC month (`monthKey` in `services/relay/quota.mjs`), so the
        /// client can say the same thing without a round trip and can say it
        /// while offline. UTC is named out loud because that reset lands
        /// mid-afternoon for most of the world, and a limit that comes back at
        /// an hour nobody can predict reads as a bug.
        static var proResetSentence: String {
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

    /// Ask the relay what this install is and what is left of it.
    ///
    /// Also the confirmation that a pasted key worked: the answer is available
    /// before a session has ever run, which is the entire reason `/v1/quota` is
    /// a route rather than a header on a transcription response.
    @discardableResult
    static func refresh() async throws -> Quota {
        guard let relay = Credentials.relayURL, let base = URL(string: relay) else {
            throw Failure.noRelay
        }

        // WHOSE ANSWER THIS IS, captured with the request.
        //
        // `bearerToken()` is read when the request goes out, but the caching
        // below used to re-read `key` when the reply came back — a 10-second
        // window in which the user can paste a licence. Settings opens, asks as
        // the device token, the network is slow; the user pastes a valid Pro key
        // and Applies; that second call returns "pro" and caches it; then the
        // FIRST reply lands, sees a key is now present, and writes the device
        // trial's "free" verdict against the licence. The result is a paid key
        // reading "that key is not active", with the BYO fields disabled, until
        // something asks again.
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

        // A REPLY THAT NO LONGER DESCRIBES THIS INSTALL IS NOT CACHED. The
        // subject can have changed while this was in flight — see `sentBearer`
        // — and an answer about the previous one is worse than no answer.
        guard sentBearer == bearerToken() else { return quota }

        // The TIER is cached only when there is a key to cache it against. A
        // free install re-asks every time, which costs one request and keeps
        // `isPro` from ever being true for a reason nobody can explain.
        if key != nil {
            UserDefaults.standard.set(quota.tier, forKey: tierName)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkedName)
        }
        // The NUMBERS are cached either way — see `cachedQuota`. A free
        // install's remaining trial is exactly what the menu line exists to
        // show, and it gates nothing.
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
