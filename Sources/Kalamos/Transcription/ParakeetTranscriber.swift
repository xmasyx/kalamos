import Foundation
import os

#if canImport(FluidAudio)
@preconcurrency import FluidAudio

/// The second engine: NVIDIA Parakeet TDT 0.6B v3, on-device via CoreML.
///
/// Added 2026-08-01 because the bench said something the first bench had hidden.
/// Whisper's better average came from ONE clip out of six — the one with his
/// jargon in it. On the other five, measured over ten passes each:
///
///     senza la clip dei nomi   Whisper 8.0%   Parakeet 6.8%   Cohere 6.0%
///     secondi per clip         Whisper 0.812  Parakeet 0.080  (±0.435 vs ±0.012)
///     trascrizioni vuote       Whisper 2/60   Parakeet 0/60
///     peso sul disco           Whisper 1.5 GB Parakeet 461 MB
///
/// So on ordinary Italian this is the better engine, ten times faster, a third of
/// the weight, and it has never once returned nothing. What it loses is rare
/// proper nouns — iTerm, LifeOS, endomidollare — which is what `VocabularyRepair`
/// is now for.
///
/// **It is multilingual and needs no telling.** FluidAudio's v3 vocabulary is
/// 8192 tokens against v2's 1024, and its language list has 28 entries (Latin,
/// Cyrillic and Greek). The `language:` parameter is NOT a language selector —
/// it is a script filter, and passing nil is the normal way to run it.
///
/// **Architecturally it is a transducer, not an encoder-decoder**, and that one
/// fact explains all four numbers above: no autoregressive language-model decoder
/// means no big text prior (so rare names suffer), one pass over the frames
/// instead of token-by-token generation (so it is fast), and an output that is
/// emitted per frame rather than chosen by a decoder that can decide to stop —
/// which is why it structurally cannot return the empty string on speech, the way
/// Whisper does about once in thirty dictations.
final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    private let managerBox = OSAllocatedUnfairLock<AsrManager?>(initialState: nil)
    private let idleBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Whether FluidAudio's cache already holds the model. Its own directory,
    /// not ours — checked by the file the loader itself writes there.
    private static var modelsAreOnDisk: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        guard let support else { return false }
        let config = support
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3/config.json")
        return FileManager.default.fileExists(atPath: config.path)
    }

    func prepare() async throws {
        if managerBox.withLock({ $0 }) != nil { scheduleIdleUnload(); return }
        // FluidAudio caches under its own Application Support directory and
        // reports no progress fraction, so the status is the indeterminate one.
        // 461 MB the first time, nothing afterwards — and *nothing afterwards* is
        // the half this line used to get wrong: it announced a download on every
        // single prepare, cached or not. Same defect as the cleanup model's, found
        // in the same sweep on 2026-08-02.
        if Self.modelsAreOnDisk {
            Self.report(.loading(.speech))
        } else {
            Self.report(.downloading(.speech, fraction: nil))
        }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        Self.report(.loading(.speech))
        managerBox.withLock { $0 = AsrManager(config: .default, models: models) }
        scheduleIdleUnload()
        Log.write("Parakeet TDT v3 ready")
    }

    func transcribe(_ samples: [Float],
                    allowedLanguages: Set<Language>,
                    forced: Language?) async throws -> TranscriptionResult {
        try await prepare()
        Self.report(.transcribing)
        guard let manager = managerBox.withLock({ $0 }) else {
            return TranscriptionResult(text: "", detectedLanguage: nil)
        }

        // The same silence gate Whisper gets, and for the same reason: an engine
        // asked to transcribe a quiet room will invent something. Shared rather
        // than reimplemented — two silence thresholds that drift apart would be
        // two different apps depending on which engine you picked.
        if WhisperKitTranscriber.isSilent(samples) {
            Log.write("recording was silent — not transcribed")
            return TranscriptionResult(text: "", detectedLanguage: forced)
        }

        // A fresh decoder state per dictation. Carrying one over leaks the last
        // token of the previous dictation into the first word of this one.
        var state = try TdtDecoderState()
        // The script hint, built from the parameter's own type rather than named.
        // FluidAudio's module contains a `struct FluidAudio`, which shadows the
        // module name, so `FluidAudio.Language` does not compile — and plain
        // `Language` in this file is ours. Letting the call site infer it is the
        // way out, and it works because both enums spell their raw values the
        // same ("it"/"en"/"fr").
        //
        // Not a decode language: v3 has ONE multilingual vocabulary (8192 tokens
        // against v2's 1024) and picks by itself, across 28 languages. This only
        // says which script to prefer, all three of ours are Latin, so it is
        // close to a no-op — passed because a free hint is worth passing.
        let result = try await manager.transcribe(
            samples, decoderState: &state,
            language: forced.flatMap { .init(rawValue: $0.rawValue) })
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleIdleUnload()

        // Parakeet reports no language of its own — it decodes every language it
        // knows into one vocabulary. So the label comes from the user's choice
        // when there is one, and otherwise from the same word-marker hint that
        // repairs Whisper's wrong labels (ISC-111). `nil` when neither is sure:
        // downstream reads that as "leave it alone", which is the honest answer.
        let detected = forced ?? LanguageHint.guess(text).flatMap {
            allowedLanguages.contains($0) ? $0 : nil
        }
        Log.write("parakeet: lang=\(detected?.rawValue ?? "?") text=\"\(text)\"")
        return TranscriptionResult(text: text, detectedLanguage: detected)
    }

    // MARK: Idle unload

    private func scheduleIdleUnload() {
        guard let seconds = Tuning.idleUnloadSeconds else {
            let old = idleBox.withLock { box -> Task<Void, Never>? in
                let p = box; box = nil; return p
            }
            old?.cancel()
            return
        }
        let newTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            self?.unload()
        }
        let old = idleBox.withLock { box -> Task<Void, Never>? in
            let previous = box; box = newTask; return previous
        }
        old?.cancel()
    }

    private func unload() {
        managerBox.withLock { $0 = nil }
        Log.write("Parakeet unloaded (idle) — RAM freed")
    }

    private static func report(_ status: DictationStatus) {
        Task { @MainActor in AppState.shared.status = status }
    }
}
#endif
