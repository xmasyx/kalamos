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

    /// Preload the speech model at launch (background) so dictation is instant.
    func warmUp() {
        let transcriber = self.transcriber
        Task.detached(priority: .utility) {
            Log.write("warmUp: preloading speech model")
            try? await transcriber.prepare()
            await MainActor.run {
                if case .loadingModel = AppState.shared.status { AppState.shared.status = .idle }
            }
            Log.write("warmUp: done")
        }
    }

    func handle(_ action: DictationAction, editMode: Bool = false) {
        switch action {
        case .beginRecording:
            // Capture the selection NOW, while it's still highlighted and the
            // right element is focused. Empty selection → behave as normal
            // dictation (safe: never surprises with an edit that has no target).
            editModeActive = editMode
            capturedSelection = editMode ? TextInjector.selectedText() : nil
            beginRecording()
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

    private func beginRecording() {
        do {
            try recorder.start()
            state.status = .listening
        } catch {
            state.status = .error("Mic unavailable: \(error.localizedDescription)")
        }
    }

    private func endAndProcess() {
        let samples = recorder.stop()
        Log.write("endAndProcess: samples=\(samples.count)")
        guard !samples.isEmpty else { state.status = .idle; return }
        state.status = .transcribing
        processing = true

        let translationEnabled = state.translationEnabled
        let translationTarget = state.translationTarget
        let defaultLanguage = state.defaultLanguage
        let autoDetect = state.autoDetectLanguage
        let enabledLanguages = state.enabledLanguages
        let promptOverride = state.cleanupPromptOverride

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
                let result = try await transcriber.transcribe(
                    samples, allowedLanguages: enabledLanguages,
                    forced: autoDetect ? nil : defaultLanguage)
                let sourceLang = result.detectedLanguage ?? defaultLanguage
                var text = result.text
                Log.write("transcribed lang=\(sourceLang.rawValue) text=\"\(text)\"")
                guard !text.isEmpty else { state.status = .idle; return }

                // Apply user replacement rules ("rosi" → "Rossi") on the raw
                // transcription, before translate/format touch it.
                let corrected = Corrections.apply(to: text)
                if corrected != text { Log.write("corrections: \"\(text)\" → \"\(corrected)\"") }
                text = corrected

                // 1b. Edit Mode: the dictation IS an instruction. Transform the
                //     captured selection on-device and replace it (⌘V overwrites
                //     the still-highlighted text). Skips the normal clean-up path.
                #if canImport(MLXLLM)
                if editMode, let selection = editSelection, !selection.isEmpty {
                    Log.write("editMode: instruction=\"\(text)\" selection=\(selection.count) chars")
                    let edited = await MLXEditor().transform(
                        instruction: text, selection: selection, language: sourceLang)
                    history.add(edited, language: sourceLang)
                    TextInjector.inject(edited)
                    UsageLog.record()
                    state.status = .idle
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

                history.add(text, language: outputLang)
                TextInjector.inject(text)
                UsageLog.record()
                state.status = .idle
                Log.write("injected ✓")
            } catch {
                state.status = .error(error.localizedDescription)
                Log.write("ERROR: \(error)")
            }
        }
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
