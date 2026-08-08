import Foundation

/// Result of a transcription: text plus the detected language (when known).
struct TranscriptionResult: Equatable, Sendable {
    let text: String
    let detectedLanguage: Language?
}

/// Abstracts the speech-to-text engine so it can be swapped (WhisperKit,
/// a mock for offline development, or a future engine). `Sendable` so the
/// main-actor controller can hand it off to a background transcription task.
protocol Transcriber: Sendable {
    /// Load the underlying model. Safe to call more than once.
    func prepare() async throws

    /// Transcribe 16 kHz mono Float32 samples.
    /// - Parameters:
    ///   - samples: audio from `AudioRecorder`.
    ///   - allowedLanguages: constrain detection to this set (v1: it/en/fr).
    ///   - forced: skip detection and decode as this language (nil = auto-detect).
    func transcribe(
        _ samples: [Float],
        allowedLanguages: Set<Language>,
        forced: Language?
    ) async throws -> TranscriptionResult

    /// Switch the underlying speech model at runtime (menu picker). Default no-op.
    func setModel(_ name: String) async

    /// The personal vocabulary, used as prior context BEFORE the decoder
    /// guesses — but never as a whole list: see `VocabularyPrompt`, a long prompt
    /// damages the very terms it contains.
    ///
    /// Two engines answer it, `WhisperCppTranscriber` since 2026-08-05 and
    /// `WhisperKitTranscriber` since 2026-08-08, when WhisperKit 1.1.0 was
    /// measured to have fixed the defect that made this channel return an empty
    /// transcription 48 times out of 48 (upstream issue #372). Parakeet has no
    /// such channel, so the default stays a no-op.
    ///
    /// Passed in rather than read from `Vocabulary` inside the engine, so a bench
    /// can hold the text constant — a probe that reads the app's own defaults
    /// measures whichever domain the probe happens to run in, and that has cost
    /// this project three wrong answers.
    func setVocabulary(_ terms: [String])
}

extension Transcriber {
    func setModel(_ name: String) async {}
    func setVocabulary(_ terms: [String]) {}
}

/// No-model transcriber so the full pipeline (hotkey → audio → format →
/// inject) is runnable offline and in tests, before WhisperKit downloads.
final class MockTranscriber: Transcriber {
    let cannedText: String
    let cannedLanguage: Language?

    init(cannedText: String = "this is a kalamos mock transcription",
         cannedLanguage: Language? = .english) {
        self.cannedText = cannedText
        self.cannedLanguage = cannedLanguage
    }

    func prepare() async throws {}

    func transcribe(_ samples: [Float],
                    allowedLanguages: Set<Language>,
                    forced: Language?) async throws -> TranscriptionResult {
        TranscriptionResult(text: cannedText, detectedLanguage: forced ?? cannedLanguage)
    }
}
