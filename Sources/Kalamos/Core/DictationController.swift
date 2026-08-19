import AppKit

/// Orchestrates: record → transcribe (+detect language) → translate OR clean up
/// → inject. Text is injected once at the end (no live streaming).
@MainActor
final class DictationController {
    private let state: AppState
    private let history: TranscriptHistory
    private let recorder = AudioRecorder()
    private let transcriber: Transcriber
    private let translator: Translator
    private var processing = false

    // Edit Mode: set when recording starts under the Edit-Mode modifier. The
    // selection is captured at that instant (before focus/selection can change),
    // and consumed in endAndProcess to transform-and-replace instead of insert.
    private var editModeActive = false
    private var capturedSelection: String?

    init(state: AppState = .shared,
         transcriber: Transcriber,
         translator: Translator = NoOpTranslator(),
         history: TranscriptHistory = .shared) {
        self.state = state
        self.transcriber = transcriber
        self.translator = translator
        self.history = history
    }

    /// Load the models again after the Mac has slept.
    ///
    /// "Never free the memory" is a promise about availability, and sleep breaks
    /// it without telling anybody: the model is still resident as far as the app
    /// is concerned, while its pages are gone. On 2026-08-15 the first long
    /// dictation after a 94-minute clamshell sleep waited **2 minutes and 15
    /// seconds**, of which the inference itself was 3.4 — the rest was 4 GB
    /// coming back off the disk. Every other run that day took between 2 and 6
    /// seconds.
    ///
    /// So the reload happens while he is opening the lid instead of while he is
    /// waiting for his text. It costs a disk read after each wake, which is the
    /// price of the setting he chose, and `warmUp` itself does nothing at all
    /// unless he chose it.
    ///
    /// Not while a dictation is in flight: a wake can land in the middle of one,
    /// and a preload competing with the decode it was supposed to make faster is
    /// the wrong trade in the one moment that matters.
    func warmUpAfterWake() {
        guard !recorder.isRecording, state.status == .idle else {
            Log.write("wake: dettatura in corso, riscaldamento rimandato")
            return
        }
        Log.write("wake: riscaldo i modelli")
        warmUp()
    }

    /// Preload at launch (in the background) so the first dictation is instant.
    ///
    /// The speech model always. The cleanup model only when the setting says
    /// **never free the memory** — because that is what "never" means. Until
    /// 2026-07-31 it did not: the cleanup model was left to load lazily on first
    /// use in every case, so someone who had chosen "always ready" still watched
    /// "opening the cleanup model…" after every restart of the app, having asked
    /// for precisely the opposite. The idle timer was not the culprit and turning
    /// it off could not have fixed it.
    ///
    /// On any other setting the old behaviour stands: a model that is going to be
    /// released in five minutes should not be fetched into memory at launch.
    /// Whether the 4 GB cleanup model is worth holding in memory before anybody
    /// asks for it.
    ///
    /// Pulled out of `warmUp` so it can be checked rather than asserted: the
    /// condition lived inline in a method whose only observable effect was a
    /// preload, so nothing could go red when it drifted — and it did drift. The
    /// test imports THIS function instead of restating it, so the day the routing
    /// changes again the two cannot disagree quietly.
    ///
    /// It must mirror `makeFormatter` exactly. `adaptive` sends punctuation to
    /// `L1Formatter` when the punctuation model is on disk and only falls back to
    /// the LLM when it is not, so `adaptive` alone is not a reason to keep 4 GB
    /// resident.
    /// `nonisolated` perché è una funzione dei suoi parametri e basta: legarla al
    /// MainActor la renderebbe asincrona da fuori, cioè scomoda da provare, che è
    /// il motivo per cui una decisione così finisce sepolta in un metodo e nessuno
    /// la controlla più.
    nonisolated static func wantsCleanupModelResident(
        mode: FormatterMode,
        punctuationModelOnDisk: Bool,
        translating: Bool,
        editMode: Bool
    ) -> Bool {
        if translating || editMode { return true }
        switch mode {
        case .localLLM:  return true
        case .adaptive:  return !punctuationModelOnDisk
        case .off, .ruleBased: return false
        }
    }

    func warmUp() {
        let transcriber = self.transcriber
        Task.detached(priority: .utility) {
            Log.write("warmUp: preloading speech model")
            try? await transcriber.prepare()
            await MainActor.run {
                // Whoever asked for the model puts the status back — but only if
                // the status is still about THIS model. The two warm-ups run at
                // once, and clearing on `isModelBusy` alone let the speech model
                // erase the cleanup model's download.
                if AppState.shared.status.modelKind == .speech { AppState.shared.status = .idle }
            }
            Log.write("warmUp: done")
        }

        // Il modello di punteggiatura, se il modo lo usa ed è sul disco: il
        // carico a freddo dopo un sonno lungo costerebbe secondi alla prima
        // dettatura, a caldo ne costa mezzo. Stessa ragione del riscaldamento
        // dei modelli voce.
        if state.formatterMode == .adaptive, PunctuationModel.isDownloaded {
            Task.detached(priority: .utility) {
                Log.write("warmUp: preloading punctuation model")
                try? await PunctuationModel.shared.prepare()
                Log.write("warmUp: punctuation model ready")
            }
        }

        #if canImport(MLXLLM)
        let keepResident = Tuning.idleUnloadSeconds == nil
        // Edit Mode runs on the same engine, so it is the same reason to have it
        // ready — it was missing from this test, and someone who uses the model
        // ONLY to rewrite selections got the cold load they had asked to avoid.
        //
        // **`adaptive` counts only while the punctuation model is missing**, and
        // that qualifier is the whole point. Until the punctuation layer shipped,
        // `adaptive` reached for this 4 GB model on every long unpunctuated
        // dictation, so keeping it warm was right. It now routes to `L1Formatter`
        // whenever `PunctuationModel.isDownloaded` (see `makeFormatter`), and the
        // LLM is the fallback for the one case where that model is absent. The
        // condition has to mirror the routing exactly or the app holds 4 GB for a
        // path nobody walks: measured on a real install with Edit Mode off,
        // 5747 MB of footprint, 4.0 GB of it the MLX allocation in
        // `IOAccelerator`, for a model no dictation was calling any more.
        let usesCleanupModel = Self.wantsCleanupModelResident(
            mode: state.formatterMode,
            punctuationModelOnDisk: PunctuationModel.isDownloaded,
            translating: state.translationEnabled,
            editMode: state.editModeEnabled
        )
        guard keepResident, usesCleanupModel else { return }
        Task.detached(priority: .utility) {
            Log.write("warmUp: preloading cleanup model (memory set to never free)")
            await MLXEngine.shared.warmUp()
            await MainActor.run {
                if AppState.shared.status.modelKind == .cleanup { AppState.shared.status = .idle }
            }
            Log.write("warmUp: cleanup model ready")
        }
        #endif
    }

    /// Called when the silence guard closed the microphone on its own, so the
    /// gesture recogniser can settle: it still believes it is listening, and the
    /// next tap would otherwise be spent stopping a recording that already ended.
    var onSilenceStop: (() -> Void)?

    /// Ticks while a hands-free dictation is open. Nil at every other moment.
    private var silenceGuard: Timer?
    private var handsFreeStartedAt: TimeInterval?

    /// When the microphone opened, so the end of a dictation can say how long it
    /// was held against how much audio came back. Without those two numbers side
    /// by side, audio dropped on the way in is indistinguishable from a short
    /// dictation, and on 2026-08-04 that ambiguity could not be resolved for a
    /// recording that had already happened.
    private var recordingStartedAt: Date?

    func handle(_ action: DictationAction, editMode: Bool = false, handsFree: Bool = false) {
        switch action {
        case .beginRecording:
            // Capture the selection NOW, while it's still highlighted and the
            // right element is focused. Empty selection → behave as normal
            // dictation (safe: never surprises with an edit that has no target).
            editModeActive = editMode
            capturedSelection = editMode ? TextInjector.selectedText() : nil
            beginRecording()
            if handsFree { armSilenceGuard() }
        case .cancelRecording:
            recorder.cancel(); if !processing { state.status = .idle }
        case .endRecordingAndProcess:
            endAndProcess()
        }
    }

    /// How loud the microphone is right now, for the wave.
    ///
    /// A pass-through and not a stored value: the controller owns the recorder, so
    /// whoever draws the wave asks the controller instead of being handed the
    /// recorder — nothing outside this class gets to start or stop a microphone.
    func microphoneLevel() -> Double { recorder.takeLevelPeak() }

    /// Menu picker → swap the speech model (loads on next dictation).
    func setSpeechModel(_ name: String) {
        let t = transcriber
        Task.detached { await t.setModel(name) }
    }

    /// Menu picker → swap the on-device cleanup/translation LLM (loads on next use).
    func setCleanupModel(_ id: String) {
        #if canImport(MLXLLM)
        Task.detached { await MLXEngine.shared.setModel(id) }
        #endif
    }

    /// Watch a hands-free dictation for a stretch of silence, once a second.
    ///
    /// Polling rather than reacting to the audio callback on purpose: the
    /// callback runs on the audio thread, and the last thing that thread should
    /// be doing is deciding policy and touching the UI.
    private func armSilenceGuard() {
        let window = Tuning.handsFreeSilenceSeconds
        guard window > 0 else { return }
        disarmSilenceGuard()
        handsFreeStartedAt = Date.timeIntervalSinceReferenceDate
        silenceGuard = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForSilence(window: window) }
        }
    }

    private func disarmSilenceGuard() {
        silenceGuard?.invalidate()
        silenceGuard = nil
        handsFreeStartedAt = nil
    }

    private func checkForSilence(window: Double) {
        guard recorder.isRecording, let startedAt = handsFreeStartedAt else {
            disarmSilenceGuard()
            return
        }
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
        let tail = recorder.tail(seconds: window)
        // Judged with the transcriber's own definition of silence, not a second
        // one: two definitions of silence in one app end up disagreeing about the
        // same audio.
        let tailIsSilent = WhisperKitTranscriber.isSilent(tail)

        switch HandsFreeSilence.decide(elapsed: elapsed, tailIsSilent: tailIsSilent,
                                       heardSpeech: recorder.heardSpeech, window: window) {
        case .keepListening:
            return
        case .finish:
            Log.write("hands-free: \(Int(window))s of silence after speech — finishing")
            disarmSilenceGuard()
            onSilenceStop?()
            endAndProcess()
        case .discard:
            Log.write("hands-free: \(Int(window))s and nothing was ever said"
                      + " — microphone closed, nothing transcribed")
            disarmSilenceGuard()
            onSilenceStop?()
            recorder.cancel()
            state.status = .idle
        }
    }

    private func beginRecording() {
        // Asked BEFORE the device is opened, or the answer is about us. It never
        // stops a dictation — a shared microphone works fine — it only decides
        // which sentence the user reads if this one turns out dead.
        let busyElsewhere = AudioRecorder.inputDeviceBusyElsewhere()
        do {
            try recorder.start()
            recordingStartedAt = Date()
            Log.write("recording started")
            state.status = .listening
            checkMicrophoneCameUp(wasBusyElsewhere: busyElsewhere)
        } catch {
            state.status = .error("Mic unavailable: \(error.localizedDescription)")
        }
    }

    /// Half a second after the key, ask whether the microphone actually turned up.
    ///
    /// ISC-109, the user's own design. `engine.start()` succeeding does NOT mean the
    /// input device is ours: when a phone call takes it, the graph starts, the
    /// tap installs, and every sample is zero. The old fix noticed at the END of
    /// the recording, which still meant listening to nothing for as long as the
    /// gesture lasted — forty minutes, the day it happened. Asking now costs
    /// nothing and gives the honest answer: this dictation is not going to work,
    /// so stop pretending to listen and go back to idle.
    ///
    /// Waiting instead of asking CoreAudio who owns the device is deliberate: the
    /// device might be shared, might be a virtual one, might be a permission
    /// revoked mid-session. Whether audio ARRIVES is the question we actually
    /// care about, and it has one answer for all of those.
    private func checkMicrophoneCameUp(wasBusyElsewhere: Bool) {
        let probe = AudioRecorder.startupProbeSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + probe) { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            let health = self.recorder.healthSoFar()
            guard health != .alive else { return }

            Log.write("mic did not come up (\(health), busy elsewhere: \(wasBusyElsewhere))"
                      + " — abandoning this dictation")
            self.recorder.cancel()
            // One dead start is proof enough: the next press gets a new graph.
            self.recorder.markForRebuild()
            // Name the cause when we can. "Not available" tells nobody what to
            // do; "another app has it" tells you to hang up.
            self.state.status = .error(wasBusyElsewhere
                ? L.t("Il microfono lo sta usando un'altra app",
                      "Another app is using the microphone",
                      "Une autre app utilise le micro")
                : L.t("Il microfono non è disponibile — riprova",
                      "The microphone is not available — try again",
                      "Le micro n’est pas disponible — réessayez"))
        }
    }

    private func endAndProcess() {
        disarmSilenceGuard()
        let samples = recorder.stop()
        let startedAt = recordingStartedAt ?? Date()
        recordingStartedAt = nil

        // Two numbers, not one. Seconds of audio alone cannot tell a short
        // dictation from a long one that lost its middle; the wall clock can.
        // A gap between them is audio that never reached the buffer.
        let heldSeconds = Date().timeIntervalSince(startedAt)
        let audioSeconds = Double(samples.count) / AudioRecorder.targetSampleRate
        Log.write(String(format: "endAndProcess: samples=%d (%.1fs audio, %.1fs al microfono)",
                         samples.count, audioSeconds, heldSeconds))
        if heldSeconds - audioSeconds > 1.0 {
            Log.write(String(format: "WARNING: %.1fs di audio non sono arrivati nel buffer",
                             heldSeconds - audioSeconds))
        }

        // Keep the sound itself, before anything can go wrong with the words.
        let archived = DictationArchive.keep(samples, startedAt: startedAt,
                                             sampleRate: AudioRecorder.targetSampleRate)

        // ISC-109 — say it out loud instead of writing it in a log nobody reads.
        //
        // Both of these were knowable on 2026-08-01 and both were silent: the
        // recording that ran forty minutes on a microphone a phone call had
        // taken, and the three dead ones after it. A failure the app can name
        // and does not is worse than one it cannot see.
        if recorder.hitCeiling {
            Log.write("recording hit the \(Int(AudioRecorder.maxSeconds))s ceiling")
            state.status = .error(L.t("Registrazione troppo lunga, fermata",
                                      "Recording too long — stopped",
                                      "Enregistrement trop long, arrêté"))
        } else if AudioRecorder.isDead(samples) {
            Log.write("recording was digitally silent — the microphone gave nothing")
            state.status = .error(L.t("Il microfono non ha dato niente",
                                      "The microphone gave nothing",
                                      "Le micro n’a rien donné"))
            return
        }

        guard !samples.isEmpty else { state.status = .idle; return }
        state.status = .transcribing
        processing = true

        let translationEnabled = state.translationEnabled
        let translationTarget = state.translationTarget
        let defaultLanguage = state.defaultLanguage
        let autoDetect = state.autoDetectLanguage
        let enabledLanguages = state.enabledLanguages
        let promptOverride = state.cleanupPromptOverride
        let addSpace = state.spaceBetweenDictations
        let smartCapitals = state.smartCapitalization
        let forceLowercase = state.lowercaseFirstLetter
        let dropTrailingPeriod = state.removeTrailingPeriod
        let insertionMode = state.insertionMode

        // Consume the Edit-Mode capture for this utterance (reset immediately so
        // the next dictation is normal unless the modifier is held again).
        let editMode = editModeActive
        let editSelection = capturedSelection
        editModeActive = false
        capturedSelection = nil

        Task {
            defer { processing = false }
            do {
                // 1. Transcribe (the transcriber already strips Whisper's
                //    trailing-silence hallucinations like "thank you"/"grazie").
                // Il vocabolario PRIMA, non solo dopo.
                //
                // `VocabularyRepair` più sotto ripara il testo quando la parola è
                // già uscita sbagliata, e resta: è la rete. Ma una parola che il
                // motore non ha mai sentito non si ripara a valle se non è in
                // lista, ed è esattamente il caso di `fork`, uscito «forco» nelle
                // sue dettature vere. Su whisper.cpp il canale funziona e la porta
                // a 5 su 5, e dal 2026-08-08 risponde anche WhisperKit, dove il
                // difetto che lo teneva chiuso è stato misurato morto. Su Parakeet
                // questa chiamata non fa niente: quel motore non ha un prompt.
                transcriber.setVocabulary(Vocabulary.terms)
                let result = try await transcriber.transcribe(
                    samples, allowedLanguages: enabledLanguages,
                    forced: autoDetect ? nil : defaultLanguage)
                let sourceLang = result.detectedLanguage ?? defaultLanguage
                var text = result.text
                Log.write("transcribed lang=\(sourceLang.rawValue) text=\"\(text)\"")
                let rawText = text
                guard !text.isEmpty else { state.status = .idle; return }

                // Apply user replacement rules ("rosi" → "Rossi") on the raw
                // transcription, before translate/format touch it.
                let corrected = Corrections.apply(to: text)
                if corrected != text { Log.write("corrections: \"\(text)\" → \"\(corrected)\"") }
                text = corrected

                // Then the vocabulary, in the same place and for the same reason.
                //
                // Until 2026-08-01 the word list did nothing to the text: it went
                // into the cleanup prompt, and measured over 180 transcriptions
                // from three engines it repaired ZERO names — "Calamos" stayed
                // "Calamos" with "Kalamos" sitting in the prompt. A replacement
                // rule you have to type by hand caught it; a word you named once
                // did not. Now both are code.
                //
                // AFTER Corrections on purpose: a rule you wrote yourself is an
                // instruction, and the vocabulary is a guess. The instruction goes
                // first and the guess never gets to overrule it.
                let repaired = VocabularyRepair.apply(to: text)
                if repaired != text { Log.write("vocabulary: \"\(text)\" → \"\(repaired)\"") }
                text = repaired

                // I numeri in cifre, e SOLO su Parakeet.
                //
                // Whisper scrive già «30%» da sé; Parakeet non ha una
                // normalizzazione inversa per l'italiano e consegna «trenta per
                // cento», «uno.cinque barra uno.sette». Non è un ascolto
                // peggiore, è un formato — ma nel testo che finisce nel suo
                // documento è un errore lo stesso.
                //
                // Il cancello è dietro il motore e non dietro una preferenza
                // perché su Whisper questa passata non avrebbe niente da fare e
                // avrebbe comunque qualcosa da rompere: ogni riparazione che
                // gira su un testo già a posto è solo una superficie di rischio.
                if state.speechEngine == .parakeet {
                    let inCifre = ItalianNumberSpans.apply(to: text)
                    if inCifre != text { Log.write("numeri: \"\(text)\" → \"\(inCifre)\"") }
                    text = inCifre
                }

                // 1b. Edit Mode: the dictation IS an instruction. Transform the
                //     captured selection on-device and replace it (⌘V overwrites
                //     the still-highlighted text). Skips the normal clean-up path.
                #if canImport(MLXLLM)
                if editMode, let selection = editSelection, !selection.isEmpty {
                    Log.write("editMode: instruction=\"\(text)\" selection=\(selection.count) chars")
                    let edited = await MLXEditor().transform(
                        instruction: text, selection: selection, language: sourceLang)
                    history.add(edited, language: sourceLang)
                    TextInjector.inject(edited, mode: state.insertionMode)
                    UsageLog.record()
                    finishQuietly()
                    Log.write("editMode: replaced ✓")
                    return
                }
                #endif

                let bundleID = TextInjector.frontmostBundleID()

                // 2. Translate OR clean up.
                let outputLang: Language
                if translationEnabled, translationTarget != sourceLang {
                    Log.write("translating \(sourceLang.rawValue)→\(translationTarget.rawValue)…")
                    text = try await translator.translate(text, from: sourceLang, to: translationTarget)
                    outputLang = translationTarget
                } else {
                    outputLang = sourceLang
                    text = await makeFormatter(for: text).format(
                        text, context: FormattingContext(
                            language: outputLang, frontmostBundleID: bundleID,
                            promptOverride: promptOverride))
                }
                Log.write("output=\"\(text)\"")

                // Un microfono aperto per sbaglio non è una dettatura, e non va
                // archiviato (sua richiesta, 2026-08-16: nel pannello comparivano
                // fra le righe da guardare, e non c'è niente da guardare).
                //
                // **Ma solo quando davvero non ha parlato.** Una registrazione in
                // cui la voce c'era e il motore è tornato vuoto è l'unica prova
                // che esiste di ISC-108, aperta da agosto e vista 7 volte su 305:
                // cancellarla insieme ai tocchi a vuoto distruggerebbe il caso nel
                // momento esatto in cui capita. Quella resta, marcata.
                if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if recorder.heardSpeech, let archived {
                        DictationArchive.mark(archived, reason: "vuota con voce dentro (ISC-108)")
                        Log.write("archivio: trascrizione vuota MA c'era voce, tenuta come prova")
                    } else {
                        DictationArchive.discard(archived)
                    }
                    return
                }

                // The words, beside the sound they came from. This is the whole
                // point of the archive: a dictation that lost something is only
                // a usable bug report when both halves survive it.
                DictationArchive.annotate(archived, lines: [
                    String(format: "durata audio: %.1fs · microfono aperto: %.1fs",
                           audioSeconds, heldSeconds),
                    "lingua: \(sourceLang.rawValue)",
                    "",
                    "GREZZO:",
                    rawText,
                    "",
                    "CONSEGNATO:",
                    text,
                ])

                // Did he just say the same thing again? Then the one before it
                // came out wrong, and the app can know that without being told.
                //
                // The previous snapshot is read BEFORE the new one replaces it,
                // and the mark goes on the OLDER file: the redo is the evidence,
                // and the dictation it replaced is the defect worth keeping.
                if let previous = LastDictation.shared.snapshot,
                   DictationTruth.isRedo(previous: previous.raw, current: rawText,
                                         gap: Date().timeIntervalSince(previous.finishedAt)) {
                    DictationArchive.mark(previous.wav, reason: L.t(
                        "ridetta subito dopo, quindi probabilmente sbagliata",
                        "said again right afterwards, so probably wrong",
                        "redite juste après, donc probablement fausse"))
                }
                LastDictation.shared.record(wav: archived, raw: rawText)

                // Say it out loud when the model's version was refused. Not a
                // system notification — that would mean asking for one more
                // permission — but the status line, the menu-bar marker, and a
                // line in the log you can go back to.
                let rejection = state.notifyCleanupRejected ? CleanupReport.shared.take() : nil
                history.add(text, language: outputLang, cleanupRejected: rejection)
                // Fit it to what is already there — a space to chain onto the
                // previous dictation, and a first letter that agrees with it.
                // Both settings are off unless asked for; the context read is
                // best-effort and skipped where the app will not answer.
                let shaped = TextShaping.prepare(
                    text,
                    before: (addSpace || smartCapitals) ? TextInjector.textBeforeCursor() : nil,
                    addSpace: addSpace,
                    smartCapitals: smartCapitals,
                    forceLowercase: forceLowercase,
                    dropTrailingPeriod: dropTrailingPeriod)
                TextInjector.inject(shaped, mode: insertionMode)
                UsageLog.record()
                if let rejection {
                    announceRejection(rejection)
                } else {
                    finishQuietly()
                }
                Log.write("injected ✓")
            } catch {
                state.status = .error(error.localizedDescription)
                Log.write("ERROR: \(error)")
            }
        }
    }

    /// Leave the reason on screen for a few seconds, then go back to idle —
    /// unless a new dictation has started in the meantime, which always wins.
    private func announceRejection(_ reason: String) {
        state.status = .error(L.t("pulizia scartata", "cleanup discarded", "nettoyage écarté")
                              + " — \(reason)")
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .error = state.status { finishQuietly() }
        }
    }

    /// Back to idle — unless the microphone is already open again.
    ///
    /// In hands-free mode you can start the next dictation while the previous one
    /// is still being cleaned up, and this task would then blindly overwrite
    /// `.listening` with `.idle`: the icon stops saying it is recording while the
    /// mic is live, which is the worst direction for that particular lie.
    /// (Gemini audit, 2026-07-31.)
    private func finishQuietly() {
        if state.status != .listening { state.status = .idle }
    }

    /// The raw transcript is a parameter because one mode decides per dictation:
    /// `adaptive` looks at what Whisper actually produced and only pays for the
    /// model when the punctuation is missing. See `CleanupNeed`.
    private func makeFormatter(for raw: String) -> TextFormatter {
        switch state.formatterMode {
        case .off:       return IdentityFormatter()
        case .ruleBased: return RuleBasedFormatter()
        case .adaptive:
            let needed = CleanupNeed.needsModel(raw)
            guard needed else {
                Log.write("adaptive: regole, già punteggiato")
                return RuleBasedFormatter()
            }
            // Il lavoro di punteggiatura va al modello dedicato quando c'è:
            // stessa qualità misurata sopra l'LLM (85,9/78,4/91,2 contro
            // 72,6/53,8/50,0 sul metro) a 20 ms invece di 3 s. L'LLM resta il
            // ripiego finché il modello non è scaricato, e resta il titolare
            // di tono/registro nel modo «Rifinitura AI».
            if PunctuationModel.isDownloaded {
                Log.write("adaptive: al modello L1")
                return L1Formatter()
            }
            #if canImport(MLXLLM)
            Log.write("adaptive: al modello (L1 non scaricato)")
            return MLXFormatter(engine: .shared)
            #else
            return RuleBasedFormatter()
            #endif
        case .localLLM:
            #if canImport(MLXLLM)
            return MLXFormatter(engine: .shared)
            #else
            return RuleBasedFormatter()
            #endif
        }
    }
}
