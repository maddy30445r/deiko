import CryptoKit
import DeikoHandoff
import Foundation
import IOKit
import Security

// The credentials the pipeline needs. `GROQ_API_KEY` is the only one: Whisper
// transcribes and the same key powers the orb's three-line reading. In a
// checkout it can come from `.env`; a shipped app has no `.env` and reads the
// keychain.
//
// This is the one place that answers "what environment does the Node child
// get".

enum Credentials {

    /// The keys Deiko passes through, named explicitly rather than forwarding the
    /// whole environment: a child process that needs one API key should receive
    /// one, not everything this app is holding.
    ///
    /// One key covers both transcription and the summary, so bringing your own
    /// means that audio and its transcription skip Deiko's relay. Sorting, while
    /// on, still goes through the relay regardless of a key.
    static let names = ["GROQ_API_KEY"]

    /// The environment for a spawned pipeline script.
    ///
    /// Starts from this process's own environment so PATH, HOME and TMPDIR
    /// survive — Node needs them — and layers on the credentials plus the one
    /// thing the pipeline cannot work out for itself.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Not Node's loader settings: the scripts run with this app's Screen
        // Recording, Microphone and Accessibility grants, and
        // `NODE_OPTIONS=--require …` (set by a login shell, or by anything that
        // can launch this app) would load arbitrary code into every one.
        // `NODE_EXTRA_CA_CERTS` stays: behind a company proxy it is how the
        // relay is reachable at all.
        for name in ["NODE_OPTIONS", "NODE_PATH"] { env[name] = nil }

        // Bringing your own key is free, so one is passed whenever there is one
        // to pass. A key never reaches the relay for transcription:
        // `DEIKO_RELAY_URL` below is withheld while one is in use, though
        // `DEIKO_CLASSIFY_URL` still goes out for sorting while that is on.
        //
        // `willUse` asks an attributes-only question, so nobody without a key
        // pays a keychain decrypt or sees a password prompt.
        for name in names where willUse(name) {
            if let value = value(for: name) { env[name] = value }
        }
        // Where the app is. `transcribe.mjs` relaunches Deiko through
        // LaunchServices to get on-device word timings (TCC blames the
        // responsible process, so the request must come from the app, not from
        // node). Walking up from the script is right in a checkout and wrong in
        // a bundle, so the path is passed explicitly.
        env["DEIKO_APP_PATH"] = Bundle.main.bundleURL.path
        // The two language settings; see Narration.swift.
        env["DEIKO_NARRATION"] = Narration.selected.rawValue
        env["DEIKO_SPEECH_LOCALE"] = SpeechLocale.selected

        // The relay is the default path for somebody with no key, and only
        // them: one key covers transcription and the summary, so the URL is
        // withheld whenever a key is in use.
        //
        // The token is `License.bearerToken()` rather than the device token, so
        // a paying install sends `lic_…` and everybody else `dev_…`. The relay
        // cannot tell the two apart by shape.
        if let relay = relayURL, !willUse("GROQ_API_KEY") {
            env["DEIKO_RELAY_URL"] = relay
            env["DEIKO_RELAY_TOKEN"] = License.bearerToken()
        }
        // Sorting is not transcription: a brief is placed in its task through the
        // relay whoever transcribed it, so own-key users keep their memory. It
        // uses its own names so `transcribe.mjs` and `summarize.mjs`, which route
        // through DEIKO_RELAY_URL when it is set, never see a relay for somebody
        // using their own key. Only while "Sort briefs into tasks" is on; see
        // `Sorting`.
        return Sorting.environment(env, relay: relayURL, on: sortsBriefs, token: License.bearerToken)
    }

    /// "Sort briefs into tasks" in Settings — on unless somebody turned it
    /// off. `bool(forKey:)` rather than `as? Bool`: `defaults write … 0` stores
    /// a string, and read as "never set" that would leave the switch on.
    static let sortBriefsKey = "DEIKO_SORT_BRIEFS"

    static var sortsBriefs: Bool {
        UserDefaults.standard.object(forKey: sortBriefsKey) == nil
            || UserDefaults.standard.bool(forKey: sortBriefsKey)
    }

    /// Whether a brief's words go to the relay to be filed: sorting is on and
    /// there is a relay to sort through. What every sentence about filing asks.
    static var filesBriefs: Bool { sortsBriefs && relayURL != nil }

    /// Where Deiko's transcription service lives, or nil when this build has
    /// none. `DEIKO_RELAY_URL` in the environment overrides it, which is how the
    /// relay is tested against a local server.
    static var relayURL: String? {
        if let override = ProcessInfo.processInfo.environment["DEIKO_RELAY_URL"],
           !override.isEmpty {
            return override
        }
        return defaultRelayURL
    }

    /// Read from the bundle, stamped there by `make bundle RELAY_URL=…`, so no
    /// source literal has to be edited before each release. Empty means there is
    /// no relay and sessions fall back to on-device words, which beats pointing
    /// at a host that does not answer: the fallback is silent, and a relay that
    /// 404s on every session is not.
    private static var defaultRelayURL: String? {
        let configured = Bundle.main.object(forInfoDictionaryKey: "DeikoRelayURL") as? String
        guard let configured, !configured.isEmpty else { return nil }
        return configured
    }

    /// Where the site is, or nil when this build has none. Used by the update
    /// check, the licence card's links and the review panel's "Get Pro". Same
    /// shape as `relayURL`: stamped by `make bundle SITE_URL=…`, overridable from
    /// the environment.
    static var siteURL: URL? {
        configuredURL(env: "DEIKO_SITE_URL", plist: "DeikoSiteURL")
    }

    /// Where somebody buys Pro, or nil. Its own key rather than `siteURL` +
    /// "/buy": a button derived from the site URL would appear in a build where
    /// the link cannot work. Nil hides every buy affordance.
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
    /// Not authentication: a token that ships inside a client can be read out of
    /// it. What it buys is the ability to stop one abusive install without
    /// stopping everybody.
    ///
    /// Deliberately not in the keychain. A keychain read decrypts, which is
    /// checked against an ACL pinned to one exact cdhash; every app update mints
    /// a new one, so every user would get a login-password prompt on the first
    /// session after each update. This is an identifier, not a secret, so it is
    /// not worth that prompt.
    static func deviceToken() -> String {
        // Environment first, as everywhere else here, so a test run can pin a
        // token without touching the user's real one.
        if let fromProcess = ProcessInfo.processInfo.environment[tokenKey],
           !fromProcess.isEmpty {
            return fromProcess
        }
        // The machine, not the preferences file. See `hardwareIdentifier`.
        if let derived = hardwareIdentifier() { return derived }

        // Nothing to derive from (a VM, or hardware that stops answering): fall
        // back to a stored random id.
        if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        UserDefaults.standard.set(minted, forKey: tokenKey)
        // Clear any old keychain item on the way past. `SecItemDelete` does not
        // decrypt, so it cannot prompt. The token is minted afresh rather than
        // migrated: reading the old one would cause the prompt this avoids.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
        ] as CFDictionary)
        return minted
    }

    private static let tokenKey = "DEIKO_DEVICE_TOKEN"

    /// This Mac, as a number that cannot be turned back into this Mac. It keys
    /// the free trial to the hardware, so resetting preferences or adding a
    /// macOS login does not grant another.
    ///
    /// A stable machine-derived identifier is more identifying than a random
    /// per-install one, so:
    ///
    ///   - the raw `IOPlatformUUID` is never stored, written or sent; only the
    ///     digest leaves this function;
    ///   - it is salted, so the digest cannot be lined up against another
    ///     product that fingerprints the same Mac. The salt ships in the app, so
    ///     this defeats correlation by a third party, not by Deiko;
    ///   - it identifies a machine, not a person: there is no account or email.
    ///
    /// Returns nil rather than trapping when IOKit has nothing to say (a VM, or
    /// hardware that answers differently one day); the caller falls back.
    private static func hardwareIdentifier() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String, !property.isEmpty else { return nil }

        // Versioned, so changing what is hashed is a deliberate act (every
        // install becomes a new subject) rather than something a refactor does.
        let salt = "deiko.device.v1:"
        let digest = SHA256.hash(data: Data((salt + property).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // Half a SHA-256 is 128 bits: far past any collision concern for a
        // population of Macs, and short enough to read in a log line.
        return String(hex.prefix(32))
    }

    /// Where a key comes from, in order. The `.env` fallback comes last and
    /// reads the file beside the app, never inside it: a credential must never
    /// be copied into something that gets signed and distributed. It keeps a
    /// developer's checkout working; a shipped app has no such file and falls
    /// through to the keychain.
    ///
    /// **This one decrypts, so it can prompt.** Call it only when the value is
    /// needed (spawning the pipeline). To know whether a key is set, use
    /// `exists(_:)`.
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

    /// Will the pipeline actually use this key? The single source of truth:
    /// `childEnvironment()` asks it to decide what to pass and Settings asks it
    /// to decide what to say, so the two cannot disagree about whether audio
    /// leaves this Mac. A stored key is a used key.
    ///
    /// Asks only `exists`-style questions, so it never decrypts and never
    /// prompts.
    static func willUse(_ name: String) -> Bool { exists(name) }

    /// Is a key set, without decrypting it and therefore without a prompt.
    ///
    /// A keychain item's ciphertext is guarded by an ACL whose partition list
    /// pins one exact cdhash, so every rebuild or update invalidates it and
    /// macOS demands the login password. An attributes-only query decrypts
    /// nothing and is never challenged, so Settings and first-run can say "a key
    /// is stored" without a prompt.
    static func exists(_ name: String) -> Bool {
        if ProcessInfo.processInfo.environment[name]?.isEmpty == false { return true }
        if cache.read(name) != nil { return true }
        if inKeychain(name) { return true }
        return dotEnv()[name]?.isEmpty == false
    }

    /// Is there a keychain item for this key, without decrypting it?
    /// Attributes, not data: adding `kSecReturnData` would bring the password
    /// prompt back for every caller.
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

    /// Where one key comes from, for the Settings window's per-key line
    /// ("Groq: from your login keychain"). Asks `exists`-style questions only:
    /// opening Settings must never trigger a keychain password prompt.
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
        // `WhenUnlocked` is the tightest class that always works while the
        // pipeline runs: no prompt, and the item never leaves this Mac.
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
