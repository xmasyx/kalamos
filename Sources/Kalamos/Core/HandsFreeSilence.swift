import Foundation

/// When a hands-free dictation should close the microphone by itself.
///
/// **The failure this exists for.** In one-tap mode every short tap of the
/// trigger starts listening, and only another tap stops it — so a key brushed by
/// accident opens the microphone and leaves it open. On 2026-08-02 his log
/// showed seven recordings he never asked for in twenty-six seconds, one of them
/// sixteen seconds long, three transcribed as the classic silence hallucination
/// ("Grazie a tutti"). The trade-off was written into one-tap the day it was
/// built; what was missing was a floor under it.
///
/// **Two outcomes, not one, and the difference is what makes this safe.** After
/// the window of silence: if you had spoken, the dictation finishes normally and
/// your text is delivered — throwing away real speech would be the worse
/// failure. If nothing was ever said, the recording is discarded without being
/// transcribed: no text, no model run, and no hallucinated "thanks everyone"
/// from ten seconds of room tone.
///
/// A pure function so both poles are testable without a microphone.
enum HandsFreeSilence {
    /// His number, 2026-08-02. Long enough to pause and think mid-dictation,
    /// short enough that a key brushed by accident is a nuisance rather than an
    /// open microphone.
    static let defaultSeconds: Double = 10

    enum Outcome: Equatable {
        /// Not silent long enough yet.
        case keepListening
        /// Silence after speech — deliver what was said.
        case finish
        /// Silence and nothing was ever said — close, transcribe nothing.
        case discard
    }

    static func decide(elapsed: Double, tailIsSilent: Bool, heardSpeech: Bool,
                       window: Double = HandsFreeSilence.defaultSeconds) -> Outcome {
        // The window has to have elapsed AND the tail be silent. Elapsed alone
        // would cut someone off at ten seconds of perfectly good dictation.
        guard window > 0, elapsed >= window, tailIsSilent else { return .keepListening }
        return heardSpeech ? .finish : .discard
    }
}
