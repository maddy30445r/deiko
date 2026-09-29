import Foundation
import Speech

// Two settings, both read by the pipeline through `Credentials.childEnvironment`:
//
//   DEIKO_NARRATION      english: Whisper translates the speech into English and the
//                                 on-device recogniser's timeline is matched against it.
//                        native:  Whisper transcribes what it heard with its own word
//                                 timestamps, and the brief is in that language.
//   DEIKO_SPEECH_LOCALE  which of Apple's on-device recognisers runs: the offline path
//                        and the timing source.

enum Narration: String, CaseIterable {
    case english
    case native

    static let defaultsKey = "DEIKO_NARRATION"

    static var selected: Narration {
        get { Narration(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .english }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var name: String {
        switch self {
        case .english: "English (translated)"
        case .native: "Same as I speak"
        }
    }

    /// The sentence Settings shows about what comes back.
    var comesBackAs: String {
        switch self {
        case .english: "It comes back as English, whatever you spoke."
        case .native: "It comes back in the language you spoke."
        }
    }
}

enum SpeechLocale {
    static let defaultsKey = "DEIKO_SPEECH_LOCALE"
    static let fallback = "en-IN"

    /// BCP-47, with a hyphen: the spelling `SFSpeechRecognizer(locale:)` and
    /// `transcribe.mjs --locale` take.
    ///
    /// Resolved against what this Mac has. On-device locales depend on the
    /// models downloaded, so a stored or default `en-IN` may be unavailable; it
    /// then degrades to the system language's locale if present, else the first.
    static var selected: String {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? fallback
            let available = onDevice
            if available.isEmpty || available.contains(stored) { return stored }
            let want = Locale.Language(identifier: stored).languageCode
            return available.first { Locale.Language(identifier: $0).languageCode == want }
                ?? available.first { $0 == fallback }
                ?? available[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// The locales this Mac can recognise without the network, the only kind
    /// the offline path may use (see `SpeechTiming`). Computed once: it queries
    /// the speech framework per locale.
    static let onDevice: [String] = SFSpeechRecognizer.supportedLocales()
        .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        .map { $0.identifier(.bcp47) }
        .sorted()

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
