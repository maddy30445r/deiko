import CryptoKit
import Foundation
import IOKit
import Security

// ─────────────────────────────────────────────────────────────────────────────
// THE KEYS THE PIPELINE NEEDS
//
// `GROQ_API_KEY` is the only one: Whisper transcribes and the same key powers
// the orb's three-line reading. In a checkout it comes from the repo's `.env`,
// which the login shell sources — a shipped app has no checkout and no `.env`.
//
// This is the ONE place that answers "what environment does the Node child
// get", so moving the answer to the Keychain later changes this file and
// nothing else.
// ─────────────────────────────────────────────────────────────────────────────

enum Credentials {

    /// The key Deiko passes through. Named explicitly rather than forwarding
    /// the whole environment: a child process that needs one API key should
    /// receive one API key, not everything this app happens to be holding.
    ///
    /// ONE KEY. It was two — Sarvam for the words, Groq for the summary — until
    /// Whisper replaced Sarvam and took over both. A single name is what makes
    /// "bring your own key and Deiko's servers see nothing" a statement with no
    /// half-configured state hiding inside it.
    static let names = ["GROQ_API_KEY"]

    /// The environment for a spawned pipeline script.
    ///
    /// Starts from this process's own environment so PATH, HOME and TMPDIR
    /// survive — Node needs them — and layers on the credentials plus the one
    /// thing the pipeline cannot work out for itself.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // BRINGING YOUR OWN KEY IS FREE, so this passes one whenever there is
        // one to pass. It was gated on a licence until the vendor changed: the
        // gate existed to keep heavy users inside Pro, and at Groq's price a
        // licence pinning the whole monthly cap still earns more than it costs,
        // so there was nothing left for it to protect. A key also never reaches
        // the relay — the URL below is withheld while one is in use — so a free
        // caller who brings one spends no quota of ours either.
        //
        // Nobody without a key pays a keychain DECRYPT here: `willUse` asks an
        // attributes-only question, so there is no password prompt for the
        // people who have nothing stored.
        for name in names where willUse(name) {
            if let value = value(for: name) { env[name] = value }
        }
        // WHERE THE APP IS. `transcribe.mjs` relaunches Deiko through
        // LaunchServices to get on-device word timings — TCC blames the
        // responsible process, so the request has to come from the app itself
        // rather than from node. It used to find the app by walking up from the
        // script, which is right in a checkout and wrong in a bundle, where it
        // resolves to `Contents/Resources/build/Deiko.app`. Telling it removes
        // the guess.
        env["DEIKO_APP_PATH"] = Bundle.main.bundleURL.path
        // The two language settings — see Narration.swift for what each does.
        env["DEIKO_NARRATION"] = Narration.selected.rawValue
        env["DEIKO_SPEECH_LOCALE"] = SpeechLocale.selected

        // THE DEFAULT PATH FOR SOMEBODY WHO HAS NO KEYS — AND ONLY THEM.
        //
        // This used to be passed unconditionally, on the reasoning that the
        // scripts prefer a real key when one is set. That was true of the audio
        // and false of the summary: back when transcription was Sarvam and the
        // summary was Groq, somebody who brought only the transcription key
        // still sent every session's narration as text to our Lambda — while
        // Settings told them "Deiko's servers never see it". One key covers
        // both now, and the URL is simply withheld when it is in use, so the
        // sentence is true with no half-configured state left to be wrong in.
        //
        // The token is `License.bearerToken()` rather than the device token
        // directly, so a paying install sends `lic_…` and everybody else sends
        // `dev_…`. The relay cannot tell the two apart by shape — both are
        // v4-shaped UUIDs — and gets it wrong in both directions if it tries.
        if let relay = relayURL, !willUse("GROQ_API_KEY") {
            env["DEIKO_RELAY_URL"] = relay
            env["DEIKO_RELAY_TOKEN"] = License.bearerToken()
        }
        // SORTING IS NOT TRANSCRIPTION. A brief is placed in its task through
        // the relay whoever transcribed it — the owner decided own-key users
        // keep their memory. Its own names, so `transcribe.mjs` and
        // `summarize.mjs`, which route through DEIKO_RELAY_URL when it is set,
        // still never see a relay for somebody using their own key.
        if let relay = relayURL {
            env["DEIKO_CLASSIFY_URL"] = relay
            env["DEIKO_CLASSIFY_TOKEN"] = License.bearerToken()
        }
        return env
    }

    /// Where Deiko's transcription service lives, or nil when this build has
    /// none — which is the state until it is actually deployed. `DEIKO_RELAY_URL`
    /// in the environment overrides it, which is how the relay is tested against
    /// a local server.
    static var relayURL: String? {
        if let override = ProcessInfo.processInfo.environment["DEIKO_RELAY_URL"],
           !override.isEmpty {
            return override
        }
        return defaultRelayURL
    }

    /// Read from the bundle, stamped there by `make bundle RELAY_URL=…`.
    ///
    /// Deployment configuration rather than a source literal, for the same
    /// reason the version is: a constant that has to be edited before every
    /// release is a constant that is wrong in somebody's local build. Empty
    /// means there is no relay, and sessions fall back to on-device words —
    /// which is correct for a local build and for any release cut before the
    /// service exists. Better than pointing at a host that does not answer:
    /// the fallback is silent, and a relay that 404s on every session is not.
    private static var defaultRelayURL: String? {
        let configured = Bundle.main.object(forInfoDictionaryKey: "DeikoRelayURL") as? String
        guard let configured, !configured.isEmpty else { return nil }
        return configured
    }

    /// Where the site is, or nil when this build has none.
    ///
    /// Lives here rather than in `Update`, which owned it first, because three
    /// things now ask: the update check, the licence card's links, and the
    /// review panel's "Get Pro". Same shape and same reasoning as `relayURL` —
    /// stamped by `make bundle SITE_URL=…`, overridable from the environment so
    /// it can be pointed at a local file server.
    static var siteURL: URL? {
        configuredURL(env: "DEIKO_SITE_URL", plist: "DeikoSiteURL")
    }

    /// Where somebody buys Pro, or nil.
    ///
    /// ITS OWN KEY, not `siteURL` + "/buy", and the distinction is not
    /// pedantry: as this ships, the stamped site answers 404 on every path
    /// including the one the update check reads. A button derived from a site
    /// URL would therefore appear in a build where it cannot work, and a
    /// purchase link that 404s is worse than no purchase link — it reads as a
    /// broken product at the exact moment somebody decided to pay. Nil hides
    /// every buy affordance instead, so the button appears when there is
    /// something behind it and not before.
    static var buyURL: URL? {
        configuredURL(env: "DEIKO_BUY_URL", plist: "DeikoBuyURL")
    }

    /// Where a bug report goes. Nil hides the menu item, for the same reason.
    static var supportEmail: String? {
        let override = ProcessInfo.processInfo.environment["DEIKO_SUPPORT_EMAIL"]
        let configured = override?.isEmpty == false
            ? override
            : Bundle.main.object(forInfoDictionaryKey: "DeikoSupportEmail") as? String
        guard let configured, !configured.isEmpty else { return nil }
        return configured
    }

    /// Environment first, then the bundle — the pattern every stamped URL uses.
    private static func configuredURL(env: String, plist: String) -> URL? {
        let override = ProcessInfo.processInfo.environment[env]
        let configured = override?.isEmpty == false
            ? override
            : Bundle.main.object(forInfoDictionaryKey: plist) as? String
        guard let configured, !configured.isEmpty else { return nil }
        return URL(string: configured)
    }

    /// An opaque per-install identifier, so the service can rate-limit and
    /// revoke without knowing anything about who is calling.
    ///
    /// Not authentication, and not described as such: a token that ships inside
    /// a client can be read out of it by anyone who wants to. What it buys is
    /// the ability to stop one abusive install without stopping everybody.
    /// Real per-user identity means accounts, which is a product decision, not
    /// a line of code.
    ///
    /// NOT IN THE KEYCHAIN, and that is the point. This used to be stored
    /// beside the API keys, which meant every session read it back — and a
    /// keychain read DECRYPTS, which is checked against an ACL that pins one
    /// exact cdhash. Every app update mints a new cdhash, so every user got a
    /// login-password prompt on their first session after every update, at the
    /// worst possible moment: after they had finished talking, with the brief
    /// waiting on it. Users with no API key at all were hit too, because the
    /// relay path reads this token on every single session.
    ///
    /// The keychain was buying nothing for it. This is a random identifier, not
    /// a secret — the doc comment above says so in as many words, and anyone
    /// holding the app can read it out regardless. Protecting a non-secret with
    /// something that costs a password prompt after every update is a bad
    /// trade, so it lives in preferences and the prompt is gone.
    static func deviceToken() -> String {
        // Environment first, as everywhere else here, so a test run can pin a
        // token without touching the user's real one.
        if let fromProcess = ProcessInfo.processInfo.environment[tokenKey],
           !fromProcess.isEmpty {
            return fromProcess
        }
        // THE MACHINE, NOT THE PREFERENCES FILE. See `hardwareIdentifier`.
        if let derived = hardwareIdentifier() { return derived }

        // Nothing to derive from — a VM, or hardware that stops answering.
        // A Mac we cannot identify gets a trial rather than an error: the
        // stored random id is the pre-existing behaviour, kept exactly as it
        // was for this one case.
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        UserDefaults.standard.set(minted, forKey: tokenKey)
        // Clear the old keychain item on the way past. `SecItemDelete` does not
        // decrypt, so this cannot prompt — deleting is the one keychain
        // operation that is free here, which is also why the token is minted
        // afresh rather than migrated: reading the old one across would have
        // charged the exact prompt this change exists to remove.
        //
        // THIS USED TO SAY losing the old value costs nothing, because there
        // was no server-side state keyed to it beyond a warm container's
        // counter. That stopped being true the day the relay started metering:
        // a lifetime free-trial balance now hangs off this exact string, so a
        // re-mint is a fresh thirty minutes at our expense.
        //
        // It is still the right call HERE, because this branch only runs when
        // there was nothing to lose — the keychain item is being deleted
        // precisely because we are about to stop using it, and any Mac that
        // reaches this line had no derivable hardware id either.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
        ] as CFDictionary)
        return minted
    }

    private static let tokenKey = "DEIKO_DEVICE_TOKEN"

    /// This Mac, as a number that cannot be turned back into this Mac.
    ///
    /// The free trial is thirty minutes ONCE, and it used to be keyed to a
    /// random id in `~/Library/Preferences/com.deiko.capture.plist` — so
    /// `defaults delete` bought another thirty, and so did a second macOS
    /// login. Deriving from the hardware closes both.
    ///
    /// WHAT THIS COSTS, said out loud because the product is sold on privacy:
    /// a stable machine-derived identifier IS more identifying than a random
    /// per-install one. That is a real regression, accepted deliberately, and
    /// mitigated rather than hidden:
    ///
    ///   • the raw `IOPlatformUUID` is never stored, never written to disk and
    ///     never sent — only the digest leaves this function;
    ///   • it is SALTED, so the digest cannot be lined up against any other
    ///     product that fingerprints the same Mac. The salt ships inside the
    ///     app and is therefore readable by anyone holding it: this defeats
    ///     cross-service correlation by a third party, NOT by us. Claiming
    ///     more would be the kind of privacy theatre this file exists to avoid;
    ///   • it identifies a machine, not a person. There is still no account, no
    ///     email, and nothing here that says who you are.
    ///
    /// Returns nil rather than trapping when IOKit has nothing to say — a VM,
    /// or hardware that answers differently one day. The caller falls back.
    private static func hardwareIdentifier() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String, !property.isEmpty else { return nil }

        // Versioned, so that changing what we hash is a deliberate act with a
        // visible consequence — every install becomes a new subject — rather
        // than something that happens quietly during a refactor.
        let salt = "deiko.device.v1:"
        let digest = SHA256.hash(data: Data((salt + property).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // Half a SHA-256 is 128 bits: far past any collision concern for a
        // population of Macs, and short enough to read in a log line.
        return String(hex.prefix(32))
    }

    /// Where a key comes from, in order.
    ///
    /// The `.env` fallback comes LAST and reads the file beside the app, never
    /// inside it — a credential must never be copied into something that gets
    /// signed, notarised and handed to somebody else. It exists so a developer's
    /// checkout keeps working untouched; a shipped app has no such file and
    /// falls through to the keychain.
    ///
    /// **This one decrypts, so it can prompt.** Call it only when the value is
    /// actually needed — spawning the pipeline. Anything that merely wants to
    /// know whether a key is set should call `exists(_:)`, which does not.
    static func value(for name: String) -> String? {
        if let fromProcess = ProcessInfo.processInfo.environment[name], !fromProcess.isEmpty {
            return fromProcess
        }
        if let cached = cache.read(name) { return cached }
        if let fromKeychain = keychainRead(name), !fromKeychain.isEmpty {
            cache.write(name, fromKeychain)
            return fromKeychain
        }
        return dotEnv()[name]
    }

    /// WILL THE PIPELINE ACTUALLY USE THIS KEY?
    ///
    /// The single source of truth. `childEnvironment()` asks it to decide what
    /// to pass, and Settings asks it to decide what to say — because the rule
    /// was briefly written out in both places and they disagreed. The window
    /// told a developer whose `.env` key was live that "transcription runs on
    /// this Mac. Nothing is uploaded", which is the one sentence in this app
    /// that must never be wrong.
    ///
    /// NOT GATED ON A LICENCE ANY MORE: a stored key is a used key. It stays a
    /// function of its own, rather than callers asking `exists`, so that the
    /// pipeline and Settings keep asking ONE question if a rule ever returns.
    ///
    /// Asks only `exists`-style questions, so it never decrypts and never
    /// prompts.
    static func willUse(_ name: String) -> Bool { exists(name) }

    /// Is a key set — without decrypting it, and therefore without a prompt.
    ///
    /// THIS DISTINCTION IS THE WHOLE POINT. A keychain item's ciphertext is
    /// guarded by an ACL whose partition list pins one exact cdhash, so every
    /// rebuild (and, shipped, every update) invalidates it and macOS demands
    /// the login password. But an ATTRIBUTES-only query decrypts nothing and
    /// is never challenged — verified against a binary deliberately signed out
    /// of the ACL. So Settings and first-run, which only ever needed to say
    /// "a key is stored", now ask a question that has no password attached.
    static func exists(_ name: String) -> Bool {
        if ProcessInfo.processInfo.environment[name]?.isEmpty == false { return true }
        if cache.read(name) != nil { return true }
        if inKeychain(name) { return true }
        return dotEnv()[name]?.isEmpty == false
    }

    /// Is there a keychain item for this key — WITHOUT decrypting it?
    ///
    /// Attributes, NOT data. Adding `kSecReturnData` here would put the password
    /// prompt back for every caller, which is the whole thing `exists` and
    /// `source` exist to avoid.
    private static func inKeychain(_ name: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Decrypted values already paid for this launch, so the pipeline prompts
    /// at most once per key per launch rather than once per session.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func read(_ name: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[name]
        }

        func write(_ name: String, _ value: String) {
            lock.lock()
            defer { lock.unlock() }
            values[name] = value
        }

        func forget(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            values[name] = nil
        }
    }

    private static let cache = Cache()

    /// Where ONE key comes from, for the Settings window's per-key line —
    /// "Groq: from your login keychain". A developer whose
    /// `.env` already works should not be told to type a key they have.
    /// Asks `exists`-style questions only — opening Settings must never
    /// trigger a keychain password prompt.
    static func source(of name: String) -> String {
        if ProcessInfo.processInfo.environment[name]?.isEmpty == false {
            return "from this process's environment"
        }
        if inKeychain(name) { return "from your login keychain" }
        if dotEnv()[name]?.isEmpty == false {
            return "from the .env beside the app"
        }
        return "not set"
    }

    // ── Keychain ────────────────────────────────────────────────────────────

    private static let service = "com.deiko.capture"

    /// Store a key, or delete it when cleared.
    ///
    /// An empty box means "remove this", not "store an empty string": a stored
    /// empty value would shadow the `.env` fallback and read as a key that is
    /// present but wrong, which fails further downstream and less clearly.
    static func store(_ value: String, for name: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        cache.forget(name)
        guard !trimmed.isEmpty else { return }
        cache.write(name, trimmed)
        query[kSecValueData as String] = Data(trimmed.utf8)
        // The pipeline runs while the developer is at the machine, so
        // `WhenUnlocked` is the tightest class that always works — no prompt,
        // and the item never leaves this Mac.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func keychainRead(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parsed once. A `.env` beside the bundle, if there is one.
    private static let dotEnvCache: [String: String] = {
        let beside = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".env")
        guard let text = try? String(contentsOf: beside, encoding: .utf8) else { return [:] }

        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Shell-style quoting, since this is the same file `set -a` reads.
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }()

    private static func dotEnv() -> [String: String] { dotEnvCache }
}
