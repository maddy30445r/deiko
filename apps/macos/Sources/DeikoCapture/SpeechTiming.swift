import AVFoundation
import Foundation
import DeikoVoice
import Speech

struct TimedWord: Codable {
    let text: String
    /// Milliseconds from the start of the audio, not the session clock. The caller adds `audioT0`;
    /// see `packages/core/src/transcribe.mjs`.
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

/// Word timing from Apple's Speech framework, on-device.
///
/// Apple Speech says when words were said (it drives alignment); Sarvam says what was said (it drives
/// the plan text). Sarvam's REST API returns one timestamp for the whole clip, so it has no word-level
/// timing to bind against. Apple's transcription need not be good, only its clock right and its tokens
/// close enough to locate the deictic words. It runs on-device at roughly 7-12x realtime, uploading nothing.
enum SpeechTiming {

    /// Ask for permission. Speech Recognition is its own TCC prompt, alongside Accessibility, Screen
    /// Recording and Microphone.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Transcribe a WAV file, returning per-word timings.
    ///
    /// `en-IN` by default: `hi-IN` may have no on-device asset (`supportsOnDeviceRecognition == false`), and
    /// falling back to Apple's servers would send narration off the device. An Indian-English recogniser
    /// also renders Hindi words phonetically in Latin script ("yeh", "isko"), the form the Hinglish half of
    /// the deictic lexicon matches, while a Hindi-locale one mangles the English technical terms that make
    /// up most of a developer's speech.
    ///
    /// `contextualStrings` is the recogniser's vocabulary hint list. `useEffect` comes back as "use effect"
    /// because a dictation model does not know it, but it is usually on the screen the user is pointing at
    /// and Deiko has already read it through AX and OCR. Passing it sends nothing anywhere.
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
        // Partials on, and every result accumulated: with partials off, a multi-utterance recording comes
        // back as only its last utterance. The recogniser splits on pauses and marks each utterance final
        // in turn, so all of them are seen only by watching every result and unioning the segments.
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = forceOnDevice
        request.taskHint = .dictation
        // Capped and de-duplicated: the API takes a hint list, not a corpus, and a long list dilutes the bias.
        if !contextualStrings.isEmpty {
            request.contextualStrings = Array(Set(contextualStrings)).prefix(100).map { $0 }
        }

        let onDevice = recognizer.supportsOnDeviceRecognition && forceOnDevice
        if forceOnDevice && !recognizer.supportsOnDeviceRecognition {
            // Refuse to fall back silently to Apple's servers: narration and screen content must not
            // leave the machine except to the disclosed APIs.
            return failure(
                "on-device recognition unavailable for \(localeIdentifier) — refusing to fall back to network recognition",
                locale: localeIdentifier
            )
        }

        // Opened once; both the deadline and the completeness check need it.
        let durationMs = audioDurationSeconds(url).map { $0 * 1000 }
        // Completion is judged against the last word, not the last sample (see `speechEndMs`). The
        // duration is the fallback for a file that cannot be measured: slower, but it terminates.
        let targetMs = speechEndMs(url) ?? durationMs

        return await withCheckedContinuation { continuation in
            let collector = SegmentCollector(speechEndMs: targetMs)

            // The idle half of `RecognitionCompletion`, polled because nothing calls back when the
            // recogniser goes quiet. The coverage half runs in the result handler, on `isFinal`.
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

            // Silence gets its own, much shorter deadline. The backstop below waits duration + 20s, right
            // for a recognition in progress, but a recogniser that has produced nothing is not in progress.
            // Recognition streams at 7-12x realtime, so a first segment arrives early or never: allow for a
            // cold model load, then stop. Being wrong is cheap: no timings means the transcript is kept with
            // estimated word times.
            let silenceDeadline = max(8.0, (durationMs.map { $0 / 1000 } ?? 60) * 1.5)
            Task {
                try? await Task.sleep(for: .seconds(silenceDeadline))
                // Anything at all arrived: this is a real recognition, and the backstop below owns it.
                guard collector.isEmpty(), collector.markResumed() else { return }
                continuation.resume(returning: failure(
                    "nothing recognised in \(Int(silenceDeadline))s — no speech the on-device model could hear",
                    locale: localeIdentifier
                ))
            }

            // Hard deadline, a backstop rather than the common path: the recogniser signals completion
            // inconsistently (an error at end-of-audio, a final result, or neither).
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
                        // Partial results in hand beat nothing: the recogniser often errors at
                        // end-of-file having already delivered every utterance.
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

                // `isFinal` fires once per utterance, not once per file, so it means keep the segments,
                // not stop listening. The task ends with an error at end of audio, handled above.
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

    /// Where the speech ends, which is not where the file ends: a recording stops seconds after the
    /// last word, when the developer reaches for the hotkey. Judged against the file's duration, the
    /// recogniser could never "reach the end" and every session would wait out its deadline.
    ///
    /// Judged by `VoiceGate`, the same relative-to-the-room test the recorder uses live, so "speech" means
    /// the same on both sides. Nil when the file cannot be read or holds no speech; callers fall back to
    /// the duration.
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

            // Float or int16 depending on the processing format, but `VoiceGate`'s floor is calibrated in
            // int16 units (see `absoluteFloor`), so float samples are scaled up rather than letting a
            // quiet-looking file read as silence.
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

/// Recognises one hold as it is spoken, feeding the same recogniser while the session runs. One
/// instance per hold.
///
/// A finished WAV gives the recogniser no way to say "that was the end", so the file path infers
/// completion (idle threshold, silence deadline, backstop) and that inference dominates the wait after
/// the hotkey is released. Fed live, `endAudio()` states the end and the final result lands quickly.
///
/// This does not replace the file path. It is best-effort: if the recogniser is unavailable, errors or
/// returns nothing, no file is written and `BriefPipeline.precomputeTimings` recognises the WAV
/// afterwards. The output format and consumer are the same, so nothing downstream can tell which path
/// produced a timing file.
final class LiveSpeechTiming: @unchecked Sendable {
    private let locale: String
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let collector: SegmentCollector
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    /// Set by whichever of `endAudio` and the result handler gets there first.
    private var continuation: CheckedContinuation<TimingResult, Never>?
    private var finished = false

    /// Nil when live recognition cannot run at all (no recogniser for the locale, unavailable, or no
    /// on-device model). Each of those leaves the work to the file path rather than reporting an error:
    /// the session is recording either way.
    init?(localeIdentifier: String = "en-IN") {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable,
              // Same refusal as the file path: narration does not go to Apple's servers because a
              // local model was missing.
              recognizer.supportsOnDeviceRecognition
        else { return nil }

        self.locale = localeIdentifier
        self.request = SFSpeechAudioBufferRecognitionRequest()
        // Live has no `speechEndMs` to measure. Nil means the coverage test never fires: `endAudio()`
        // is the completion signal here.
        self.collector = SegmentCollector(speechEndMs: nil)

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { self.collector.absorb(result.bestTranscription) }
            // An error at end-of-stream is the recogniser's normal way of saying it is done, usually
            // after delivering everything.
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

    /// Say the audio has ended and wait for the last result. The deadline is a backstop: whatever has
    /// been collected by then is returned rather than discarded, since a partial timeline still binds
    /// most of the words.
    func finish(timeout: Duration = .seconds(3)) async -> TimingResult {
        request.endAudio()
        let waiter = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.deliver()
        }
        defer { waiter.cancel(); clearTask() }

        return await withCheckedContinuation { cont in
            lock.lock()
            // The result handler may already have fired: `deliver` sets `finished` before it resumes
            // anything, so check under the same lock rather than parking a continuation nobody will resume.
            if finished {
                lock.unlock()
                cont.resume(returning: result())
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// Abandon the recognition without waiting: the hold produced no audio, or the session is torn down.
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

    /// `task` is written in `init` and cleared from whichever thread finishes first, so it is held under
    /// the same lock as everything else here.
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
        // Nil when `finish()` has not been called yet: the recogniser finished first, and `finish()`
        // reads the collected result directly.
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

/// Accumulates segments across every result the recogniser emits. Keyed by start time so re-delivered
/// segments (revised as the recogniser hears more) overwrite rather than duplicate, and utterances from
/// anywhere in the file survive in any arrival order.
private final class SegmentCollector: @unchecked Sendable {
    private var segments: [Int: TimedWord] = [:]
    private var resumed = false
    private let lock = NSLock()
    /// When `absorb` last took anything. Wall-clock, not the audio clock: it answers "has the recogniser
    /// gone quiet", which is about delivery.
    private var lastSegmentAt: Date?
    private var deliveryGaps: [Double] = []
    /// Measured once by the caller, not reopened from the WAV on every `isFinal`.
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

        // Evict everything inside the span this hypothesis covers before inserting it. Keying by start
        // time alone leaves ghosts: a revision merging "is"+"mein" into "ismein" at a nudged timestamp
        // would keep the superseded words, and the transcript would read "ismein mein". Utterances never
        // overlap, so this only removes earlier hypotheses of the same utterance.
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

    /// Ask `RecognitionCompletion` whether this recognition is done. One lock, one snapshot, so a delivery
    /// cannot land between reads and answer about two different moments.
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

    /// Nothing recognised at all, as opposed to "recognised something and gone quiet" (`decideCompletion`).
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
