import Testing
@testable import Kalamos

/// The guard under one-tap dictation: the microphone closes by itself after a
/// stretch of silence.
///
/// From his log on 2026-08-02 — seven recordings nobody asked for in twenty-six
/// seconds, one sixteen seconds long, three of them transcribed as the classic
/// silence hallucination. The trade-off is inherent to one-tap (every short tap
/// fires); what was missing was a floor under it.
@Suite struct HandsFreeSilenceTests {
    private let window = HandsFreeSilence.defaultSeconds   // 10

    // MARK: The two outcomes

    /// The stray tap: nobody ever spoke. Close it, and transcribe nothing —
    /// running a model over ten seconds of room tone is how "Grazie a tutti"
    /// ends up in somebody's document.
    @Test func silenceWithNothingEverSaidIsDiscarded() {
        #expect(HandsFreeSilence.decide(elapsed: 10, tailIsSilent: true, heardSpeech: false,
                                        window: window) == .discard)
    }

    /// The real dictation that ended: deliver it. Throwing away speech somebody
    /// actually gave us is the worse failure of the two.
    @Test func silenceAfterSpeechFinishesTheDictation() {
        #expect(HandsFreeSilence.decide(elapsed: 30, tailIsSilent: true, heardSpeech: true,
                                        window: window) == .finish)
    }

    // MARK: When it must NOT fire

    /// Someone talking is not silence, however long they have been going.
    @Test func aLongDictationIsNeverCutOffWhileItIsStillSpeech() {
        #expect(HandsFreeSilence.decide(elapsed: 600, tailIsSilent: false, heardSpeech: true,
                                        window: window) == .keepListening)
    }

    /// Both conditions are required. Elapsed time alone would cut a pause at ten
    /// seconds even while the microphone is picking up a voice.
    @Test func timeAloneIsNotEnough() {
        #expect(HandsFreeSilence.decide(elapsed: 999, tailIsSilent: false, heardSpeech: false,
                                        window: window) == .keepListening)
    }

    /// And silence alone is not enough either — the first second of every
    /// recording is silent, and closing there would make one-tap unusable.
    @Test func silenceAloneIsNotEnough() {
        #expect(HandsFreeSilence.decide(elapsed: 0.5, tailIsSilent: true, heardSpeech: false,
                                        window: window) == .keepListening)
    }

    /// The boundary, from both sides.
    @Test func theWindowIsTheBoundary() {
        #expect(HandsFreeSilence.decide(elapsed: window, tailIsSilent: true, heardSpeech: false,
                                        window: window) == .discard)
        #expect(HandsFreeSilence.decide(elapsed: window - 0.001, tailIsSilent: true,
                                        heardSpeech: false, window: window) == .keepListening)
    }

    /// Zero turns the guard off for someone who would rather hold the microphone
    /// open. It must never fire then, not even after an hour of nothing.
    @Test func zeroDisablesIt() {
        #expect(HandsFreeSilence.decide(elapsed: 3600, tailIsSilent: true, heardSpeech: false,
                                        window: 0) == .keepListening)
    }
}

/// The two halves the guard leans on, which live in the recorder and the
/// transcriber. Neither is mockable, so what is checked here is that they agree
/// about the same audio — a guard that calls something silent while the
/// transcriber calls it speech would close the microphone mid-sentence.
@Suite struct SilenceAgreementTests {
    @Test func theRecorderAndTheTranscriberShareOneFloor() {
        #expect(AudioRecorder.speechFloor == 0.004)
        // The transcriber's own default, spelled out so a change to either side
        // fails here instead of drifting quietly.
        #expect(WhisperKitTranscriber.isSilent([Float](repeating: 0.001, count: 16_000)))
        #expect(!WhisperKitTranscriber.isSilent([Float](repeating: 0.02, count: 16_000)))
    }

    /// A tail shorter than a quarter of a second counts as silent, so the guard
    /// cannot be tricked into "speech" by a key click.
    @Test func aClickIsNotSpeech() {
        #expect(WhisperKitTranscriber.isSilent([Float](repeating: 0.5, count: 800)))
    }
}
