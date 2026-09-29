import Testing
@testable import DeikoVoice

// Each test is a property the design depends on, or a failure mode of an
// alternative design that looked correct until measured.

/// Buffers roughly like real narration: bursts of speech separated by the gaps
/// between words. RMS values are in the range this app actually records.
private func speech(bursts: Int, loud: Double = 400, quiet: Double = 60) -> [Double] {
    (0..<bursts).flatMap { _ in [loud, loud, loud, quiet] }
}

private func run(_ gate: inout VoiceGate, _ samples: [Double]) -> [Bool] {
    samples.map { gate.note(rms: $0) }
}

@Test("speech is voice")
func speechIsVoice() {
    var gate = VoiceGate()
    let heard = run(&gate, speech(bursts: 10))
    // Not every buffer: the quiet inter-word ones are correctly not speech, but
    // most of the loud ones must be.
    #expect(heard.filter { $0 }.count >= 20)
}

@Test("a room quiet enough to hear a pin drop is still silence")
func absoluteFloorHolds() {
    var gate = VoiceGate()
    // 2.5x a noise floor of 4 is 10, below anything a microphone should call
    // narration. Without the absolute floor this reads as speech.
    let heard = run(&gate, (0..<60).map { $0 % 3 == 0 ? 4.0 : 12.0 })
    #expect(!heard.contains(true))
}

@Test("a constant tone is not speech, however loud")
func constantToneIsNotSpeech() {
    var gate = VoiceGate()
    // Flat 93 RMS with no dynamics is hum, not a person.
    let heard = run(&gate, [Double](repeating: 93, count: 120))
    #expect(!heard.contains(true))
}

@Test("a near-silent warm-up buffer does not poison the floor")
func warmUpBufferDoesNotPoison() {
    var gate = VoiceGate()
    // The engine's first buffer is near zero. A floor that pins to it never
    // recovers, so the hum above would read as speech for the rest of the
    // session.
    var heard = run(&gate, [0.0])
    heard += run(&gate, [Double](repeating: 93, count: 120))
    #expect(!heard.suffix(100).contains(true))
}

@Test("talking without pausing does not raise the floor to meet you")
func continuousSpeechStaysVoice() {
    var gate = VoiceGate()
    // A fast-climbing floor treats the speaker as the room after a few seconds.
    // Two hundred buffers is about seventeen seconds.
    let heard = run(&gate, speech(bursts: 50))
    #expect(heard.suffix(40).filter { $0 }.count >= 20)
}

@Test("no voice gap long enough to lose a referent")
func gapsStayUnderTheRecorderGate() {
    var gate = VoiceGate()
    let heard = run(&gate, speech(bursts: 50))

    var longest = 0, run_ = 0
    for h in heard {
        if h { run_ = 0 } else { run_ += 1; longest = max(longest, run_) }
    }
    // Buffers are ~85ms and Recorder drops a settle 6000ms from any narration;
    // 40 buffers is 3.4 seconds, the margin this design exists to buy.
    #expect(longest < 40)
}

@Test("the same speech is voice whether the mic is loud or quiet")
func scaleInvariance() {
    let samples = speech(bursts: 30)
    var loud = VoiceGate(), quiet = VoiceGate()
    // Halving the input must give the identical answer, because nothing about
    // the speech changed. A fixed threshold cannot do that.
    #expect(run(&loud, samples) == run(&quiet, samples.map { $0 * 0.5 }))
}

@Test("the window forgets, so a quieter room becomes audible again")
func windowIsTrailing() {
    var gate = VoiceGate(windowSize: 20)
    _ = run(&gate, [Double](repeating: 800, count: 40))

    // The room drops to near silence, then someone speaks softly. Against the
    // old loud floor that is nothing; against the last twenty buffers it is
    // clearly speech.
    _ = run(&gate, [Double](repeating: 30, count: 20))
    let heard = gate.note(rms: 200)
    #expect(heard)
}

@Test("reset leaves nothing of the previous session behind")
func resetClearsTheWindow() {
    var gate = VoiceGate(windowSize: 20)
    _ = run(&gate, [Double](repeating: 800, count: 40))
    gate.reset()

    // A fresh session in a quiet room. If the loud window survived, the first
    // buffers of real narration would be judged against it and lost.
    let heard = run(&gate, speech(bursts: 5, loud: 200, quiet: 30))
    #expect(heard.contains(true))
}

@Test("a partially filled window still judges")
func partialWindow() {
    var gate = VoiceGate(windowSize: 96)
    // The window fills over eight seconds and narration usually starts sooner,
    // so the first second must still be judged.
    let heard = run(&gate, speech(bursts: 3))
    #expect(heard.contains(true))
}
