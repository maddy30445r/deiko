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
        return env
    }

    /// Where a key comes from, in order.
    ///
    /// The `.env` fallback comes LAST and reads the file beside the app, never
    /// inside it — a credential must never be copied into something that gets
    /// signed, notarised and handed to somebody else. It exists so a developer's
    /// checkout keeps working untouched; a shipped app has no such file and
    /// falls through to the keychain.
    static func value(for name: String) -> String? {
        if let fromProcess = ProcessInfo.processInfo.environment[name], !fromProcess.isEmpty {
            return fromProcess
        }
        if let fromKeychain = keychainRead(name), !fromKeychain.isEmpty {
            return fromKeychain
        }
        return dotEnv()[name]
    }

    /// Human-readable provenance, for the Settings window. A developer whose
    /// `.env` already works should not be told to type a key they have.
    static func sourceDescription() -> String {
        if ProcessInfo.processInfo.environment["SARVAM_API_KEY"]?.isEmpty == false {
            return "Using SARVAM_API_KEY from this process's environment."
        }
        if keychainRead("SARVAM_API_KEY")?.isEmpty == false {
            return "Stored in your login keychain."
        }
        if dotEnv()["SARVAM_API_KEY"] != nil {
            return "Using the .env beside the app. Saving here moves it to your keychain."
        }
        return "No Sarvam key yet — transcription will not run without one."
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
        guard !trimmed.isEmpty else { return }
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
