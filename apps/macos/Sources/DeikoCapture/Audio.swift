import AVFoundation
// AVFAudio predates Sendable annotations, so `AVAudioPCMBuffer` and the converter's input block trip
// strict concurrency checks. The block runs synchronously inside `convert(to:error:)` and nothing
// crosses a concurrency boundary, so the suppression is scoped to this one import.
@preconcurrency import AVFAudio
import Foundation
import DeikoVoice

/// One-shot flag for the converter's input block. See `append(_:)`.
private final class ConversionState: @unchecked Sendable {
    var supplied = false
}

/// Captures narration as 16kHz mono WAV while the hotkey is held. `t0` is the `Clock.nowMs()` reading
/// when the first buffer lands, and every ASR word timestamp is an offset from it: audio must share the
/// monotonic clock with cursor samples and crops, or every binding skews.
final class Audio {
    /// A fresh engine per recording; see `start(path:)`.
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// `Clock.nowMs()` at the first captured buffer. Nil until audio flows: the engine takes a few ms
    /// to spin up, and this measures that gap rather than assuming it.
    private(set) var t0: Double?

    private(set) var isRecording = false

    /// `Clock.nowMs()` when speech was last heard, or nil if none yet. The recorder uses it to skip
    /// cursor settles made in silence (transit, scrolling, reading).
    ///
    /// Written on the audio thread, read on the main actor: a `Double` write is atomic on the platforms
    /// this runs on, and a stale read is off by one buffer (~256ms), which the multi-second gate absorbs.
    nonisolated(unsafe) private(set) var lastVoiceMs: Double?

    /// Handed every converted buffer, on the audio thread, just before it is written to the WAV, so
    /// recognition can run during the session instead of on the finished file.
    ///
    /// It gets the converted buffer, not the mic's native one, so the recognition stream holds exactly
    /// the samples in the WAV and a fallback to the file path keeps the same timeline. It runs on the
    /// real-time thread, so the receiver must be cheap.
    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Decides whether a buffer is speech, relative to the room rather than a fixed threshold. See
    /// `VoiceGate`.
    ///
    /// Touched only from the audio thread, including the per-recording reset (done on the first buffer,
    /// not in `start()`): it holds an array, and `removeTap` does not promise an in-flight callback has
    /// returned, so resetting from the caller's thread could mutate a buffer being read.
    nonisolated(unsafe) private var gate = VoiceGate()

    enum AudioError: LocalizedError {
        case formatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: "could not build the 16kHz mono output format"
            case .converterUnavailable: "could not convert the mic format to 16kHz mono"
            }
        }
    }

    /// Begins recording to `path`. Throws rather than failing quietly: a session without audio is
    /// useless for alignment.
    func start(path: String) throws {
        // Self-heal rather than return early: the caller would record an `audioPath` for a file that
        // was never created.
        if isRecording { stop() }

        // A fresh engine per recording. An engine's input node caches the hardware format and nothing
        // refreshes it (AirPods connecting, a call app changing the sample rate, mic permission granted
        // mid-run), so a reused engine hands `installTap` a stale format. That raises an Objective-C
        // exception ("Failed to create tap due to format mismatch") which no `do/catch` sees, and the app dies.
        engine = AVAudioEngine()

        // Reset the origin first, before anything can throw, so a failed `start` cannot leave the
        // previous recording's t0 for `stop()` to report.
        t0 = nil
        lastVoiceMs = nil

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { throw AudioError.formatUnavailable }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioError.converterUnavailable
        }

        // 16-bit PCM WAV, not the hardware's float format: the ASR APIs accept it directly and it is
        // a third of the size.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.converter = converter
        self.targetFormat = target

        // `format: nil`: the tap takes whatever the node is producing now. The mismatch exception is
        // raised only for an explicit format; a device change since `inputFormat` was read surfaces as a
        // converter error on that buffer instead.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Unwind the tap: a leftover one would trip AVAudioEngine's one-tap-per-bus precondition on
            // the next hold and abort the process.
            input.removeTap(onBus: 0)
            self.file = nil
            self.converter = nil
            throw error
        }
        isRecording = true
    }

    /// Stops and returns the audio origin so the caller can record it against the shared clock. Nil
    /// when nothing was recorded, never a previous hold's origin.
    @discardableResult
    func stop() -> Double? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        file = nil
        converter = nil
        return t0
    }

    /// Tap callback, on the real-time thread: keep it cheap.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat, let file else { return }

        // Stamp the origin on the first buffer, not at `engine.start()`: the gap between asking for audio
        // and receiving it is real. `start()` nils `t0`, so this is also where a new recording is
        // observable on the audio thread, the only thread allowed to touch the gate.
        if t0 == nil {
            t0 = Clock.nowMs()
            gate.reset()
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { return }

        // A reference box rather than a captured `var`: the input block is `@Sendable`, so mutating a
        // local from it is a concurrency error even though the call is synchronous.
        let state = ConversionState()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter pulls until satisfied; supply this buffer once, then report no data, or it spins.
            if state.supplied {
                status.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return }
        noteVoiceActivity(in: output)
        // Before the write, so a disk error cannot cost the recogniser a buffer it cannot ask for again.
        onBuffer?(output)
        try? file.write(from: output)
    }

    /// RMS of the converted buffer, on the audio thread: one pass over int16 samples, no allocation.
    private func noteVoiceActivity(in buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumOfSquares = 0.0
        for i in 0..<count {
            let sample = Double(channel[i])
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Double(count)).squareRoot()
        if gate.note(rms: rms) { lastVoiceMs = Clock.nowMs() }
    }
}
