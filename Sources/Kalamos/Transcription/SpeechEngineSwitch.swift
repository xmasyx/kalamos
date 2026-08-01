import Foundation
import os

/// Which model does the listening.
///
/// Two, not one, since 2026-08-01: they are good at different things and the
/// difference is measured, not a matter of taste. Whisper keeps his jargon,
/// Parakeet is ten times faster and better on ordinary Italian.
enum SpeechEngine: String, CaseIterable, Sendable {
    case whisper
    case parakeet

    var title: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    /// One line, in his language, saying what the trade actually is. Written from
    /// the bench numbers rather than from adjectives: an engine picker whose
    /// options read "balanced" and "fast" tells you nothing you can decide with.
    @MainActor var note: String {
        switch self {
        case .whisper:
            return L.t("più preciso sui tuoi nomi · 1,5 GB · ~0,8 s",
                       "better on your names · 1.5 GB · ~0.8 s",
                       "meilleur sur vos noms · 1,5 Go · ~0,8 s")
        case .parakeet:
            return L.t("10× più veloce, meglio sull'italiano comune · 461 MB · ~0,08 s",
                       "10× faster, better on ordinary speech · 461 MB · ~0.08 s",
                       "10× plus rapide, meilleur sur la langue courante · 461 Mo · ~0,08 s")
        }
    }
}

/// Holds both engines and speaks for whichever one is selected.
///
/// A wrapper rather than a mutable field on the controller: `DictationController`
/// captures its transcriber into a detached task before every dictation, so a
/// field that changes underneath is a race with the thing being switched. Here
/// the switch is one locked write, and a dictation already in flight finishes on
/// the engine it started with.
///
/// Both instances exist from launch and cost nothing until used — neither loads a
/// model before its first `prepare()`, so the unselected one is an empty object.
final class SpeechEngineSwitch: Transcriber, @unchecked Sendable {
    private let selected: OSAllocatedUnfairLock<SpeechEngine>
    private let whisper: Transcriber
    private let parakeet: Transcriber

    init(engine: SpeechEngine, whisper: Transcriber, parakeet: Transcriber) {
        self.selected = OSAllocatedUnfairLock(initialState: engine)
        self.whisper = whisper
        self.parakeet = parakeet
    }

    var engine: SpeechEngine { selected.withLock { $0 } }

    private var active: Transcriber {
        selected.withLock { $0 } == .whisper ? whisper : parakeet
    }

    func use(_ engine: SpeechEngine) {
        guard selected.withLock({ $0 }) != engine else { return }
        selected.withLock { $0 = engine }
        Log.write("speech engine set to \(engine.rawValue)")
    }

    func prepare() async throws { try await active.prepare() }

    func transcribe(_ samples: [Float],
                    allowedLanguages: Set<Language>,
                    forced: Language?) async throws -> TranscriptionResult {
        try await active.transcribe(samples, allowedLanguages: allowedLanguages, forced: forced)
    }

    /// The variant picker is Whisper's alone — Parakeet ships as one model — so
    /// this goes to Whisper whichever engine is live. Sending it to `active`
    /// instead would silently drop the choice whenever Parakeet was selected, and
    /// the setting would show a model nobody had been told about.
    func setModel(_ name: String) async { await whisper.setModel(name) }
}
