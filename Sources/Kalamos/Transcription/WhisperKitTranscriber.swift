import Foundation
import os

#if canImport(WhisperKit)
@preconcurrency import WhisperKit

/// WhisperKit-backed transcriber. Runs entirely on-device (Core ML / ANE / GPU).
/// Auto-detects the spoken language and constrains it to the enabled set.
///
/// `@unchecked Sendable`: the only mutable state is the cached `pipe`, guarded
/// by `lock`. WhisperKit itself is not `Sendable`, so we keep it private and
/// never hand it across isolation boundaries.
final class WhisperKitTranscriber: Transcriber, @unchecked Sendable {
    // Lock-protected so `setModel` can swap it from the main actor while a
    // background transcription task reads it (the lock is never held across await).
    private let nameBox: OSAllocatedUnfairLock<String>
    // Async-safe lock-protected cache (the lock is never held across `await`).
    private let pipeBox = OSAllocatedUnfairLock<WhisperKit?>(initialState: nil)
    private let idleBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(modelName: String) { self.nameBox = OSAllocatedUnfairLock(initialState: modelName) }

    /// Switch the speech model. Unloads the current pipeline; the new variant
    /// downloads (first time) / loads on the next `transcribe`. No-op if unchanged.
    func setModel(_ name: String) async {
        guard nameBox.withLock({ $0 }) != name else { return }
        nameBox.withLock { $0 = name }
        pipeBox.withLock { $0 = nil }   // force reload with the new variant
        Log.write("Whisper model set to \(name) (loads on next dictation)")
    }

    func prepare() async throws {
        if pipeBox.withLock({ $0 }) != nil { scheduleIdleUnload(); return }

        let modelName = nameBox.withLock { $0 }
        let base = ModelStorage.base
        // WhisperKit lays models out as <base>/models/argmaxinc/whisperkit-coreml/<variant>/
        let cached = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true)
        let marker = cached.appendingPathComponent("AudioEncoder.mlmodelc")

        let folder: URL
        if FileManager.default.fileExists(atPath: marker.path) {
            // Already downloaded — load directly, NO network, NO re-download.
            folder = cached
        } else {
            // First run: download fully (progress in the menu bar), into the
            // persistent App Support base so it's reused on every later launch.
            Self.report(.downloading(.speech, fraction: nil))
            folder = try await WhisperKit.download(variant: modelName, downloadBase: base) { progress in
                Self.report(.downloading(.speech, fraction: progress.fractionCompleted))
            }
        }

        Self.report(.loading(.speech))
        // Set downloadBase too so the text tokenizer (openai/whisper-large-v3,
        // ~3 MB) also lands in App Support instead of ~/Documents (WhisperKit:
        // tokenizerFolder = config.downloadBase). Keeps ~/Documents untouched.
        let config = WhisperKitConfig(
            model: modelName, downloadBase: base, modelFolder: folder.path, download: false)
        let built = try await WhisperKit(config)
        pipeBox.withLock { $0 = built }
        scheduleIdleUnload()
    }

    // Unload the speech model after idle to free ~1.5 GB. Reloads (~few s) on the
    // next dictation. Timer resets on each use → no cost during active use.
    private func scheduleIdleUnload() {
        guard let seconds = Tuning.idleUnloadSeconds else {                 // nil = never
            let old = idleBox.withLock { box -> Task<Void, Never>? in let p = box; box = nil; return p }
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
        pipeBox.withLock { $0 = nil }
        Log.write("Whisper model unloaded (idle) — RAM freed")
    }

    private static func report(_ status: DictationStatus) {
        Task { @MainActor in AppState.shared.status = status }
    }

    func transcribe(_ samples: [Float],
                    allowedLanguages: Set<Language>,
                    forced: Language?) async throws -> TranscriptionResult {
        try await prepare()
        // `prepare` may have put "opening the speech model" on screen. The model
        // is open now and the app is back to what the user asked for.
        Self.report(.transcribing)
        guard let pipe = pipeBox.withLock({ $0 }) else {
            return TranscriptionResult(text: "", detectedLanguage: nil)
        }

        // Trim leading/trailing silence — Whisper hallucinates phrases like
        // "thank you"/"grazie" on trailing silence (trained on YouTube captions).
        let samples = Self.trimSilence(samples)

        var options = DecodingOptions()
        if let forced {
            options.language = forced.rawValue
            options.detectLanguage = false
        } else {
            options.detectLanguage = true   // auto-detect
            options.language = nil
        }
        options.task = .transcribe          // keep words in the spoken language
        options.usePrefillPrompt = true

        // NOTE: Whisper-level vocabulary biasing via `options.promptTokens` is
        // DELIBERATELY DISABLED. Empirically (kalamos.log 2026-07-01) setting
        // promptTokens — even a 3-token prompt — makes this model+config return
        // an EMPTY transcription and mis-detect the language, deterministically,
        // regardless of prompt content (dropping the old "Glossary:" prime did
        // NOT help). The prepended prompt shifts the start-of-transcript token to
        // a non-zero prefill index and the decode degenerates to end-of-text.
        // Vocabulary still works: the LLM cleanup/translation prompts enforce the
        // custom spellings (Vocabulary.list → MLXFormatter/MLXTranslator). Do not
        // re-enable promptTokens without a live transcription test proving the
        // empty-output regression is gone.

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.stripHallucinations(raw)
        // Diagnostic: distinguishes "Whisper produced nothing" from "Whisper
        // produced a phrase we stripped as a hallucination".
        if text.isEmpty { Log.write("empty result — raw before filter: \"\(raw)\"") }

        // If the caller forced a language, that IS the source language (we told
        // Whisper to decode in it). Otherwise map the detected code/name and
        // validate to the enabled set (ISC-28).
        let detected = forced ?? Self.mapLanguage(results.first?.language, allowed: allowedLanguages)
        scheduleIdleUnload()
        return TranscriptionResult(text: text, detectedLanguage: detected)
    }

    /// Drop near-silent leading/trailing samples (keeps a small pad).
    private static func trimSilence(_ s: [Float], threshold: Float = 0.008) -> [Float] {
        guard !s.isEmpty else { return s }
        var end = s.count
        while end > 0 && abs(s[end - 1]) < threshold { end -= 1 }
        var start = 0
        while start < end && abs(s[start]) < threshold { start += 1 }
        guard start < end else { return s }   // all silence → leave as-is
        let pad = 1_600                        // 0.1 s at 16 kHz
        return Array(s[max(0, start - pad) ..< min(s.count, end + pad)])
    }

    /// Known Whisper trailing-silence hallucinations (IT/EN/FR).
    private static let hallucinations: [String] = [
        "thank you", "thanks for watching", "thank you for watching", "thanks",
        "please subscribe", "subscribe", "bye",
        "grazie", "grazie per la visione", "grazie a tutti", "grazie per aver guardato",
        "grazie mille", "sottotitoli e revisione a cura di", "sottotitoli",
        "merci", "merci d'avoir regardé", "merci beaucoup", "abonnez-vous",
        "amara.org",
    ]

    /// Strip a trailing standalone hallucination phrase (e.g. "… 3. Grazie.").
    private static func stripHallucinations(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lower = t.lowercased()
            for phrase in hallucinations {
                for punct in ["", ".", "!", "?", "…"] {
                    let cand = phrase + punct
                    guard lower.hasSuffix(cand) else { continue }
                    let cut = t.index(t.endIndex, offsetBy: -cand.count)
                    let boundary = cut == t.startIndex
                        || [" ", "\n", ",", "."].contains(String(t[t.index(before: cut)]))
                    if boundary {
                        t = String(t[..<cut]).trimmingCharacters(
                            in: CharacterSet(charactersIn: " ,.;:\n…"))
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }
        return t
    }

    private static func mapLanguage(_ raw: String?, allowed: Set<Language>) -> Language? {
        guard let raw = raw?.lowercased() else { return nil }
        let code: String
        switch raw {
        case "italian", "italiano": code = "it"
        case "english", "inglese":  code = "en"
        case "french", "francese", "français": code = "fr"
        default: code = raw          // already an ISO code like "it"
        }
        guard let lang = Language(rawValue: code), allowed.contains(lang) else { return nil }
        return lang
    }
}
#endif
