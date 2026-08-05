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

        #if canImport(MLXLLM)
        let keepResident = Tuning.idleUnloadSeconds == nil
        // Edit Mode runs on the same engine, so it is the same reason to have it
        // ready — it was missing from this test, and someone who uses the model
        // ONLY to rewrite selections got the cold load they had asked to avoid.
        let usesCleanupModel = state.formatterMode == .localLLM
            || state.translationEnabled
            || state.editModeEnabled
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
                // a 5 su 5; sugli altri due questa chiamata non fa niente.
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
                    text = await makeFormatter().format(
                        text, context: FormattingContext(
                            language: outputLang, frontmostBundleID: bundleID,
                            promptOverride: promptOverride))
                }
                Log.write("output=\"\(text)\"")

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

    private func makeFormatter() -> TextFormatter {
        switch state.formatterMode {
        case .off:       return IdentityFormatter()
        case .ruleBased: return RuleBasedFormatter()
        case .localLLM:
            #if canImport(MLXLLM)
            return MLXFormatter(engine: .shared)
            #else
            return RuleBasedFormatter()
            #endif
        }
    }
}
