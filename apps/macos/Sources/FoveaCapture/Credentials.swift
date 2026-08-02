import Foundation
import Security

// ─────────────────────────────────────────────────────────────────────────────
// THE KEYS THE PIPELINE NEEDS
//
// `SARVAM_API_KEY` is required to transcribe; `GROQ_API_KEY` is optional and
// only powers the orb's three-line reading. In a checkout both come from the
// repo's `.env`, which the login shell sources — a shipped app has no checkout
// and no `.env`.
//
// This is the ONE place that answers "what environment does the Node child
// get", so moving the answer to the Keychain later changes this file and
// nothing else.
// ─────────────────────────────────────────────────────────────────────────────

enum Credentials {

    /// The keys Fovea passes through. Named explicitly rather than forwarding
    /// the whole environment: a child process that needs two API keys should
    /// receive two API keys, not everything this app happens to be holding.
    static let names = ["SARVAM_API_KEY", "GROQ_API_KEY"]

    /// The environment for a spawned pipeline script.
    ///
    /// Starts from this process's own environment so PATH, HOME and TMPDIR
    /// survive — Node needs them — and layers on the credentials plus the one
    /// thing the pipeline cannot work out for itself.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for name in names {
            if let value = value(for: name) { env[name] = value }
        }
        // WHERE THE APP IS. `transcribe.mjs` relaunches Fovea through
        // LaunchServices to get on-device word timings — TCC blames the
        // responsible process, so the request has to come from the app itself
        // rather than from node. It used to find the app by walking up from the
        // script, which is right in a checkout and wrong in a bundle, where it
        // resolves to `Contents/Resources/build/Fovea.app`. Telling it removes
        // the guess.
        env["FOVEA_APP_PATH"] = Bundle.main.bundleURL.path

        // THE DEFAULT PATH FOR SOMEBODY WHO HAS NO KEYS.
        //
        // Passed unconditionally: the scripts prefer a real key when one is
        // set, so a developer with their own Sarvam key never touches the
        // relay, and everybody else transcribes without holding an account
        // anywhere. Absent both, they still get a brief from on-device words.
        if let relay = relayURL {
            env["FOVEA_RELAY_URL"] = relay
            env["FOVEA_RELAY_TOKEN"] = deviceToken()
        }
        return env
    }

    /// Where Fovea's transcription service lives, or nil when this build has
    /// none — which is the state until it is actually deployed. `FOVEA_RELAY_URL`
    /// in the environment overrides it, which is how the relay is tested against
    /// a local server.
    static var relayURL: String? {
        if let override = ProcessInfo.processInfo.environment["FOVEA_RELAY_URL"],
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
        let configured = Bundle.main.object(forInfoDictionaryKey: "FoveaRelayURL") as? String
        guard let configured, !configured.isEmpty else { return nil }
        return configured
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
        // Losing the old value costs nothing. The token identifies an install
        // for rate-limiting, and a new install is what a re-minted token looks
        // like — there is no server-side state keyed to it beyond a warm
        // container's counter.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
        ] as CFDictionary)
        return minted
    }

    private static let tokenKey = "FOVEA_DEVICE_TOKEN"

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
    /// "Sarvam: from your login keychain · Groq: not set". A developer whose
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

    private static let service = "com.fovea.capture"

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
