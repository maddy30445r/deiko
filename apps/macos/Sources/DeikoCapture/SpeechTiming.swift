import AVFoundation
import Foundation
import DeikoVoice
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
// LATENCY: this is why it's Apple rather than another network call. It runs
// on-device at 7–12x realtime, so a 40s recording is transcribed in about 5s
// with nothing uploaded — which is what PRD §9's latency budget assumes.
//
// This comment used to claim recognition ran on the buffers as they ARRIVED,
// during the session. It never did: the request below is a
// `SFSpeechURLRecognitionRequest` over a finished file. Live recognition would
// shave the remaining few seconds, and is worth doing eventually, but it is not
// what made this slow — see `RecognitionCompletion`.
// ─────────────────────────────────────────────────────────────────────────────

struct TimedWord: Codable {
    let text: String
    /// Milliseconds from the start of the audio, NOT the session clock. The
    /// caller adds `audioT0` — see `scripts/transcribe.mjs`.
    let start: Double
    let end: Double
}

struct TimingResult: Codable {
    let words: [TimedWord]
    let transcript: String
    let locale: String
    let onDevice: Bool
    let error: String?
    /// Wall-clock gaps between the recogniser's deliveries. Diagnostic: the idle
    /// completion threshold has to sit clear of the longest one.
    var deliveryGapsMs: [Double]? = nil
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
    ///
    /// `contextualStrings` is the recogniser's vocabulary hint list, and it is
    /// the one lever that makes on-device recognition competitive on the words
    /// a developer actually says. `useEffect` comes back as "use effect" and
    /// `nginx` as "engine x" because neither is in a dictation model's
    /// vocabulary — but both are usually ON THE SCREEN the user is pointing at,
    /// and Deiko has already read them through AX and OCR. Passing them costs
    /// nothing, sends nothing anywhere, and is measured by `make bakeoff`
    /// before anything in the product depends on it.
    static func transcribe(
        url: URL,
        localeIdentifier: String = "en-IN",
        forceOnDevice: Bool = true,
        contextualStrings: [String] = []
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
        // Capped and de-duplicated. The API takes a hint list, not a corpus;
        // handing it every OCR line on screen dilutes the bias it is supposed
        // to apply, and the identifiers worth biasing toward are few.
        if !contextualStrings.isEmpty {
            request.contextualStrings = Array(Set(contextualStrings)).prefix(100).map { $0 }
        }

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

        // Opened once; both the deadline and the completeness check need it.
        let durationMs = audioDurationSeconds(url).map { $0 * 1000 }
        // Completion is judged against the last WORD, not the last sample —
        // see `speechEndMs`. Falling back to the duration keeps the old, slow
        // behaviour for a file we cannot measure, rather than finishing early.
        let targetMs = speechEndMs(url) ?? durationMs

        return await withCheckedContinuation { continuation in
            let collector = SegmentCollector(speechEndMs: targetMs)

            // The idle half of `RecognitionCompletion` — polled, because nothing
            // calls back when the recogniser goes quiet. The coverage half is
            // checked inside the result handler below, where `isFinal` gives it
            // a natural moment to run.
            Task {
                while !collector.isResumed() {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard collector.decideCompletion() == .finishedIdle else { continue }
                    if let final = collector.finish() {
                        continuation.resume(returning: TimingResult(
                            words: final.words, transcript: final.transcript,
                            locale: localeIdentifier, onDevice: onDevice, error: nil,
                            deliveryGapsMs: collector.gaps().map { $0 * 1000 }
                        ))
                    }
                    return
                }
            }

            // SILENCE GETS ITS OWN, MUCH SHORTER DEADLINE.
            //
            // The backstop below waits duration + 20s, which is right for a
            // recognition in progress — cutting one of those off would truncate
            // a transcript. But a recogniser that has produced NOTHING is not
            // in progress, and it was being given the same generous wait.
            // Measured on session 20260801-215445: 16s of audio took 38.4s
            // through the pipeline, and 27 of those seconds were one 7.1s hold
            // sitting at its full deadline having recognised nothing. The app
            // launch this was blamed on costs 0.1s.
            //
            // Recognition streams at 7–12× realtime, so a first segment arrives
            // early or never. Allow generously for a cold model load, then stop.
            // Being wrong here is cheap: no timings means the transcript is kept
            // with estimated word times, not that the hold is lost.
            let silenceDeadline = max(8.0, (durationMs.map { $0 / 1000 } ?? 60) * 1.5)
            Task {
                try? await Task.sleep(for: .seconds(silenceDeadline))
                // Anything at all arrived → this is a real recognition, and the
                // backstop below owns it.
                guard collector.isEmpty(), collector.markResumed() else { return }
                continuation.resume(returning: failure(
                    "nothing recognised in \(Int(silenceDeadline))s — no speech the on-device model could hear",
                    locale: localeIdentifier
                ))
            }

            // Hard deadline, now a backstop rather than the common path. The
            // recogniser signals completion inconsistently — sometimes an error
            // at end-of-audio, sometimes a final result, sometimes neither.
            let deadline = (durationMs.map { $0 / 1000 } ?? 60) + 20
            Task {
                try? await Task.sleep(for: .seconds(deadline))
                if let final = collector.finish() {
                    continuation.resume(returning: TimingResult(
                        words: final.words, transcript: final.transcript,
                        locale: localeIdentifier, onDevice: onDevice, error: nil,
                            deliveryGapsMs: collector.gaps().map { $0 * 1000 }
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
                            locale: localeIdentifier, onDevice: onDevice, error: nil,
                            deliveryGapsMs: collector.gaps().map { $0 * 1000 }
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
                if result.isFinal, collector.decideCompletion() == .finishedCovering {
                    if let final = collector.finish() {
                        continuation.resume(returning: TimingResult(
                            words: final.words, transcript: final.transcript,
                            locale: localeIdentifier, onDevice: onDevice, error: nil,
                            deliveryGapsMs: collector.gaps().map { $0 * 1000 }
                        ))
                    }
                }
            }
        }
    }

    fileprivate static func failure(_ message: String, locale: String) -> TimingResult {
        TimingResult(words: [], transcript: "", locale: locale, onDevice: false, error: message)
    }

    private static func audioDurationSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Where the SPEECH ends, which is not where the file ends.
    ///
    /// A recording stops when the developer reaches over and presses the hotkey,
    /// seconds after their last word — the measured session trails 3940ms of
    /// silence. Completion was being judged against the file's duration, so the
    /// recogniser could never "reach the end" and every session waited out a
    /// 97-second deadline for work that took six.
    ///
    /// Judged by `VoiceGate`, the same relative-to-the-room test the recorder
    /// uses live, so "speech" means the same thing on both sides of the pipeline.
    /// Nil when the file cannot be read or holds no speech at all; callers fall
    /// back to the duration, which is the old behaviour and still terminates.
    static func speechEndMs(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }

        var gate = VoiceGate()
        var lastSpeechMs: Double?
        var readFrames: AVAudioFramePosition = 0

        while true {
            do { try file.read(into: buffer, frameCount: frames) } catch { break }
            let count = Int(buffer.frameLength)
            if count == 0 { break }

            // Float or int16 depending on the processing format, but VoiceGate's
            // floor is calibrated in int16 units (see its `absoluteFloor`), so
            // scale float samples up rather than letting a quiet-looking file
            // read as pure silence.
            var sumOfSquares = 0.0
            if let ints = buffer.int16ChannelData?[0] {
                for i in 0..<count {
                    let sample = Double(ints[i])
                    sumOfSquares += sample * sample
                }
            } else if let floats = buffer.floatChannelData?[0] {
                for i in 0..<count {
                    let sample = Double(floats[i]) * 32767
                    sumOfSquares += sample * sample
                }
            } else {
                return nil
            }

            readFrames += AVAudioFramePosition(count)
            let rms = (sumOfSquares / Double(count)).squareRoot()
            if gate.note(rms: rms) {
                lastSpeechMs = Double(readFrames) / format.sampleRate * 1000
            }
        }

        return lastSpeechMs
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE TIMING — the same recogniser, fed while the session is still running
//
// The file-based path above is correct and slow, and the slowness is structural:
// handed a finished WAV, the recogniser has no way to say "that was the end", so
// completion has to be INFERRED — an 8s idle threshold, a silence deadline, a
// duration+20s backstop. Measured on real sessions, that inference was 92-99% of
// the wait between letting go of the hotkey and reading a brief, against roughly
// 1.5s of actual recognition for 13s of audio.
//
// Fed live, end-of-audio stops being a guess: `endAudio()` states it, and the
// recogniser delivers its final result in well under a second. The heuristics
// are not tuned — they are not needed.
//
// This does NOT replace the file path. It is best-effort in exactly the way the
// crops are: if the recogniser is unavailable, errors, or returns nothing, no
// file is written and `BriefPipeline.precomputeTimings` recognises the WAV
// afterwards exactly as it does today. Same output format, same consumer, so
// nothing downstream can tell which path produced a timing file.
// ─────────────────────────────────────────────────────────────────────────────

/// Recognises one hold as it is spoken. One instance per hold.
final class LiveSpeechTiming: @unchecked Sendable {
    private let locale: String
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let collector: SegmentCollector
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    /// Set by whichever of `endAudio` and the result handler gets there first.
    private var continuation: CheckedContinuation<TimingResult, Never>?
    private var finished = false

    /// Nil when live recognition cannot run at all — no recogniser for the
    /// locale, unavailable, or no on-device model. Every one of those is a
    /// reason to leave the work to the file path rather than to report an error:
    /// the session is recording either way and the user must not be told about a
    /// shortcut that did not happen.
    init?(localeIdentifier: String = "en-IN") {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              // Same refusal as the file path: narration does not go to Apple's
              // servers because a local model was missing.
              recognizer.supportsOnDeviceRecognition
        else { return nil }

        self.locale = localeIdentifier
        self.request = SFSpeechAudioBufferRecognitionRequest()
        // Live has no `speechEndMs` to measure — the audio does not exist yet.
        // Nil means the collector's coverage test never fires, which is right:
        // `endAudio()` is the completion signal here, not a coverage guess.
        self.collector = SegmentCollector(speechEndMs: nil)

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { self.collector.absorb(result.bestTranscription) }
            // An error at end-of-stream is the recogniser's normal way of
            // saying it is done, and it usually arrives having already
            // delivered everything. Partial results in hand beat nothing.
            if error != nil || (result?.isFinal ?? false) { self.deliver() }
        }
    }

    /// Called on the audio thread for every converted buffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done else { return }
        request.append(buffer)
    }

    /// Say the audio has ended and wait for the last result.
    ///
    /// The deadline is a backstop, not the expected path — the final result
    /// lands in well under a second once the stream is closed. Whatever has been
    /// collected by then is returned rather than discarded, because a partial
    /// timeline still binds most of the words and the alternative is recognising
    /// the whole file again.
    func finish(timeout: Duration = .seconds(3)) async -> TimingResult {
        request.endAudio()
        let waiter = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.deliver()
        }
        defer { waiter.cancel(); clearTask() }

        return await withCheckedContinuation { cont in
            lock.lock()
            // The result handler may already have fired — `deliver` sets
            // `finished` before it can resume anything, so check it under the
            // same lock rather than parking a continuation nobody will resume.
            if finished {
                lock.unlock()
                cont.resume(returning: result())
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// Abandon the recognition without waiting — the hold produced no audio, or
    /// the session is being torn down.
    func cancel() {
        lock.lock()
        finished = true
        let pending = continuation
        continuation = nil
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
        pending?.resume(returning: SpeechTiming.failure("cancelled", locale: locale))
    }

    /// The recognition task is written in `init` and cleared from whichever
    /// thread finishes first, so it is held under the same lock as everything
    /// else here rather than being the one field left to chance.
    private func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    private func deliver() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        // Nil when `finish()` has not been called yet: the recogniser finished
        // before we asked it to, which is fine — `finish()` reads the collected
        // result directly in that case.
        pending?.resume(returning: result())
    }

    private func result() -> TimingResult {
        guard let final = collector.finish() else {
            return SpeechTiming.failure("nothing recognised live", locale: locale)
        }
        return TimingResult(
            words: final.words, transcript: final.transcript,
            locale: locale, onDevice: true, error: nil,
            deliveryGapsMs: collector.gaps().map { $0 * 1000 }
        )
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
    /// When `absorb` last took anything. Wall-clock, not the audio clock — the
    /// question it answers is "has the recogniser gone quiet", which is about
    /// delivery, not about where we are in the recording.
    private var lastSegmentAt: Date?
    private var deliveryGaps: [Double] = []
    /// Measured once by the caller — this class used to reopen the WAV on
    /// every `isFinal`, parsing the same header dozens of times per hold.
    private let speechEndMs: Double?
    private let policy = RecognitionCompletion()

    init(speechEndMs: Double?) {
        self.speechEndMs = speechEndMs
    }

    func absorb(_ transcription: SFTranscription) {
        lock.lock()
        defer { lock.unlock() }

        let placed = transcription.segments.filter { $0.timestamp > 0 }
        guard !placed.isEmpty else { return }

        // Evict everything inside the span this hypothesis covers before
        // inserting it. Keying by start time alone left GHOSTS: a revision
        // that merged "is"+"mein" into "ismein" at a nudged timestamp added
        // the new word but kept the superseded ones, and the transcript read
        // "ismein mein" — a phantom token the aligner then treated as really
        // spoken. Utterances never overlap in time, so the eviction can only
        // remove earlier hypotheses of THIS utterance, never another one.
        let spanStart = placed.map { $0.timestamp * 1000 }.min()!
        let spanEnd = placed.map { ($0.timestamp + $0.duration) * 1000 }.max()!
        for key in segments.keys
        where Double(key) >= spanStart - 1 && Double(key) <= spanEnd + 1 {
            segments.removeValue(forKey: key)
        }

        for segment in placed {
            let startMs = segment.timestamp * 1000
            segments[Int(startMs.rounded())] = TimedWord(
                text: segment.substring,
                start: startMs,
                end: (segment.timestamp + segment.duration) * 1000
            )
        }
        if let previous = lastSegmentAt {
            deliveryGaps.append(Date().timeIntervalSince(previous))
        }
        lastSegmentAt = Date()
    }

    /// Wall-clock gaps between deliveries, for tuning the idle threshold.
    func gaps() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return deliveryGaps
    }

    /// Ask `RecognitionCompletion` whether this recognition is done, from the
    /// state held right now. One lock, one snapshot: reading "how many segments"
    /// and "how long since the last" through separate calls would let a delivery
    /// land between them and answer about two different moments.
    func decideCompletion() -> RecognitionCompletion.Decision {
        lock.lock()
        defer { lock.unlock() }
        return policy.decide(
            furthestSegmentEndMs: segments.values.map(\.end).max(),
            speechEndMs: speechEndMs,
            secondsSinceLastSegment: lastSegmentAt.map { -$0.timeIntervalSinceNow } ?? 0
        )
    }

    func isResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    /// Nothing recognised at all — as opposed to "recognised something and
    /// gone quiet", which is what `decideCompletion` is for.
    func isEmpty() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return segments.isEmpty
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
}
