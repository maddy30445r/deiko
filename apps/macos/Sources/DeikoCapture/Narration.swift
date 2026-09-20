import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────────────
// WHAT LANGUAGE THE BRIEF IS WRITTEN IN
//
// Two settings, both read by the pipeline through `Credentials.childEnvironment`:
//
//   DEIKO_NARRATION      english — Whisper translates whatever was spoken into
//                                  English, and the on-device recogniser's timeline
//                                  is matched against it (the original design).
//                        native  — Whisper writes down what it heard, with its own
//                                  word timestamps, and the brief is in that
//                                  language. The first Mandarin-speaking user got
//                                  an English brief and did not expect one.
//   DEIKO_SPEECH_LOCALE  which of Apple's on-device recognisers runs — the offline
//                        path and the timing source. It was `en-IN` in three
//                        places; a Mandarin speaker past their trial got English
//                        applied to Chinese, which is noise.
// ─────────────────────────────────────────────────────────────────────────────

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

    /// BCP-47, with a hyphen — the spelling `SFSpeechRecognizer(locale:)` and
    /// `transcribe.mjs --locale` have always been handed.
    ///
    /// RESOLVED AGAINST WHAT THIS MAC HAS. Which locales are on-device depends
    /// on the models the user has downloaded: this Mac reports five, all
    /// English, and a Mac set up in Chinese may report none of them. A stored
    /// or default `en-IN` that is not in that list would leave the Settings
    /// picker blank and hand the recogniser a locale it refuses, so an
    /// unavailable choice degrades to one that exists — the system language's
    /// if this Mac has it, otherwise the first.
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

    /// The locales THIS Mac can recognise without the network, which is the
    /// only kind the offline path is allowed to use (see `SpeechTiming`).
    /// Computed once: it asks the speech framework once per locale.
    static let onDevice: [String] = SFSpeechRecognizer.supportedLocales()
        .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        .map { $0.identifier(.bcp47) }
        .sorted()

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
