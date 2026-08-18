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

    // Il vocabolario personale, acceso su questo motore dal 2026-08-08.
    //
    // È lo stesso canale di whisper.cpp e la stessa disciplina: NON si riversa
    // la lista intera nel prompt, si decodifica una volta e si ri-decodifica con
    // i soli termini che la prima passata sembra aver sbagliato (`VocabularyPrompt`).
    // La lista arriva da fuori, come per gli altri motori, così un banco può
    // tenerla ferma.
    private let vocabBox = OSAllocatedUnfairLock<[String]>(initialState: [])
    func setVocabulary(_ terms: [String]) { vocabBox.withLock { $0 = terms } }

    /// Whether `decodeCovering` goes back for stretches that produced no words
    /// (ISC-174). ON always, except under a bench that is measuring what it
    /// costs — see the note where it is read. Settable rather than read from
    /// settings for the reason every other knob in this class is: a probe that
    /// reads the app's own defaults measures whichever domain the probe happens
    /// to run in, and that has cost this project three wrong answers.
    private let coverageBox = OSAllocatedUnfairLock<Bool>(initialState: true)
    var repairsCoverage: Bool {
        get { coverageBox.withLock { $0 } }
        set { coverageBox.withLock { $0 = newValue } }
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

    /// Quante volte l'ultimo anello — ridecodifica SENZA il taglio di coda — ha
    /// riportato indietro del testo. Contato per lo stesso motivo di `emptyBox`:
    /// una rete che scatta e non lascia traccia contabile è indistinguibile da una
    /// che non è mai servita, e il banco non può misurarla dal registro.
    private let senzaTaglioBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Recuperi senza taglio dall'ultima chiamata, e azzera il contatore.
    func takeRecoveredWithoutTrim() -> Int {
        senzaTaglioBox.withLock { n in let v = n; n = 0; return v }
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
        try await SegmentedDecode.run(samples, allowedLanguages: allowedLanguages,
                                      forced: forced, engine: "whisperkit",
                                      decode: transcribeOne)
    }

    private func transcribeOne(_ samples: [Float],
                               allowedLanguages: Set<Language>,
                               forced: Language?) async throws -> TranscriptionResult {
        try await prepare()
        // `prepare` may have put "opening the speech model" on screen. The model
        // is open now and the app is back to what the user asked for.
        Self.report(.transcribing)
        guard let pipe = pipeBox.withLock({ $0 }) else {
            return TranscriptionResult(text: "", detectedLanguage: nil)
        }

        // Trim TRAILING silence — Whisper hallucinates phrases like
        // "thank you"/"grazie" on it (trained on YouTube captions). The silence
        // at the start is left alone on purpose: see `trimSilence`.
        let grezzi = samples
        let samples = Self.trimSilence(samples)
        // Quanto è stato tolto, scritto nel registro.
        //
        // Non è rumore di log: il 2026-08-16 la domanda «il taglio si è mangiato
        // le ultime parole?» ha richiesto di ricostruire il taglio a mano, fuori
        // dall'app, perché l'app non diceva da nessuna parte quanti campioni
        // avesse consegnato al decoder. Una riga qui e quella domanda si legge
        // dal registro invece di essere rifatta.
        //
        // **E oltre `trimSospetto` la riga lo DICE** (2026-08-17). Il taglio da
        // 2,22 s che ha mangiato «di diverso» stava nel registro dal primo minuto,
        // scritto identico a un taglio da tre decimi: chi scorreva il file non
        // aveva modo di distinguerli, e il difetto è arrivato in faccia a lui
        // invece che a noi. Un marcatore non ferma niente e non deve: rende
        // cercabile la classe di righe che merita un'occhiata.
        if samples.count != grezzi.count {
            let tolto = Double(grezzi.count - samples.count) / 16_000
            Log.write(String(format: "whisperkit: taglio coda %.2fs → %.2fs (−%.2fs)%@",
                             Float(grezzi.count) / 16_000,
                             Float(samples.count) / 16_000,
                             Float(tolto),
                             tolto >= Self.trimSospetto
                                ? String(format: " ⚠︎ SOSPETTO (oltre %.1fs)", Self.trimSospetto) : ""))
        }

        // And if there is no speech in there at all, do not ask.
        //
        // The phrase list below catches the hallucinations Whisper is FAMOUS for,
        // which is pattern-matching: feed it pure silence and it will invent
        // something, and anything not on the list gets through. Until now
        // `trimSilence` explicitly handed all-silence audio over untouched
        // (`guard end > 0 else { return s }`), so the one case that
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
        // prefill, so the segment ends before the first real token.
        //
        // IL MURO È CADUTO IL 2026-08-08: la 1.1.0 (6 agosto) elenca fra le sue
        // correzioni proprio `promptTokens`, e il pacchetto è salito a quella
        // versione. Quindi la frase che stava qui — «la correzione non è in
        // nessun tag rilasciato, e questo pacchetto è inchiodato alla 0.14.1» —
        // oggi è falsa in tutte e due le metà.
        //
        // L'interruttore però resta SPENTO, perché nessuno ha ancora rimisurato
        // su questa versione, e la misura è la sola cosa che può accenderlo: le
        // 160 trascrizioni vuote su 160 sono state contate sulla 0.14.1. Prima di
        // toccarlo si rifà il banco del 2026-08-02 sulle sue registrazioni vere,
        // in lingua forzata E in automatica, guardando per prime le frasi
        // ORDINARIE: il guasto che conta è quello che danneggia il parlato con
        // cui il vocabolario non c'entra niente.
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
        func promptTokens(for prompt: String) -> [Int]? {
            guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                  let tokenizer = pipe.tokenizer else { return nil }
            let encoded = tokenizer
                .encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !encoded.isEmpty else { return nil }
            let tokens = Array(encoded.suffix(200))
            // The round-trip is logged because "the tokens are wrong" was a
            // live suspect for a month. They are not: the decode comes back
            // byte-identical to what went in.
            Log.write("vocab prompt: \(tokens.count) tokens"
                      + " · round-trip=\"\(tokenizer.decode(tokens: tokens))\"")
            return tokens
        }

        // Un prompt passato a mano (il banco) è un ordine: una passata sola, con
        // quel testo. Il vocabolario invece agisce DOPO la prima decodifica, in
        // fondo a questo metodo, perché i termini da insegnare si scelgono
        // guardando che cosa la prima passata ha sbagliato.
        let manualPrompt = initialPrompt
        if let manualPrompt, let tokens = promptTokens(for: manualPrompt) {
            options.promptTokens = tokens
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
        // ISC-174, 2026-08-12: the decode now has to account for the whole
        // recording. `decodeCovering` is the same single decode as before plus
        // a re-listen of anything the seek loop skipped — see `CoverageGap` for
        // the failure, and note that the four knobs listed above were all aimed
        // at making the skip less likely, while this notices it and goes back.
        var decoded = try await decodeCovering(
            samples, options: options, pipe: pipe, allowed: allowedLanguages)
        var raw = decoded.raw
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
                decoded = try await decodeCovering(
                    samples, options: options, pipe: fresh, allowed: allowedLanguages)
                raw = decoded.raw
                text = Self.stripHallucinations(raw)
                Log.write(raw.isEmpty ? "still empty after reloading — giving up"
                                      : "recovered after reloading: \"\(text)\"")
            }
        }

        // **L'ultimo anello: se è ancora vuota, si ridecodifica SENZA il taglio di
        // coda** (2026-08-18, sua parola «costruisci la rete»).
        //
        // Il caso che l'ha aperta: `20260818-020906`, 5,59 s di cui ne restano 2,20
        // dopo il taglio, esce **vuota 2 volte su 3** — e l'audio intero dà il testo
        // giusto 3 volte su 3. Non è una soglia sbagliata: è un dirupo del decoder
        // sulle clip cortissime, l'unica dei 120 file dell'archivio che resti sotto
        // i 5 secondi.
        //
        // Perché è l'ULTIMO anello e non il primo: l'audio intero è esattamente ciò
        // che il taglio esiste per evitare, perché Whisper inventa «grazie» sulla
        // quiete in coda. Quindi si prova solo quando l'alternativa è consegnargli
        // niente, che è il peggiore degli esiti — lui ha parlato e non riceve nulla.
        // La difesa contro l'invenzione è già in casa: il risultato passa da
        // `stripHallucinations` come ogni altro, e se esce vuoto anche di là non si
        // è perso niente.
        //
        // La condizione sul taglio non è cosmetica: se il taglio non aveva tolto
        // nulla, `grezzi` E `samples` sono lo stesso audio e la ridecodifica sarebbe
        // la stessa domanda fatta due volte — cioè il difetto che ISC-108 ha già
        // pagato una volta.
        if raw.isEmpty, samples.count != grezzi.count,
           let pipe = pipeBox.withLock({ $0 }) {
            Log.write("ancora vuota — ridecodifico senza il taglio di coda")
            let intero = try await decodeCovering(
                grezzi, options: options, pipe: pipe, allowed: allowedLanguages)
            let testoIntero = Self.stripHallucinations(intero.raw)
            if !testoIntero.isEmpty {
                senzaTaglioBox.withLock { $0 += 1 }
                decoded = intero
                raw = intero.raw
                text = testoIntero
                Log.write("recuperata senza taglio: \"\(text)\"")
            } else {
                Log.write("vuota anche senza taglio — non c'era niente da recuperare")
            }
        }

        // If the caller forced a language, that IS the source language (we told
        // Whisper to decode in it). Otherwise map the detected code/name and
        // validate to the enabled set (ISC-28).
        var detected = forced ?? Self.mapLanguage(decoded.language, allowed: allowedLanguages)

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
            let redone = try await decodeCovering(
                samples, options: second, pipe: pipe, allowed: allowedLanguages)
            let redoneText = Self.stripHallucinations(redone.raw)
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

        // ── Il vocabolario, secondo giro (2026-08-08) ────────────────────────
        //
        // Perché QUI e non nella prima passata: `VocabularyPrompt` sceglie i
        // termini guardando che cosa il motore ha sbagliato, quindi ha bisogno
        // di un testo. E perché DOPO la correzione di lingua: quella può
        // ridecodificare tutto, e insegnare parole a una passata che sta per
        // essere buttata è lavoro sprecato.
        //
        // Il canale è aperto perché il difetto che lo teneva chiuso è morto:
        // WhisperKit 1.1.0 restituisce 0 trascrizioni vuote su 160 dove la
        // 0.14.1 ne dava 160 su 160, col polo negativo intatto (25/25, la clip
        // 12 «comandasse» resta italiana) e il WER medio da 8,3% a 3,3%.
        // Referto: `03-Plans/kalamos-prompttokens/REFERTO-20260808.md`.
        let vocab = vocabBox.withLock { $0 }
        if manualPrompt == nil, !vocab.isEmpty, !text.isEmpty,
           let mirato = VocabularyPrompt.text(for: text, terms: vocab),
           let tokens = promptTokens(for: mirato) {
            var second = options
            second.promptTokens = tokens
            // La lingua è ormai decisa: la seconda passata non la rimette in
            // discussione, altrimenti due decisioni diverse sullo stesso audio
            // finirebbero nello stesso testo.
            if let detected {
                second.language = detected.rawValue
                second.detectLanguage = false
            }
            let redone = try await decodeCovering(
                samples, options: second, pipe: pipe, allowed: allowedLanguages)
            let redoneText = Self.stripHallucinations(redone.raw)
            Log.write("whisperkit: prompt mirato «\(mirato)» — «\(text)» → «\(redoneText)»")
            // E se il secondo giro esce vuoto, degenera o PORTA VIA PAROLE, si
            // tiene il primo. Un miglioramento che può peggiorare deve avere una
            // via di ritorno: è la stessa riga che protegge il percorso
            // whisper.cpp. La terza condizione è arrivata dal campo il 13 agosto
            // — vedi `ContentLoss` per il caso e per il conto.
            let termini = mirato.split(separator: ",").count
            if redoneText.isEmpty || RepetitionGuard.degenerated(redoneText) {
                Log.write("whisperkit: secondo giro scartato, tengo il primo")
            } else if ContentLoss.lostContent(first: text, second: redoneText, terms: termini) {
                Log.write("whisperkit: secondo giro scartato, ha perso "
                          + "\(ContentLoss.words(in: text) - ContentLoss.words(in: redoneText))"
                          + " parole — tengo il primo")
            } else {
                text = redoneText
            }
        }

        scheduleIdleUnload()
        return TranscriptionResult(text: text, detectedLanguage: detected)
    }

    /// One whole-audio decode, plus whatever the seek loop skipped.
    ///
    /// ISC-174. Everything about the failure this repairs is in `CoverageGap`;
    /// what matters here is the shape of the answer. Four properties, in the
    /// order they matter:
    ///
    /// **A sound dictation is untouched, byte for byte.** With no hole the
    /// function returns exactly the string the old single line returned, and
    /// nothing extra is decoded, so the common case pays nothing at all. That is
    /// the first property because a repair that costs the healthy path is a
    /// worse trade than the bug.
    ///
    /// **A silent stretch stays silent.** A hole is checked against the audio
    /// before the decoder is asked, and a genuinely mute pause never reaches the
    /// model. This is the negative pole (ISC-175): the app has invented words on
    /// silence before, and a repair that hands empty audio to a model famous for
    /// filling it would be a regression dressed as a fix.
    ///
    /// **The re-decode cannot hit the same bug.** Each hole is cut into pieces
    /// that fit inside one encoder window, so the seek loop never runs.
    ///
    /// **Order comes from the clock, not from the order things were decoded.**
    /// Recovered text carries the timestamp of the hole it came from, and the
    /// final string is assembled by time.
    private func decodeCovering(
        _ samples: [Float],
        options: DecodingOptions,
        pipe: WhisperKit,
        allowed: Set<Language>
    ) async throws -> (raw: String, language: String?) {
        let sampleRate: Float = 16_000
        let minimumGap: Float = 3
        let maximumRepairs = 4
        var engine = pipe

        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        let language = results.first?.language
        let base = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty decode is ISC-108's business (the pipeline is stuck and gets
        // replaced), not this function's. Repairing a hole in nothing would only
        // hide the condition that reload exists to clear.
        guard !base.isEmpty else { return (base, language) }

        // The bench's way of asking what the repair costs, and it is a knob for
        // a MEASUREMENT, not a behaviour anybody ships: the default is on, and
        // nothing in the app turns it off.
        //
        // It exists because of a confound the principal found in the 2026-08-16
        // report, after delivery. With the audio cut into pieces, this repair
        // re-arms inside every piece — on `d-lungo-48s` it turned 1.6 s into
        // 8.7 s for a text two words different — so the WhisperKit columns of
        // that bench measured the cut PLUS this repair, and were read as if they
        // measured the cut. Separating the two needs a run with this off.
        guard repairsCoverage else { return (base, language) }

        let duration = Float(samples.count) / sampleRate
        let segments = results.flatMap(\.segments)
        // The map of the decode, and the only way this class of failure is ever
        // diagnosable after the fact: which stretch of audio produced which
        // words. Costs one line per dictation and answered in one minute a
        // question that took an hour of bisecting the recording by hand.
        Log.write("whisperkit: mappa " + segments.map {
            String(format: "%.1f-%.1f(%d)", $0.start, $0.end,
                   Self.withoutSpecialTokens($0.text).count)
        }.joined(separator: " "))
        // Two ways a stretch of audio goes unheard, and the timeline is only the
        // rarer one: time nobody claimed, and time claimed by a segment that
        // produced almost no words. The second is what the 12 August recording
        // does — see `CoverageGap.isThin`.
        // A segment's `text` is the RAW decode: it still carries
        // `<|startoftranscript|>`, the language tag and the timestamp tokens,
        // which the joined `result.text` has already had stripped. Building the
        // repaired transcription out of segments therefore means stripping them
        // here, and it is not cosmetic — those tokens are characters, so leaving
        // them in also inflates the density that decides what looks collapsed.
        var pieces: [(start: Float, end: Float, text: String)] =
            segments.map { (start: $0.start, end: $0.end, text: Self.withoutSpecialTokens($0.text)) }
        for hole in CoverageGap.gaps(
            covered: segments.map { CoverageGap.Span(start: $0.start, end: $0.end) },
            duration: duration,
            minimum: minimumGap)
        {
            pieces.append((start: hole.start, end: hole.end, text: ""))
        }
        pieces.sort { $0.start < $1.start }

        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suspects = pieces.indices.filter {
            CoverageGap.isThin(duration: pieces[$0].end - pieces[$0].start,
                               characters: trimmed(pieces[$0].text).count,
                               minimumDuration: minimumGap)
        }
        guard !suspects.isEmpty else { return (base, language) }

        Log.write(String(format: "whisperkit: %d segmenti su %.1fs, %d tratto/i da riascoltare",
                         segments.count, duration, suspects.count))

        // The language is settled by the pass that just ran; the repair decodes
        // in it rather than detecting again, so one recording cannot come back
        // in two languages.
        var again = options
        if let code = options.language ?? Self.mapLanguage(language, allowed: allowed)?.rawValue {
            again.language = code
            again.detectLanguage = false
        }

        /// Decode one stretch, cut the way the scissors cut: at the pauses.
        ///
        /// Riscritta il 2026-08-17, e il cambiamento è DOVE si taglia, non
        /// quanto. Prima il tratto si riascoltava dai confini dichiarati dal
        /// ciclo di ricerca — cioè da metà parlato — con tagli interni a passo
        /// fisso, e sulla clip del crollo tornava vuoto 6 volte su 8 a
        /// QUALUNQUE lunghezza (30 s: 3 piene su 9; 28 e 26 s: zero — quindi la
        /// lunghezza non era la manopola, e ritentare identico non la muoveva).
        /// Gli stessi secondi con gli estremi nel punto più quieto: zero vuoti
        /// su 8, a tre lunghezze diverse, compresa una sopra la finestra
        /// dell'encoder. Referto forbici §⑪. Perciò: estremi agganciati al
        /// quieto dal chiamante, e qui dentro il tratto passa da
        /// `AudioSplit.pieces` — il tagliaforbici già provato — così anche i
        /// tagli interni di un tratto lungo cadono nelle pause.
        ///
        /// A piece that comes back empty is asked again, up to three times:
        /// on this audio the decoder is a coin toss rather than a function
        /// (measured 2026-08-12; the retries saved 5 of 12 empties in the
        /// 2026-08-17 log), so asking again still earns its keep.
        func listenAgain(to clip: CoverageGap.Span) async throws -> String {
            guard let r = CoverageGap.range(of: clip, sampleRate: sampleRate, count: samples.count)
            else { return "" }
            let audio = Array(samples[r])
            var recovered: [String] = []
            for piece in AudioSplit.pieces(of: audio) {
                let sub = Array(audio[piece.range])
                let da = clip.start + Float(piece.range.lowerBound) / sampleRate
                let a = clip.start + Float(piece.range.upperBound) / sampleRate
                for attempt in 1 ... 3 {
                    let out = try await engine.transcribe(audioArray: sub, decodeOptions: again)
                    let t = trimmed(out.map(\.text).joined(separator: " "))
                    if !t.isEmpty { recovered.append(t); break }
                    Log.write(String(format: "whisperkit: pezzo %.1f-%.1fs vuoto al tentativo %d",
                                     da, a, attempt))
                }
            }
            return Self.stripHallucinations(TextSeam.join(recovered))
        }

        var repaired = 0
        var reloaded = false
        for index in suspects {
            guard repaired < maximumRepairs else { break }
            let span = CoverageGap.Span(start: pieces[index].start, end: pieces[index].end)
            let padded = CoverageGap.padded(span, by: 0.3, within: duration, notLongerThan: 30)
            // Gli estremi del riascolto si AGGANCIANO AL QUIETO, cercando solo
            // verso l'ESTERNO del tratto (2026-08-17). Verso l'esterno perché
            // spostare un estremo dentro il buco significherebbe non
            // riascoltare un pezzo di audio che nessuno ha sentito; allargare
            // invece ripete al massimo due secondi già trascritti, e il
            // doppione lo toglie `TextSeam.join` come per ogni altra cucitura.
            // I numeri che impongono questa riga sono nel commento di
            // `listenAgain` qui sotto; il caso misurato è 25,7 → 24,05 s sulla
            // clip del crollo.
            let clip = CoverageGap.Span(
                start: AudioSplit.quietestPoint(in: samples,
                                                betweenSeconds: padded.start - 2,
                                                and: padded.start) ?? padded.start,
                end: AudioSplit.quietestPoint(in: samples,
                                              betweenSeconds: padded.end,
                                              and: padded.end + 2) ?? padded.end)
            // The silence question is asked of the hole ITSELF, never of the
            // padded clip: the padding deliberately reaches into the speech on
            // either side, so a genuinely mute pause looks voiced through it.
            // Measured 2026-08-12 on a fifteen-second silence spliced between
            // two real sentences — asked through the padding it came back
            // "voiced", and the repair spent a decode and a model reload to
            // arrive where it started.
            guard let heart = CoverageGap.range(of: span, sampleRate: sampleRate, count: samples.count),
                  !Self.isSilent(Array(samples[heart])) else {
                Log.write(String(format: "whisperkit: tratto %.1f-%.1fs muto, lasciato com'è",
                                 span.start, span.end))
                continue
            }

            var clean = try await listenAgain(to: clip)
            let had = trimmed(pieces[index].text).count

            // ISC-108's remedy, applied to a stretch instead of a whole
            // recording. Measured on this same clip, 2026-08-12: cut at 25.4 s
            // and asked for 24 and for 26 seconds, the first decode came back
            // EMPTY both times and the reload then produced the full sentence;
            // asked for 16, 20, 22 and 28 seconds it came back empty and stayed
            // empty. So the pipeline reaching the bad state is what is actually
            // eating the words, and reloading it is the only thing that has ever
            // cleared it. Once per recording: it costs seconds, and a second
            // reload has never bought anything.
            if !reloaded, CoverageGap.isThin(duration: span.duration, characters: clean.count) {
                reloaded = true
                Log.write(String(format: "whisperkit: tratto %.1f-%.1fs ancora magro, ricarico il modello",
                                 span.start, span.end))
                unload()
                try await prepare()
                if let fresh = pipeBox.withLock({ $0 }) {
                    engine = fresh
                    clean = try await listenAgain(to: clip)
                }
            }

            // Adopt only what says materially more than what was already there.
            // This is what makes the density threshold safe to be approximate: a
            // stretch flagged by mistake re-decodes to roughly what it already
            // said, fails this test, and leaves the transcription untouched.
            guard !clean.isEmpty, !RepetitionGuard.degenerated(clean),
                  clean.count > max(12, had * 3 / 2) else {
                Log.write(String(format: "whisperkit: tratto %.1f-%.1fs non ha reso di più (%d → %d): «%@»",
                                 span.start, span.end, had, clean.count, clean))
                continue
            }
            Log.write(String(format: "whisperkit: tratto %.1f-%.1fs recuperato (%d → %d): «%@»",
                             span.start, span.end, had, clean.count, clean))
            pieces[index].text = clean
            repaired += 1
        }

        guard repaired > 0 else { return (base, language) }
        return (TextSeam.join(pieces.map { trimmed($0.text) }), language)
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
        // hides it whenever the quiet sits at the END — and since 2026-08-16 it
        // no longer hides the case where the quiet sits at the start either.
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

    /// Drop near-silent TRAILING samples (keeps a small pad). The head is left
    /// exactly where the recorder put it, and that is deliberate.
    //
    // `internal`, not `private`: `SegmentedDecode`, `SondaTaglio`, `ParakeetTranscriber`
    // and `DictationController` call it. (`WhisperCppTranscriber` did too, until 2026-08-19.)
    // Copying the body into the new engine would have been the worse move — the
    // trim and the silence gate are the two places where this project has
    // already been wrong twice, and two copies drift apart without a test noticing.
    //
    // The LEADING half was here from the first commit and was removed on
    // 2026-08-16, because it was eating a whole sentence out of long dictations.
    // Only the trailing half ever had a reason: Whisper invents "thank you" /
    // "grazie" on silence at the END, trained as it is on video captions. Nothing
    // was ever wrong with silence at the START, and cutting it bought about a
    // tenth of a second of decode on a recording lasting a minute.
    //
    // What it cost instead: both Whisper engines chop the audio into 30-second
    // windows, and a sentence landing across a seam can be dropped with no error
    // and no log line. Cutting the head SHIFTS every later sentence against that
    // grid — by however long the user waited before speaking, so a different
    // amount on every recording. Measured 2026-08-08 on an 82-second file:
    // whisper.cpp lost the same sentence 16 decodes out of 16 in the app, while
    // the same model on the same file through the command line kept it every
    // time; removing the first three seconds by hand made the command line lose
    // it too, with the app's exact word count. The head trim here was doing 0.33 s
    // of that same shift. Re-measured 2026-08-16 with this function trimming the
    // tail only: the sentence comes back, 8 decodes out of 8.
    //
    // Both engines, not just whisper.cpp: WhisperKit has its own documented
    // window-seam fragility (see `chunkingStrategy` above), a random offset is no
    // safer there, and it was measured on the same bench in the same hour — 5
    // long files, 8 passes, no sentence lost and no word count down.
    // ─────────────────────────────────────────────────────────────────────────
    // RISCRITTO IL 2026-08-16, e la riscrittura viene da una dettatura sua che
    // ha perso le ultime due parole. Vale la pena scrivere per intero perché la
    // diagnosi di partenza era ROVESCIATA rispetto a quello che è successo.
    //
    // Il caso: `20260816-145026.wav`, 3,99 s, «…sta ancora andando avanti, vedo
    // di là». L'app ha consegnato tutto tranne «vedo di là»; `whisper-cli` sullo
    // stesso file lo sente per intero. Il sospetto era che questo taglio si
    // fosse mangiato il parlato finale. **Misurato: questo taglio, com'era, non
    // toglieva NIENTE da quel file — zero campioni.** Il parlato perduto sta a
    // 3,44-3,60 s a piena voce (RMS 0,075, il punto più forte di tutta la coda),
    // e sopravvive intatto fino al decoder.
    //
    // Poi il banco, sullo stesso file. **Un processo per clip**, e quella riga
    // vale quanto i risultati: decodificando più clip in un processo solo i
    // risultati dipendono dall'ordine — la prima versione di questo banco
    // metteva cinque varianti in una cartella e dava numeri che si ribaltavano
    // cambiando il file di riscaldamento. La pipeline si porta dietro lo stato
    // fra una decodifica e l'altra (è lo stesso fatto che ISC-108 ripara
    // ricaricando il modello), quindi un banco a più clip misura anche l'ordine.
    //
    //   · intero, 3,987 s ................. perde «vedo di là», 5/5
    //   · tagliato a 3,93 s ............... lo perde, 3/3
    //   · tagliato a 3,79 s ............... lo perde, 3/3
    //   · tagliato a 3,75 / 3,70 / 3,65 / 3,60 / 3,55 s ... lo TIENE, 2/2 ognuno
    //   · con 1 s o 3 s di silenzio AGGIUNTI ... lo perde
    //   · solo la coda, da 2,4 s in poi ........ «ti vedo di là»
    //
    // Cioè: TOGLIERE la coda quieta ripara, aggiungerne no, e il dirupo sta fra
    // 3,75 e 3,79 — mentre il parlato finisce verso 3,60. Il difetto non era un
    // taglio troppo avido: era un taglio che non tagliava. Sotto c'è un
    // comportamento del decoder che non controlliamo, e questa funzione non
    // pretende di spiegarlo: gli consegna il parlato e poca quiete, che è tutto
    // ciò che può fare da questa parte.
    //
    // Perché non tagliava: il criterio era **il singolo campione**, e il rumore
    // di fondo di un microfono vero ha picchi istantanei sopra 0,008 fino
    // all'ultimo campione del file. La scansione all'indietro si fermava quindi
    // subito, sempre. Il taglio prendeva solo il silenzio DIGITALE — che da un
    // microfono non arriva quasi mai — mentre ogni dettatura vera finisce in
    // rumore di stanza, e quel rumore andava tutto al decoder.
    //
    // Il criterio giusto è l'energia su una FINESTRA: il rumore di stanza sta a
    // 0,004-0,013 di RMS su 100 ms, il parlato di quel file a 0,044-0,075. Fra i
    // due c'è un fattore cinque, e una finestra lo vede dove un campione no.
    // È lo stesso errore di misura del guardiano del silenzio (2026-08-04): la
    // statistica sbagliata su un campione che non risponde alla domanda fatta.
    //
    // NOTA sul verso di questa riparazione: rende il taglio PIÙ severo, non meno,
    // quindi rafforza la difesa contro le allucinazioni da silenzio invece di
    // indebolirla. `codaDiRumoreVieneTolta` è il polo che lo dice, ed è rosso
    // sul codice di prima.
    // ─────────────────────────────────────────────────────────────────────────

    /// La finestra su cui si misura l'energia, e il passo con cui si sposta.
    static let trimWindow = 1_600        // 0.1 s a 16 kHz
    static let trimHop = 160             // 10 ms
    /// Quanto si tiene DOPO l'ultima finestra parlata.
    ///
    /// **0,15 s dal 2026-08-17, ed è il centro di un altopiano misurato, non un
    /// numero scelto.** Era 0,05 s, e quel valore gli ha mangiato due parole vere:
    /// nella dettatura delle 00:29:45 «vorrei qualcosa **di diverso**» è stato
    /// consegnato come «vorrei qualcosa».
    ///
    /// **Il difetto non era dove sembrava, e vale la pena scriverlo.** Il sospetto
    /// era la soglia — troppo alta, che rade la coda parlata. Misurato: su quel
    /// file la soglia valeva 0,0051 e il parlato finiva a 11,2 s con la quiete
    /// dopo a 0,001, cioè **il taglio ha tolto solo silenzio vero**. Le parole
    /// erano ancora dentro l'audio consegnato al decoder — `whisper-cli` sullo
    /// stesso ritaglio le sente entrambe. A perderle è WhisperKit, e a decidere se
    /// le perde è **quanta quiete gli arriva in fondo**: sotto un decimo di
    /// secondo non chiude la frase.
    ///
    /// La spazzata, motore vero dell'app, tre passate per casella, sui suoi file:
    ///
    /// | cuscino | «vedo di là» (145026) | «di diverso» (002945) |
    /// |---------|----------------------|----------------------|
    /// | 0,05 s  | 3/3                  | **0/3**              |
    /// | 0,10 s  | 3/3                  | 3/3                  |
    /// | **0,15 s** | **3/3**           | **3/3**              |
    /// | 0,20 s  | 3/3                  | 3/3                  |
    /// | 0,30 s  | **0/3**              | 3/3                  |
    ///
    /// I due dirupi sono reali e tirano in direzioni opposte, quindi la banda
    /// sicura è 0,10–0,20 e 0,15 è il punto più lontano da entrambi. **Sotto c'è
    /// un comportamento del decoder che non controlliamo** — la nota del 16/08 qui
    /// sotto lo diceva già, e resta vera: da questa parte si può solo consegnargli
    /// il parlato con un po' di quiete, e scegliere «un po'» misurando.
    ///
    /// La riga del 16/08 che diceva «è piccolo, perché ogni frazione di quiete
    /// consegnata al decoder lavora contro di noi» è **smentita dalla tabella**:
    /// lavora contro solo oltre 0,2 s, e sotto 0,1 s lavora contro nell'altro
    /// verso. Il dirupo di quel giorno (3,75/3,79 s) era stato misurato per
    /// TRONCAMENTO a tempi assoluti, non attraverso questa funzione; rimisurato il
    /// 17/08 dal percorso vero, a cuscino 0,10 e 0,15 quel file regge 3/3.
    static let trimPad = 2_400           // 0.15 s

    /// Il cuscino e l'interruttore del taglio, per la spazzata di
    /// `--selftest-engine --cuscino=<s>` e `--senza-taglio`.
    ///
    /// Esistono perché la domanda «è il taglio o è il decodificatore?» si risponde
    /// solo cambiando UN parametro alla volta sullo stesso file e rileggendo cosa
    /// esce dal motore vero. Stessa ragione di `WaveIsland.probeTaratura`: una
    /// spazzata che per girare deve modificare il sorgente è una spazzata che
    /// nessuno può rifare.
    nonisolated(unsafe) static var probeTrimPad: Int?
    nonisolated(unsafe) static var probeTrimOff = false
    /// La terza manopola, `--tetto=<rms>`: il banco che sceglie `trimTetto` deve
    /// poter provare i candidati sul motore vero senza toccare il sorgente.
    nonisolated(unsafe) static var probeTrimTetto: Float?

    static var cuscino: Int { probeTrimPad ?? trimPad }

    /// La soglia si misura sulla registrazione stessa, non su una costante buona
    /// per tutti i microfoni: **una frazione della finestra più forte del file**.
    ///
    /// Il parlato vero, anche l'ultima sillaba smorzata, sta molto sopra un
    /// settimo del picco; il rumore di stanza sta molto sotto. I due estremi
    /// esistono perché la frazione da sola sbaglia agli estremi: su una
    /// registrazione quasi muta darebbe una soglia priva di senso (da qui il
    /// pavimento, che è `AudioRecorder.speechFloor`, la definizione di silenzio
    /// che l'app ha già) e su una gridata la renderebbe severa al punto di
    /// mangiare una coda parlata piano (da qui il tetto, che dal 17/08 sera è
    /// `trimTetto`, misurato per QUESTO taglio — il prestito di
    /// `AudioSplit.silenceRMS` è il difetto che il cantiere D ha chiuso).
    static let trimFraction: Float = 0.15

    /// **Oltre questo, un taglio si dichiara sospetto nel registro.**
    ///
    /// Non è un limite e non ferma niente: è la riga che si legge il giorno dopo.
    /// Il difetto del 2026-08-17 — 2,22 s di coda parlata rasi via — stava nel
    /// registro fin dal primo minuto come «taglio coda 13.59s → 11.37s», scritto
    /// esattamente come un taglio da tre decimi, e nessuno poteva distinguerli
    /// scorrendo. Un secondo e mezzo di coda quieta è una pausa lunghissima; oltre,
    /// la spiegazione più probabile è che sia stato tagliato del parlato.
    static let trimSospetto: Double = 1.5

    /// **Il tetto vero della soglia: una frazione della MEDIANA del parlato, non
    /// una costante presa in prestito** (2026-08-17).
    ///
    /// Fino a oggi il tetto era `AudioSplit.silenceRMS` (0,02), che è il «qui si
    /// può tagliare una giuntura» di un'altra parte dell'app: una domanda diversa,
    /// e un numero molto più alto di quanto serva qui. L'effetto si vede sui suoi
    /// file — su `20260816-143651` la soglia usciva **0,0200 contro una mediana
    /// del parlato di 0,0114**, cioè stava al doppio del parlato tipico di quella
    /// registrazione e ne rasava 8,3 s di coda. Su `20260816-154025` uguale, 0,0200
    /// contro 0,0078.
    ///
    /// La mediana è la statistica giusta perché è **robusta al picco** — che è
    /// precisamente ciò che tradiva la frazione sul massimo quando la
    /// registrazione comincia forte.
    ///
    /// **Perché 1,5 e non 1,0, che sarebbe il numero "di principio".** Perché 1,0
    /// e 0,5 sono stati provati e riaprono il difetto che questo taglio esiste per
    /// riparare. La mediana è contaminata: le finestre sopra il pavimento
    /// includono il rumore di stanza, quindi su una registrazione con la coda
    /// lunga la mediana SCENDE verso il rumore e un tetto stretto azzera il
    /// taglio. Misurato sui suoi file, tetto contro taglio su `20260816-145026`,
    /// che è il caso da non perdere:
    ///
    /// | quota | 145026 | 143651 | il banco del fruscio |
    /// |-------|--------|--------|----------------------|
    /// | 0,5   | **0,00 s — non taglia più** | 0,66 s | **rosso** |
    /// | 1,0   | **0,00 s — non taglia più** | 1,80 s | **rosso** |
    /// | **1,5** | **0,15 s** | 5,08 s (era 8,27) | verde |
    ///
    /// Quindi questo tetto non fa la cosa di principio, fa **la cosa misurata**:
    /// toglie i casi estremi — la soglia che stava a 1,75× e a 2,5× la mediana del
    /// parlato — senza mai scendere dentro il rumore di stanza. Il caso che resta
    /// scoperto è dichiarato in `unaFinestraDiParlatoNonVieneMaiTolta`.
    static let trimQuotaMediana: Float = 1.5

    /// **Il tetto ASSOLUTO della soglia, e stavolta è del taglio** (2026-08-17 sera,
    /// cantiere D — banco e referto in `03-Plans/Kalamos/kalamos-taglio-coda/`).
    ///
    /// Fino a stasera il tetto era `AudioSplit.silenceRMS` (0,02), il «qui si può
    /// tagliare una giuntura» di un'altra parte dell'app, e la sera stessa il campo
    /// ha pagato il prestito: la dettatura delle 17:21 ha perso «dall'LLM» con la
    /// soglia a 0,0184, mentre la coda parlata stava tutta fra 0,006 e 0,019.
    ///
    /// Il valore esce da uno sweep sul MOTORE VERO (0,006 / 0,008 / 0,010 / 0,012),
    /// misurato in parole perse contro la decodifica senza taglio, su cinque code
    /// che il motore ha provato essere parlato e tre che ha provato essere quiete:
    ///
    ///   file        ora    t=0,006  t=0,008
    ///   172114      −3     **0**    0        (il caso di stasera)
    ///   034221      −22    **−5**   −18
    ///   143651      −11    **0**    0
    ///   154025      −10    **−3**   −6
    ///   160434      −6     **−3**   −12
    ///   3 quieti    ok     ok       ok
    ///
    /// 0,006 domina il comportamento attuale su TUTTI i rossi e non tocca i quieti;
    /// da 0,008 in su si riapre il difetto. Il residuo dichiarato: parlato con RMS
    /// fra il pavimento (0,004) e questo tetto resta indistinguibile dal rumore per
    /// una soglia in RMS — è la banda del polo negativo in
    /// `unaFinestraDiParlatoNonVieneMaiTolta`, e un rimedio vero sarebbe di
    /// contenuto, non di soglia.
    static let trimTetto: Float = 0.006

    /// La soglia, dai termini che la governano.
    ///
    /// · frazione del picco — la taratura sulla registrazione stessa;
    /// · tetto sulla mediana — il vincolo «mai sopra il parlato tipico»;
    /// · tetto assoluto `trimTetto` — il limite proprio del taglio.
    ///
    /// La mediana arriva da fuori invece di essere ricalcolata qui: chi chiama ha
    /// già il profilo d'energia in mano, e rifarlo sarebbe la funzione che riscrive
    /// la misura che deve usare.
    ///
    /// **Il pavimento `speechFloor` NON è più fra i termini (2026-08-18).** Era il
    /// gemello del prestito tolto ieri dal tetto: `AudioRecorder.speechFloor` è la
    /// soglia con cui il registratore decide dal vivo se c'è voce, non una
    /// proprietà di questo taglio, ed essendo ASSOLUTA (0,004) strozzava proprio le
    /// registrazioni dette piano. Misurato sull'archivio: comandava la soglia su
    /// **75 file su 120**. Il caso che l'ha aperta è `20260818-022802` — picco
    /// 0,0148, coda parlata fra 0,0012 e 0,0025, cioè tutta sotto il pavimento:
    /// consegnava «come l'hai fatto» invece di «come l'hai fatta adesso».
    ///
    /// Il pavimento sopravvive dove ha senso, cioè nel RIPIEGO qui sotto: là serve
    /// a non consegnare intera una registrazione di sola quiete, che è il caso in
    /// cui il decoder inventa «grazie».
    ///
    /// Perché questo taglia solo dove deve: sui file governati dal tetto il
    /// pavimento non partecipava già prima, quindi restano identici per
    /// costruzione — `20260816-145026`, il fruscio che perde «Vedo di là» se non lo
    /// si taglia, ha soglia 0,006 dal tetto ed è fuori da questa modifica. Il
    /// rimedio scartato è il cuscino globale: 0,30 s riportava «adesso» ma su
    /// `145026` faceva sparire il taglio (0,15 s in tutto) e con esso la frase,
    /// 0 volte su 3.
    static func trimSoglia(_ picco: Float, mediana: Float = 0) -> Float {
        let tetto = probeTrimTetto ?? trimTetto
        let base = picco * trimFraction
        // Mediana zero significa «non misurata», non «zero». Un valore mancante non
        // deve poter passare per un valore: senza, si ricade sul comportamento di
        // prima invece di far finta che il vincolo ci sia.
        guard mediana > 0 else { return min(tetto, base) }
        return min(tetto, base, mediana * trimQuotaMediana)
    }

    /// La mediana delle finestre che portano parlato, cioè quelle sopra il
    /// pavimento. **Mediana e non media**: una coda lunga di quiete tirerebbe giù
    /// una media fino a renderla inservibile, e sono proprio le registrazioni con
    /// la coda lunga il caso che qui interessa.
    static func trimMediana(_ energie: [Float]) -> Float {
        let parlate = energie.filter { $0 >= AudioRecorder.speechFloor }.sorted()
        return parlate.isEmpty ? 0 : parlate[parlate.count / 2]
    }

    /// Drop near-silent TRAILING samples (keeps a small pad). The head is left
    /// exactly where the recorder put it, and that is deliberate.
    //
    // `internal`, not `private`: `SegmentedDecode`, `SondaTaglio`, `ParakeetTranscriber`
    // and `DictationController` call it. (`WhisperCppTranscriber` did too, until 2026-08-19.)
    // Copying the body into the new engine would have been the worse move — the
    // trim and the silence gate are the two places where this project has
    // already been wrong twice, and two copies drift apart without a test noticing.
    //
    // The LEADING half was here from the first commit and was removed on
    // 2026-08-16, because it was eating a whole sentence out of long dictations.
    // Only the trailing half ever had a reason: Whisper invents "thank you" /
    // "grazie" on silence at the END, trained as it is on video captions. Nothing
    // was ever wrong with silence at the START, and cutting it bought about a
    // tenth of a second of decode on a recording lasting a minute.
    //
    // What it cost instead: both Whisper engines chop the audio into 30-second
    // windows, and a sentence landing across a seam can be dropped with no error
    // and no log line. Cutting the head SHIFTS every later sentence against that
    // grid — by however long the user waited before speaking, so a different
    // amount on every recording. Measured 2026-08-08 on an 82-second file:
    // whisper.cpp lost the same sentence 16 decodes out of 16 in the app, while
    // the same model on the same file through the command line kept it every
    // time; removing the first three seconds by hand made the command line lose
    // it too, with the app's exact word count. The head trim here was doing 0.33 s
    // of that same shift. Re-measured 2026-08-16 with this function trimming the
    // tail only: the sentence comes back, 8 decodes out of 8.
    //
    // Both engines, not just whisper.cpp: WhisperKit has its own documented
    // window-seam fragility (see `chunkingStrategy` above), a random offset is no
    // safer there, and it was measured on the same bench in the same hour — 5
    // long files, 8 passes, no sentence lost and no word count down.
    static func trimSilence(_ s: [Float]) -> [Float] {
        guard !probeTrimOff else { return s }
        // Un pezzo delle forbici non si rifila in coda: la pausa in cui il
        // taglio è caduto è ciò che chiude l'ultima frase del pezzo, e la
        // registrazione intera è GIÀ stata rifilata prima di essere tagliata
        // (SegmentedDecode). Il perché, coi numeri: il commento di `PieceDecode`.
        guard !PieceDecode.inPiece else { return s }
        guard s.count > trimWindow else { return s }

        // Somme cumulate dei quadrati: l'energia di qualunque finestra è una
        // sottrazione, quindi il file si legge UNA volta sola invece di una
        // volta per finestra. Su una dettatura di un minuto la differenza è
        // fra 10 milioni di moltiplicazioni e un milione, e questa funzione gira
        // sulla coda di ogni dettatura, davanti all'utente che aspetta.
        // L'accumulatore è `Double` di proposito: in `Float` le somme cumulate di
        // una registrazione lunga arrivano dove la differenza fra due valori
        // vicini perde le cifre che servono, e le finestre in fondo — proprio
        // quelle che decidono — sarebbero le meno precise.
        var cumulata = [Double](repeating: 0, count: s.count + 1)
        for i in 0 ..< s.count { cumulata[i + 1] = cumulata[i] + Double(s[i]) * Double(s[i]) }

        /// L'energia di una finestra che comincia in `start`.
        func rms(_ start: Int) -> Float {
            let energia = cumulata[start + trimWindow] - cumulata[start]
            return Float((max(0, energia) / Double(trimWindow)).squareRoot())
        }

        var energie: [(start: Int, valore: Float)] = []
        energie.reserveCapacity(s.count / trimHop + 1)
        var start = 0
        while start + trimWindow <= s.count {
            energie.append((start, rms(start)))
            start += trimHop
        }
        guard let picco = energie.map(\.valore).max() else { return s }
        let soglia = trimSoglia(picco, mediana: trimMediana(energie.map(\.valore)))

        guard let ultima = energie.last(where: { $0.valore >= soglia })?.start else {
            return s   // tutto quieto → si lascia com'è, decide `isSilent`
        }

        // Si tiene la finestra INTERA, e non si affina a campione dentro di essa.
        //
        // Affinarla è stato il primo tentativo, e rimetteva dentro il difetto
        // appena tolto: dentro quella finestra il rumore di stanza ha picchi
        // istantanei sopra la soglia, quindi la scansione a campione si fermava
        // sull'ultimo di quelli — a 3,688 s invece che sulla fine del parlato — e
        // il taglio finiva a 3,79 s, dalla parte sbagliata del dirupo. La finestra
        // è la misura giusta; una misura giusta non si «raffina» con quella
        // sbagliata.
        //
        // Il prezzo è dichiarato: la risoluzione di questo taglio è la finestra,
        // cioè 100 ms, e non può essere più fine di così. Va bene, perché
        // l'errore va nella direzione prudente — si tiene un po' di troppo, mai
        // un po' di meno.
        let fine = min(s.count, ultima + trimWindow)
        let taglioPrimario = min(s.count, fine + cuscino)
        if taglioPrimario < s.count { return Array(s[0 ..< taglioPrimario]) }

        // **Il ripiego, e perché esiste (17/08 sera, `20260816-145026`).** Col
        // tetto severo può non esserci NIENTE sotto soglia in coda — su quel file
        // il fruscio sta a RMS 0,008, sopra `trimTetto` — e «nessun taglio» è esso
        // stesso il caso che perde parole: consegnato intero, il decoder perde
        // «vedo di là» 3 volte su 3, mentre QUALSIASI taglio (anche 0,03 s) lo
        // ripara, misurato nella tabella di `ilTaglioTogliePerDavveroLaCodaDiRumore`.
        // Quindi, solo quando il primo passaggio non toglie nulla, si ritenta con
        // la soglia PRE-tetto (la formula adattiva col vecchio limite largo): sui
        // file con la coda di fruscio forte taglia il fruscio; sui file dove anche
        // quella non trova nulla, si consegna intero come prima. Il rischio
        // residuo è dichiarato nel referto del banco: una coda parlata SENZA una
        // sola finestra sotto il tetto rientrerebbe qui — nei 120 file
        // dell'archivio non ce n'è una, e il caso tipico (tasto rilasciato subito
        // dopo l'ultima parola) produce un taglio ~0 comunque.
        let sogliaLarga = { () -> Float in
            let base = max(AudioRecorder.speechFloor, picco * trimFraction)
            let mediana = trimMediana(energie.map(\.valore))
            guard mediana > 0 else { return min(AudioSplit.silenceRMS, base) }
            return max(AudioRecorder.speechFloor,
                       min(AudioSplit.silenceRMS, base, mediana * trimQuotaMediana))
        }()
        guard sogliaLarga > soglia,
              let ultimaLarga = energie.last(where: { $0.valore >= sogliaLarga })?.start
        else { return s }
        let fineLarga = min(s.count, ultimaLarga + trimWindow)
        let taglioLargo = min(s.count, fineLarga + cuscino)
        // Il ripiego non supera MAI la linea del sospetto: `trimSospetto` dice già
        // che oltre 1,5 s «la spiegazione più probabile è che sia stato tagliato
        // del parlato», e il ripiego esiste per togliere un pelo di fruscio, non
        // per riaprire il difetto col tetto vecchio. Misurato (17/08 sera): senza
        // questo limite il ripiego rimangiava «dall'LLM» (1,76 s) e la coda di
        // `160434` (2,27 s); con il limite taglia gli 0,15 s di `145026` e lascia
        // interi gli altri, che interi si decodificano bene.
        guard Double(s.count - taglioLargo) / 16_000 <= trimSospetto else { return s }
        return Array(s[0 ..< taglioLargo])
    }

    /// Drop Whisper's own control tokens (`<|it|>`, `<|3.42|>`, …) from a raw
    /// segment, leaving the words.
    static func withoutSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    ///
    /// Tornata `private` il 2026-08-19. Era diventata `internal` il giorno prima
    /// per il motore whisper.cpp, che non filtrava le allucinazioni da nessuna
    /// parte e la cui rete sull'uscita vuota avrebbe altrimenti trasformato
    /// «niente» in «grazie»; uscito quel motore, l'unico chiamante è di nuovo
    /// questo file, e una visibilità larga con la sua ragione scaduta è solo un
    /// invito ad appoggiarcisi per sbaglio.
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
