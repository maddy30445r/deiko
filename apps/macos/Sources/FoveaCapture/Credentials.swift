import Foundation

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
    /// survive — Node needs them — and layers the credentials on top.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for name in names {
            if let value = value(for: name) { env[name] = value }
        }
        return env
    }

    /// Where a key comes from, in order.
    ///
    /// The `.env` fallback is what keeps a developer's bundled-layout build
    /// working before the Settings window exists, and it reads the file beside
    /// the app rather than inside it — a credential must never be copied into
    /// something that gets signed, notarised and handed to somebody else.
    static func value(for name: String) -> String? {
        if let fromProcess = ProcessInfo.processInfo.environment[name], !fromProcess.isEmpty {
            return fromProcess
        }
        return dotEnv()[name]
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
