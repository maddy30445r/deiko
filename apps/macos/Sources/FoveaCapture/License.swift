import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE LICENCE — WHICH IS NOT AN ACCOUNT
//
// A key, pasted into Settings, sent to the relay as the bearer token. There is
// no sign-in, no password, no email in our systems, no session to expire. The
// only thing Fovea knows about a paying user is a string they gave it, and the
// only thing the relay does with that string is ask Lemon Squeezy whether it is
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
// WHAT THIS FILE DELIBERATELY DOES NOT DO: activate/deactivate against Lemon
// Squeezy's instance API, and therefore does not enforce a per-licence device
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

    private static let keyName = "FOVEA_LICENSE_KEY"
    private static let tierName = "FOVEA_LICENSE_TIER"
    private static let checkedName = "FOVEA_LICENSE_CHECKED_AT"

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
            return
        }
        defaults.set(trimmed, forKey: keyName)
        // The tier is NOT assumed here. Whether this key is worth anything is
        // the relay's answer, and `refresh()` is what asks.
        defaults.removeObject(forKey: tierName)
        defaults.removeObject(forKey: checkedName)
    }

    // ── What the relay is told ──────────────────────────────────────────────

    /// The bearer the pipeline sends.
    ///
    /// THE PREFIX IS LOAD-BEARING. A Lemon Squeezy key and a Fovea device token
    /// are both v4-shaped UUIDs, so without it the relay cannot tell them
    /// apart — it would send every free user's token to Lemon Squeezy for
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
    /// This gates ONE thing — whether the Sarvam and Groq boxes in Settings are
    /// editable — and nothing else, because everything on the paid path is
    /// decided by the relay per request. A developer on a plane must not find
    /// their own API key has become read-only.
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

    struct Quota: Sendable {
        let tier: String
        let usedSeconds: Int
        let capSeconds: Int
        let remainingSeconds: Int

        var isPro: Bool { tier == "pro" }

        /// "4 hours 12 minutes left this month" — the sentence Settings shows.
        var remainingSentence: String {
            let minutes = remainingSeconds / 60
            if minutes >= 60 {
                let hours = minutes / 60
                let rest = minutes % 60
                return rest == 0
                    ? "\(hours) hour\(hours == 1 ? "" : "s") left"
                    : "\(hours)h \(rest)m left"
            }
            if minutes > 0 { return "\(minutes) minute\(minutes == 1 ? "" : "s") left" }
            return "nothing left"
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

        var request = URLRequest(url: base.appendingPathComponent("v1/quota"))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bearerToken())", forHTTPHeaderField: "Authorization")

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

        // Cached only when there is a key to cache it against. A free install
        // re-asks every time, which costs one request and keeps `isPro` from
        // ever being true for a reason nobody can explain.
        if key != nil {
            UserDefaults.standard.set(quota.tier, forKey: tierName)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkedName)
        }
        return quota
    }

    private struct Wire: Decodable {
        let tier: String
        let usedSeconds: Int
        let capSeconds: Int
        let remainingSeconds: Int
    }
}
