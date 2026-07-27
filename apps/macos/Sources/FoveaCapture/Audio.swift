import AVFoundation
// AVFAudio predates Sendable annotations, so `AVAudioPCMBuffer` and the
// converter's input block trip strict-concurrency checks. The block is
// documented as being invoked synchronously by `convert(to:error:)` on the
// calling thread — nothing actually crosses a concurrency boundary — so the
// suppression is scoped to this one import rather than silenced per-warning.
@preconcurrency import AVFAudio
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// NARRATION CAPTURE
//
// 16kHz mono WAV — what Sarvam and Whisper both want, and small enough that a
// 30-second session is under a megabyte.
//
// The only subtle part is TIME. Alignment binds spoken words to pointing
// events, so audio has to live on the same monotonic clock as the cursor
// samples and the crops. We record `t0` — the `Clock.nowMs()` reading at the
// moment the first audio buffer lands — and every word timestamp the ASR later
// returns is an offset from it. Using wall-clock here, or assuming recording
// starts the instant the hotkey goes down, would put a fixed skew into every
// binding and quietly cost us the 80% gate.
//
// The mic runs only while the hotkey is held. Nothing is recorded otherwise.
// ─────────────────────────────────────────────────────────────────────────────

/// One-shot flag for the converter's input block. See `append(_:)`.
private final class ConversionState: @unchecked Sendable {
    var supplied = false
}

final class Audio {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// `Clock.nowMs()` at the first captured buffer. Nil until audio actually
    /// starts flowing — the engine takes a few ms to spin up, and that gap is
    /// exactly what this exists to measure rather than assume.
    private(set) var t0: Double?

    private(set) var isRecording = false

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

    /// Begins recording to `path`. Throws rather than failing quietly: a session
    /// recorded without audio is useless for alignment, and the user should
    /// find out at the start rather than at transcription time.
    func start(path: String) throws {
        // Self-heal rather than silently succeed: returning early here while
        // recording meant the caller recorded an `audioPath` for a file that
        // was never created — the mic kept writing into the PREVIOUS hold's
        // WAV, and transcription later failed on a path that does not exist.
        if isRecording { stop() }

        // Reset the origin FIRST, before anything can throw. It used to be
        // reset after the file was opened, so a throwing `start` left the
        // previous hold's t0 in place — and `stop()` then reported that stale
        // origin for a hold that recorded nothing.
        t0 = nil

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

        // Write as 16-bit PCM WAV, not the hardware's float format: it is what
        // the ASR APIs accept directly, and it is a third of the size.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.converter = converter
        self.targetFormat = target

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Unwind the tap. Leaving it installed meant the NEXT hold's
            // `installTap` hit AVAudioEngine's one-tap-per-bus precondition
            // and aborted the whole process mid-session.
            input.removeTap(onBus: 0)
            self.file = nil
            self.converter = nil
            throw error
        }
        isRecording = true
    }

    /// Stops and returns the audio origin, so the caller can record it against
    /// the same clock everything else uses. Nil when nothing was recorded —
    /// never a previous hold's origin.
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

    // ── Tap callback (real-time thread — keep it cheap) ─────────────────────

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat, let file else { return }

        // Stamp the origin on the FIRST buffer, not at engine.start(): the gap
        // between asking for audio and receiving it is real, and guessing it
        // puts a constant offset into every word timestamp.
        if t0 == nil { t0 = Clock.nowMs() }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { return }

        // Held in a reference box rather than a captured `var`: the input block
        // is typed `@Sendable`, so mutating a local from inside it is a
        // concurrency error even though the call is synchronous.
        let state = ConversionState()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter pulls until satisfied; hand it this buffer once and
            // report end-of-stream after, or it spins on the same data.
            if state.supplied {
                status.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return }
        try? file.write(from: output)
    }
}
