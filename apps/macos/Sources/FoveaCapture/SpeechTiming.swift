import AVFoundation
import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────────────
// WORD TIMING — on-device, from Apple's Speech framework
//
// Two recognisers with different jobs:
//
//   Apple Speech  →  WHEN words were said   →  drives alignment
//   Sarvam        →  WHAT was said          →  drives the plan text
//
// Sarvam's Hinglish text is excellent (`mode=translit` returns "Yeh jo data hai
// ismein taxonomy ke andar board ka naam") but its REST API returns a single
// timestamp spanning the whole clip on every model and parameter combination we
// tried — no word-level timing exists to bind against. Apple's recogniser gives
// a timestamp and duration per segment, on-device, free, with no duration cap.
//
// We do not need Apple's transcription to be *good*. We need its clock to be
// right, and enough token overlap to locate the deictic words. Its Hinglish
// accuracy is mediocre and that is fine.
//
// LATENCY: this is why it's Apple rather than another network call. It runs on
// the audio buffers as they arrive during a session, so the timings are ready
// when the hotkey is released rather than after an upload — which is exactly
// what PRD §9's latency budget assumes.
// ─────────────────────────────────────────────────────────────────────────────

struct TimedWord: Codable {
    let text: String
    /// Milliseconds from the start of the audio, NOT the session clock. The
    /// caller adds `audioT0` — see `scripts/transcribe.mjs`.
    let start: Double
    let end: Double
    let confidence: Double
}

struct TimingResult: Codable {
    let words: [TimedWord]
    let transcript: String
    let locale: String
    let onDevice: Bool
    let error: String?
}

enum SpeechTiming {

    /// Ask for permission. Speech Recognition is its own TCC prompt — a fourth
    /// one alongside Accessibility, Screen Recording and Microphone, which is
    /// real onboarding friction and worth being deliberate about.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Transcribe a WAV file, returning per-word timings.
    ///
    /// `en-IN` by default, for two independent reasons.
    ///
    /// Availability: `hi-IN` has no on-device asset on this machine
    /// (`supportsOnDeviceRecognition == false`), and falling back to Apple's
    /// servers would send narration off the device — which PRD §10 forbids.
    /// `en-IN` and `en-US` both run on-device.
    ///
    /// Fit: an Indian-English recogniser renders Hindi words phonetically in
    /// LATIN script — "yeh", "isko", "yahan" — which is precisely the form the
    /// Hinglish half of the deictic lexicon matches. A Hindi-locale recogniser
    /// would return Devanagari, which the lexicon also handles, but it mangles
    /// the English technical terms that make up most of a developer's speech.
    static func transcribe(
        url: URL,
        localeIdentifier: String = "en-IN",
        forceOnDevice: Bool = true
    ) async -> TimingResult {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return failure("no recogniser for locale \(localeIdentifier)", locale: localeIdentifier)
        }
        guard recognizer.isAvailable else {
            return failure("recogniser unavailable for \(localeIdentifier)", locale: localeIdentifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partials ON, and every result accumulated.
        //
        // With partials off, a multi-utterance recording comes back as only its
        // LAST utterance: a 31s clip returned 12 segments covering 21.6s-28.7s
        // and silently dropped the first twenty seconds. The recogniser splits
        // on pauses and marks each utterance final in turn, so the only way to
        // see all of them is to watch every result and union the segments.
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = forceOnDevice
        request.taskHint = .dictation

        let onDevice = recognizer.supportsOnDeviceRecognition && forceOnDevice
        if forceOnDevice && !recognizer.supportsOnDeviceRecognition {
            // Refuse to silently fall back to Apple's servers. The product's
            // whole privacy posture is that narration and screen content do not
            // leave the machine except to the disclosed APIs (PRD §10).
            return failure(
                "on-device recognition unavailable for \(localeIdentifier) — refusing to fall back to network recognition",
                locale: localeIdentifier
            )
        }

        return await withCheckedContinuation { continuation in
            let collector = SegmentCollector()

            // Hard deadline. The recogniser signals completion inconsistently —
            // sometimes an error at end-of-audio, sometimes a final result,
            // sometimes neither — and without this the task simply never
            // returns. Whatever segments have arrived by the deadline are worth
            // more than hanging forever.
            let deadline = (audioDurationSeconds(url) ?? 60) + 20
            Task {
                try? await Task.sleep(for: .seconds(deadline))
                if let final = collector.finish() {
                    continuation.resume(returning: TimingResult(
                        words: final.words, transcript: final.transcript,
                        locale: localeIdentifier, onDevice: onDevice, error: nil
                    ))
                } else if collector.markResumed() {
                    continuation.resume(returning: failure(
                        "recognition timed out after \(Int(deadline))s with no segments",
                        locale: localeIdentifier
                    ))
                }
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if let final = collector.finish() {
                        // Partial results already in hand beat nothing: the
                        // recogniser often errors at end-of-file having already
                        // delivered every utterance.
                        continuation.resume(returning: TimingResult(
                            words: final.words, transcript: final.transcript,
                            locale: localeIdentifier, onDevice: onDevice, error: nil
                        ))
                    } else if collector.markResumed() {
                        continuation.resume(returning: failure(
                            error.localizedDescription, locale: localeIdentifier
                        ))
                    }
                    return
                }

                guard let result else { return }
                collector.absorb(result.bestTranscription)

                // `isFinal` fires once per utterance, not once per file, so it
                // is a signal to keep the segments — not to stop listening.
                // The task ends by calling back with an error (end of audio),
                // which is handled above.
                if result.isFinal, collector.isComplete(url: url) {
                    if let final = collector.finish() {
                        continuation.resume(returning: TimingResult(
                            words: final.words, transcript: final.transcript,
                            locale: localeIdentifier, onDevice: onDevice, error: nil
                        ))
                    }
                }
            }
        }
    }

    private static func failure(_ message: String, locale: String) -> TimingResult {
        TimingResult(words: [], transcript: "", locale: locale, onDevice: false, error: message)
    }

    private static func audioDurationSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

/// Accumulates segments across every result the recogniser emits.
///
/// Keyed by start time so re-delivered segments (the recogniser revises an
/// utterance as it hears more) overwrite rather than duplicate, and so
/// utterances from anywhere in the file survive regardless of the order they
/// arrive in.
private final class SegmentCollector: @unchecked Sendable {
    private var segments: [Int: TimedWord] = [:]
    private var resumed = false
    private let lock = NSLock()

    func absorb(_ transcription: SFTranscription) {
        lock.lock()
        defer { lock.unlock() }
        for segment in transcription.segments {
            let startMs = segment.timestamp * 1000
            // Segments with a zero timestamp are the recogniser's in-progress
            // guesses before it has placed them in time; they would all collide
            // at key 0 and displace real content.
            guard segment.timestamp > 0 || startMs > 0 else { continue }
            segments[Int(startMs.rounded())] = TimedWord(
                text: segment.substring,
                start: startMs,
                end: (segment.timestamp + segment.duration) * 1000,
                confidence: Double(segment.confidence)
            )
        }
    }

    /// Whether we have plausibly covered the whole file — used to decide if an
    /// `isFinal` is the last one. Compares the furthest segment against the
    /// audio's duration.
    func isComplete(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let furthest = segments.values.map(\.end).max() else { return false }
        guard let durationMs = audioDurationMs(url) else { return true }
        return furthest >= durationMs - 1500
    }

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func finish() -> (words: [TimedWord], transcript: String)? {
        lock.lock()
        defer { lock.unlock() }
        if resumed || segments.isEmpty { return nil }
        resumed = true
        let words = segments.keys.sorted().compactMap { segments[$0] }
        return (words, words.map(\.text).joined(separator: " "))
    }

    private func audioDurationMs(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate * 1000
    }
}
