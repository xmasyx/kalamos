import Foundation
import os

/// Which model does the listening.
///
/// Two, not one, since 2026-08-01: they are good at different things and the
/// difference is measured, not a matter of taste. Whisper keeps his jargon,
/// Parakeet is ten times faster and better on ordinary Italian.
///
/// Three since 2026-08-05, and the third is not a third model: `whispercpp`
/// carries the SAME Whisper large-v3-turbo weights as `whisper`, on a different
/// machine (C and Metal instead of Core ML). It is here because two things are
/// only possible there — a vocabulary that reaches the decoder BEFORE it guesses
/// (WhisperKit returns an empty transcription with its prompt on, 48 times out of
/// 48, upstream issue #372), and a decode that does not drift on long audio (200
/// passes, 200 identical texts, against swings of 11 and 31 words on the same
/// files the same afternoon). Bench: `03-Plans/kalamos-whispercpp/REFERTO.md`.
enum SpeechEngine: String, CaseIterable, Sendable {
    case whisper
    case parakeet
    case whispercpp

    var title: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        case .whispercpp: return "Whisper.cpp"
        }
    }

    /// The one number that is true on every Mac: how big the download is.
    ///
    /// It used to carry a time as well — "0,66 s" against "0,10 s" — and those
    /// were measured on ONE machine, his. Printed next to somebody else's engine
    /// they are an invention, which is the same rule the setup page is built on:
    /// facts read from the machine, never a timing predicted for it. Taken off on
    /// his instruction, 2026-08-02: *"that is calculated on my computer, so it
    /// must not stay there"*. The qualitative difference the measurements DID
    /// establish stays in the sentence above the row, where it belongs.
    ///
    /// Earlier history, kept because it is the same lesson twice: the note once
    /// claimed Whisper was "more accurate on your names", and by the evening of
    /// 2026-08-01 the vocabulary repair had erased that difference — both engines
    /// land on 150/150 of his terms. A chip that claims an advantage the
    /// measurement has since erased is worse than a chip that says nothing.
    ///
    /// It used to read "più preciso sui tuoi nomi" against "10× più veloce,
    /// meglio sull'italiano comune", and by the evening of 2026-08-01 the first
    /// half was no longer true: with the vocabulary repair both engines land on
    /// 150/150 of his terms. A chip that claims an advantage the measurement has
    /// since erased is worse than a chip that says nothing. Seconds are the
    /// in-app figures with the language forced, which is his configuration.
    /// Whisper.cpp reads its real size off the disk once the file is there, and
    /// falls back to the download size before that. Not decoration: this engine
    /// is the one whose model can sit NEXT TO the Core ML one, so the number the
    /// user needs is the one that is actually on their disk right now.
    @MainActor var note: String {
        switch self {
        case .whisper: return "1,5 GB"
        case .parakeet: return "461 MB"
        case .whispercpp:
            let path = WhisperCppTranscriber.modelPath.path
            let onDisk = (try? FileManager.default
                .attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            return Self.gb(onDisk ?? WhisperCppTranscriber.modelBytes)
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB]
        return f.string(fromByteCount: bytes)
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
    private let whispercpp: Transcriber

    init(engine: SpeechEngine, whisper: Transcriber, parakeet: Transcriber,
         whispercpp: Transcriber) {
        self.selected = OSAllocatedUnfairLock(initialState: engine)
        self.whisper = whisper
        self.parakeet = parakeet
        self.whispercpp = whispercpp
    }

    var engine: SpeechEngine { selected.withLock { $0 } }

    /// Exhaustive on purpose. The old form was `== .whisper ? whisper : parakeet`,
    /// which is a default branch in disguise: adding a case would have routed it
    /// silently to Parakeet and the compiler would have said nothing.
    private var active: Transcriber {
        switch selected.withLock({ $0 }) {
        case .whisper: return whisper
        case .parakeet: return parakeet
        case .whispercpp: return whispercpp
        }
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

    /// Al motore ATTIVO, non a tutti: il prompt è una funzione che solo
    /// whisper.cpp ha, e mandarlo anche agli altri due sarebbe scrivere in un
    /// campo che nessuno legge, cioè la premessa perfetta per credere un domani
    /// che sia acceso quando non lo è.
    func setVocabulary(_ terms: [String]) { active.setVocabulary(terms) }
}
