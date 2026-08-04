import Foundation
import os

#if canImport(WhisperKit)
@preconcurrency import WhisperKit

/// A download that reported success and left nothing behind.
///
/// It has its own error because the one it replaces was worse: the loader used
/// to fail later, complaining that a file was missing from a folder nobody had
/// been told was empty. This says what actually happened, at the moment it
/// happened.
enum ModelDownloadError: LocalizedError {
    case nothingArrived(model: String, folder: String)

    var errorDescription: String? {
        switch self {
        case let .nothingArrived(model, _):
            return "Non è stato possibile scaricare il modello \(model). Controlla la connessione e riprova."
        }
    }
}

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

    // Whisper-level vocabulary biasing. OFF unless somebody sets it — see the
    // long note in `transcribe`. Kept as a settable property rather than read
    // from settings inside the transcriber so a measurement can hold the text
    // constant: a probe that reads the app's own defaults measures whichever
    // domain the probe happens to run in, which has cost this project three
    // wrong answers.
    private let promptBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    var initialPrompt: String? {
        get { promptBox.withLock { $0 } }
        set { promptBox.withLock { $0 = newValue } }
    }

    // Two hypotheses were tested here on 2026-08-02 and both are dead; the
    // switches are gone so nobody re-runs them by accident.
    //
    // `firstTokenLogProbThreshold = nil` — the idea was that a prompt flattens
    // the first-token distribution below the −1.5 floor and WhisperKit abandons
    // the segment. Disabling the floor changed nothing: still empty.
    //
    // `usePrefillPrompt = false` — this one LOOKED like a fix, and it is the
    // reason the switch is deleted rather than kept. Transcription came back
    // perfect. It came back perfect because WhisperKit builds the prompt
    // tokens INSIDE the prefill branch (TextDecoder.prefillDecoderInputs, called
    // only `if options.usePrefillPrompt`), so turning the prefill off drops the
    // prompt on the floor. That run was the baseline wearing a costume.

    // How often a decode came back empty on audio that had speech in it — read
    // BEFORE the ISC-108 reload gets a chance to rescue it. The rescue is the
    // right behaviour for a dictation and the wrong one for a measurement: it
    // turns "this configuration breaks one decode in five" into a slightly
    // slower run with nothing to see. Counted here so a bench can ask.
    private let emptyBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Empties seen since the last call, and resets the counter.
    func takeEmptyBeforeRecovery() -> Int {
        emptyBox.withLock { n in let v = n; n = 0; return v }
    }

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
            //
            // The env var is not a CI flag here, it is the fix for a race that
            // this process loses every single time. `HubApi.snapshot` asks a
            // network monitor whether we are offline; that monitor starts life
            // with `isConnected = false` and only learns the truth from an
            // asynchronous NWPathMonitor callback. It is a lazy singleton
            // created on first use, which IS this call, so the first download of
            // a process always believes the machine is offline.
            //
            // And offline mode does not fail loudly. It checks that the models
            // folder exists, finds the OTHER models already sitting in it, and
            // returns that folder having downloaded nothing. So asking for a
            // model you do not have yet gets you a successful-looking return and
            // then `modelsUnavailable` when the loader looks for the files.
            // Two of the four models in Preferences could not be selected.
            //
            // `CI_DISABLE_NETWORK_MONITOR` is upstream's own early-out from that
            // check, and losing it costs nothing: we skip the download entirely
            // when the model is already on disk (above), and if the machine is
            // genuinely offline the HTTP call fails with a real network error,
            // which is a better answer than a silent no-op.
            setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)
            Self.report(.downloading(.speech, fraction: nil))
            folder = try await WhisperKit.download(variant: modelName, downloadBase: base) { progress in
                Self.report(.downloading(.speech, fraction: progress.fractionCompleted))
            }

            try Self.assertModelArrived(in: folder, model: modelName)
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

    /// Trust the files, not the return value.
    ///
    /// `WhisperKit.download` returning a URL only means no error was raised, and
    /// the bug this exists for is precisely a path where no error is raised and
    /// no files arrive. The marker is the encoder, because it is the one piece
    /// no variant of this model can load without.
    static func assertModelArrived(in folder: URL, model: String) throws {
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: encoder.path) else {
            Log.write("download di \(model) finito senza file in \(folder.path)")
            throw ModelDownloadError.nothingArrived(model: model, folder: folder.path)
        }
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

        // And if there is no speech in there at all, do not ask.
        //
        // The phrase list below catches the hallucinations Whisper is FAMOUS for,
        // which is pattern-matching: feed it pure silence and it will invent
        // something, and anything not on the list gets through. Until now
        // `trimSilence` explicitly handed all-silence audio over untouched
        // (`guard start < end else { return s }`), so the one case that
        // guarantees an invention was the one case with no defence. Deciding
        // this from the AUDIO instead of from the words is the only structural
        // answer. Reported on 2026-07-31, watching a competitor do
        // exactly this.
        if Self.isSilent(samples) {
            Log.write("recording was silent — not transcribed")
            return TranscriptionResult(text: "", detectedLanguage: forced)
        }

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

        // `chunkingStrategy` stays UNSET, and that is a measured decision rather
        // than an omission — do not "fix" it by turning `.vad` on.
        //
        // The problem is real: on audio longer than one 30-second window,
        // WhisperKit's blind sequential seek drops words with no error and no
        // log line. Measured 2026-08-04, the same 70-second file decoded sixteen
        // times gave 159 words fourteen times, 158 once and 150 once — identical
        // audio, three different answers, which is what a dictation quietly
        // losing a sentence looks like from outside.
        //
        // `.vad` was the obvious candidate and it is far WORSE: same file, same
        // sixteen passes, 106 words in fourteen of them. It silently deletes
        // three whole utterances, the ones straddling the first window boundary.
        // Not a loudness effect — those three are the LOUDEST in the file
        // (RMS 0.021, 0.019, 0.017 against 0.011 for the quietest, which
        // survives). The defect is positional, it sits at the window seam, and
        // the VAD chunker only makes it easier to hit.
        //
        // Bench, still standing, ~30 seconds a pass:
        //   Kalamos --selftest-engine <70s.wav> --engine whisper --lang it \
        //     --modello openai_whisper-large-v3-v20240930_turbo --ripeti 8

        // Whisper-level vocabulary biasing via `options.promptTokens`: OFF
        // unless `initialPrompt` was set, and nothing in the app sets it yet.
        //
        // MEASURED on 2026-08-02 — 16 recordings, 5 passes, both language
        // modes: with the prompt on, the Turbo model returns an empty
        // transcription 160 times out of 160. Forcing the language does not help
        // — that hypothesis died here. But the same prompt on
        // `openai_whisper-base` works and repairs the exact failure it was
        // written for ("comandasse" → "Command S"), which means the prompt
        // tokens are not the problem: the Turbo decode is.
        //
        // It is a known WhisperKit bug — issue #372, fixed by PR #514 on
        // 2026-07-30: the end-of-text check fires DURING the forced prompt
        // prefill, so the segment ends before the first real token. The fix is
        // in no released tag, and this package is held at 0.14.1 by a dependency
        // wall, so the switch stays off until that moves.
        //
        // And it would not be free even then: on `base` the prompt turned the
        // ordinary Italian "comandasse" into "commandasse" and emptied two
        // clips. So whoever turns this on measures the ordinary sentences
        // first, not just the shortcuts — the failure that matters is the one
        // that damages speech the vocabulary has nothing to do with.
        //
        // The encoding follows WhisperKit's own reference
        // (WhisperKitCLI/TranscribeCLI.swift): a leading space, and every
        // special token filtered out. A Whisper prompt is prior context, not an
        // instruction, so the text has to read like ordinary speech — a
        // "Glossary:" label makes the model believe it is transcribing a
        // glossary and degenerate on everything else.
        //
        // The cap is 200 tokens because the prompt eats the same 448-token
        // decoder window the transcription needs.
        if let prompt = initialPrompt,
           !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
           let tokenizer = pipe.tokenizer {
            let encoded = tokenizer
                .encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !encoded.isEmpty {
                let tokens = Array(encoded.suffix(200))
                options.promptTokens = tokens
                // The round-trip is logged because "the tokens are wrong" was a
                // live suspect for a month. They are not: the decode comes back
                // byte-identical to what went in.
                Log.write("vocab prompt: \(tokens.count) tokens"
                          + " · round-trip=\"\(tokenizer.decode(tokens: tokens))\"")
            }
        }

        // ISC-163 — four candidate fixes were measured here and all four lose.
        // The decode is handed the whole recording, which is what it always was.
        //
        // The defect is real: on audio longer than Whisper's 30-second window the
        // decode is not deterministic and quietly drops words. Same 120-second
        // file, eight passes: 170 · 162 · 142 · 168 · 160 · 162 · 160 · 170.
        // A dictation losing a sentence looks exactly like this from outside.
        //
        // What was tried, with the bench in 03-Plans/kalamos-finestre:
        //   · `chunkingStrategy = .vad` — far worse. 106 words instead of 159,
        //     three whole utterances deleted, the ones straddling the first
        //     window boundary. Not loudness: those three are the LOUDEST in the
        //     file (RMS 0.021/0.019/0.017 against 0.011 for the quietest, which
        //     survives).
        //   · Cutting the audio ourselves at pauses, pieces all inside the
        //     window — it worked as designed (five pieces, no cut through
        //     speech, proven by test) and the decode still came out worse:
        //     154 words on average against 162 whole.
        //   · `temperatureFallbackCount = 0` — perfectly deterministic and
        //     worse every time: 135 words, eight passes out of eight. Those
        //     random re-decodes are RESCUING text, not destroying it.
        //     Raising it instead does nothing: 10 → 159 average, 20 → 154.
        //   · `noSpeechThreshold` 0.6 → 0.99 — 161 average against 159, inside
        //     the noise, and it buys that by making the model likelier to
        //     transcribe silence, which this app has fought before.
        //
        // So the seam is not the cause and the knobs are not the cure. The next
        // idea needs the real audio of a failure, which is what the archive
        // (ISC-161) now keeps.
        var results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var raw = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var text = Self.stripHallucinations(raw)
        // Diagnostic: distinguishes "Whisper produced nothing" from "Whisper
        // produced a phrase we stripped as a hallucination".
        if text.isEmpty { Log.write("empty result — raw before filter: \"\(raw)\"") }

        // ISC-108 — an empty result is a stuck pipeline, so replace the pipeline.
        //
        // The first version of this asked the SAME loaded model a second time.
        // The log of 2026-08-01 shows why that is useless: at 15:55:46
        // the empty result, the retry, and its failure are all stamped the same
        // second — a real decode takes about a second, so the second attempt
        // never decoded anything. It answered instantly and emptily, twice. Then
        // he quit and reopened the app at 15:56:17 and dictation worked again.
        // The same shape appears at 19:19:29 → restart three seconds later.
        //
        // So it is not a coin flip that can be re-tossed: once the pipeline goes
        // bad it stays bad for the life of the process, and the only thing that
        // has ever cleared it is loading the model again. This does by itself
        // what he was doing by hand. About one dictation in thirty was lost this
        // way, in silence, with nothing on screen to say so.
        //
        // Reloading costs a few seconds. Losing what you just said costs more.
        if raw.isEmpty {
            emptyBox.withLock { $0 += 1 }
            Log.write("empty result on non-silent audio — reloading the speech model")
            unload()
            try await prepare()
            if let fresh = pipeBox.withLock({ $0 }) {
                results = try await fresh.transcribe(audioArray: samples, decodeOptions: options)
                raw = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text = Self.stripHallucinations(raw)
                Log.write(raw.isEmpty ? "still empty after reloading — giving up"
                                      : "recovered after reloading: \"\(text)\"")
            }
        }

        // If the caller forced a language, that IS the source language (we told
        // Whisper to decode in it). Otherwise map the detected code/name and
        // validate to the enabled set (ISC-28).
        var detected = forced ?? Self.mapLanguage(results.first?.language, allowed: allowedLanguages)

        // ISC-111 — when the words contradict the label, decode again in the
        // language the words are actually in.
        //
        // The "Amen": at 01:21 on 2026-08-01 Whisper marked an entirely Italian
        // sentence `lang=en`, decoded it with an English prior, and stuck a
        // trailing-silence hallucination on the end. Six of 325 dictations were
        // marked `lang=en`, two of them plainly Italian.
        //
        // Putting "amen" on the hallucination list would have hidden that one
        // instance. A blacklist only catches what it already contains, and the
        // next wrong-language decode invents a different word — the fault is the
        // language decision, so this is where it is repaired.
        //
        // Only when we let Whisper choose (a forced language is the user's
        // instruction, not a guess to second-guess), only when the hint is
        // confident, and only into a language the user has enabled.
        if forced == nil,
           let corrected = LanguageHint.contradicts(detected, text: text),
           allowedLanguages.contains(corrected) {
            Log.write("language mismatch: whisper said \(detected?.rawValue ?? "?")"
                      + " but the words look \(corrected.rawValue) — decoding again")
            var second = options
            second.language = corrected.rawValue
            second.detectLanguage = false
            let redone = try await pipe.transcribe(audioArray: samples, decodeOptions: second)
            let redoneRaw = redone.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let redoneText = Self.stripHallucinations(redoneRaw)
            // Keep the first pass if the second one came back with nothing:
            // a worse transcription is still better than none.
            if !redoneText.isEmpty {
                text = redoneText
                detected = corrected
                Log.write("re-decoded as \(corrected.rawValue): \"\(text)\"")
            } else {
                Log.write("re-decode came back empty — keeping the first pass")
            }
        }
        scheduleIdleUnload()
        return TranscriptionResult(text: text, detectedLanguage: detected)
    }

    /// True when a recording holds no speech worth transcribing.
    ///
    /// Two questions, because either alone is wrong. **Loudness**: room tone sits
    /// well under this floor while even a whispered word clears it, so the
    /// threshold is deliberately far below "quiet speech" — swallowing something
    /// you actually said would be a much worse failure than transcribing a
    /// breath. **Length**: what survives the trim has to last long enough to be
    /// a word; a double-tap that catches the key click leaves a few milliseconds
    /// of noise that is loud but empty.
    static func isSilent(_ s: [Float], rmsFloor: Float = 0.004,
                         minimumVoicedSeconds: Float = 0.25,
                         sampleRate: Float = 16_000) -> Bool {
        guard !s.isEmpty else { return true }
        if Float(s.count) / sampleRate < minimumVoicedSeconds { return true }

        // The LOUDEST quarter-second, not the average of the whole recording.
        //
        // The average answers "is this mostly speech?"; the question here is "is
        // there any speech in here at all?" — a different question, and the gap
        // between the two grows with the length of the recording. Measured
        // 2026-08-04: real speech at a normal level, surrounded by enough
        // thinking-time, averages below this floor, and the whole dictation was
        // discarded in 82 ms without the decoder ever running. `trimSilence`
        // hides it whenever the quiet sits at the ENDS, which is why this
        // survived until a recording turned up with the quiet in the middle.
        let window = max(1, Int(minimumVoicedSeconds * sampleRate))
        let hop = max(1, window / 2)   // overlapped, so a short word cannot fall in a seam
        let floorEnergy = rmsFloor * rmsFloor * Float(window)

        var start = 0
        while start + window <= s.count {
            var energy: Float = 0
            for i in start ..< (start + window) { energy += s[i] * s[i] }
            if energy >= floorEnergy { return false }   // found speech; stop looking
            start += hop
        }
        return true
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
