import Foundation
import Combine

/// Spoken language Kalamos recognizes in v1.
enum Language: String, CaseIterable, Codable {
    case italian = "it"
    case english = "en"
    case french = "fr"

    var displayName: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "English"
        case .french: return "Français"
        }
    }
}

/// How transcribed text is cleaned up before injection.
enum FormatterMode: String, CaseIterable, Codable {
    case off          // raw transcript
    case ruleBased    // free, instant, no model
    case localLLM     // MLX on-device model (Phase 2)
    /// Rules by default, the model only on the text that needs it — the call is
    /// made per dictation by `CleanupNeed`, from the raw transcript. Added
    /// 2026-08-11 because the two existing choices were both wrong most of the
    /// time: `ruleBased` leaves a 60-word run-on unpunctuated, `localLLM` pays
    /// seconds for the 88% of dictations that are short and already fine.
    case adaptive
}

/// How the finished text is put into the app you are writing in.
enum TextInsertionMode: String, CaseIterable, Codable {
    /// Write to the pasteboard, press ⌘V, put the pasteboard back. Instant on
    /// text of any length, and works everywhere — but for about 150 ms your
    /// clipboard is the dictation, and the restore keeps only the first
    /// representation of what was there.
    case clipboard
    /// Type the characters straight in as a unicode key event. The clipboard is
    /// never touched, so whatever you had copied is still there afterwards.
    /// Slower on long text, and a few apps swallow synthetic keystrokes.
    case typing
}

/// Which of the two models a status is about. Kalamos runs two: one that hears
/// (WhisperKit), one that tidies up and translates (MLX).
enum ModelKind: String, Equatable, Sendable {
    case speech
    case cleanup
}

/// Work that keeps the app busy without moving a single byte over the network.
enum WorkKind: String, Equatable, Sendable {
    case cleaning
    case translating
    case summarizing
    case editing
}

/// What the dictation pipeline is currently doing — drives the menu-bar icon.
///
/// The three middle cases used to be one, `loadingModel(String)`, and the icon
/// drew a **download arrow** for all of them. So the arrow appeared when the app
/// was reading an already-downloaded model off the disk (every launch, and again
/// after every idle unload), and even while summarising — which downloads
/// nothing at all. Reported on 2026-07-31 as "why does a download keep starting
/// when I turned the model download off?": nothing was being downloaded. The
/// icon was lying.
///
/// They carry a `ModelKind`, not a prose string, for a second reason: the words
/// the user reads are now written where the language is known, instead of being
/// hardcoded in English deep inside an engine.
enum DictationStatus: Equatable {
    case idle
    case listening
    case transcribing
    /// Coming down from the network. `fraction` is 0…1 once the transfer reports
    /// progress, `nil` in the moment before the first byte lands.
    case downloading(ModelKind, fraction: Double?)
    /// Already on disk, being read into memory. No network involved.
    case loading(ModelKind)
    /// The model is thinking. Nothing is being fetched or loaded.
    case working(WorkKind)
    case error(String)

    /// True only while bytes are actually arriving — the one state that earns a
    /// download arrow, and the one the progress panel watches.
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// How far along the download is, when the transfer says.
    var downloadFraction: Double? {
        if case .downloading(_, let fraction) = self { return fraction }
        return nil
    }

    /// A model is being fetched or opened. The engines set these; whoever asked
    /// for the model clears them, so "opening…" never outlives the opening.
    var isModelBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        default: return false
        }
    }

    /// Which model this status is about, if any.
    ///
    /// Needed because two models can be loading at once — on a first run with the
    /// memory set to "never", the speech and cleanup models are fetched together.
    /// Whoever finishes first used to clear the status on the strength of
    /// `isModelBusy` alone, wiping the OTHER one's download: the panel vanished
    /// and the icon went idle in the middle of a 4 GB transfer. Clear only what
    /// is yours. (Found by the Gemini audit, 2026-07-31.)
    var modelKind: ModelKind? {
        switch self {
        case .downloading(let kind, _), .loading(let kind): return kind
        default: return nil
        }
    }
}

/// Single source of truth for user configuration + live status.
/// Persisted to UserDefaults; observed by the UI. Main-actor isolated.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Live status (not persisted)
    @Published var status: DictationStatus = .idle

    // MARK: Configuration (persisted)

    /// The language everything the user READS is written in — the menu bar, the
    /// preferences, the dialogs. Not the language he speaks: that is
    /// `defaultLanguage`, and setup asks the two separately.
    ///
    /// Setup asked this on its very first page and then threw the answer away —
    /// it lived in a `@State` that died with the window, so the menu stayed
    /// English whatever you chose. Persisted since 2026-07-31, on his point:
    /// the answer to that question is the language of the person.
    @Published var uiLanguage: Language { didSet { persist("uiLanguage", uiLanguage.rawValue) } }

    /// How the text gets into the app you are writing in.
    @Published var insertionMode: TextInsertionMode { didSet { persist("insertionMode", insertionMode.rawValue) } }

    /// Say so when the fidelity guard threw the model's version away.
    @Published var notifyCleanupRejected: Bool { didSet { persist("notifyCleanupRejected", notifyCleanupRejected) } }

    /// Start every dictation in lowercase — for search fields, terminals, and
    /// anywhere a capital is noise.
    @Published var lowercaseFirstLetter: Bool { didSet { persist("lowercaseFirstLetter", lowercaseFirstLetter) } }

    /// Drop the full stop the cleanup adds at the end.
    @Published var removeTrailingPeriod: Bool { didSet { persist("removeTrailingPeriod", removeTrailingPeriod) } }

    /// Chain consecutive dictations with a space, so you do not reach for the
    /// space bar between one and the next.
    @Published var spaceBetweenDictations: Bool { didSet { persist("spaceBetweenDictations", spaceBetweenDictations) } }

    /// Decide the first letter from what is already before the cursor: a capital
    /// after a full stop, lowercase in the middle of a sentence you are still
    /// finishing. Pointless without the space, and both are off by default.
    @Published var smartCapitalization: Bool { didSet { persist("smartCapitalization", smartCapitalization) } }

    // MARK: The wave (2026-08-16)

    /// Show the wave while the microphone is open. **On by default**, because what
    /// it answers is "is it listening to me right now", and that question exists
    /// for everybody until they decide it does not.
    @Published var waveEnabled: Bool { didSet { persist("waveEnabled", waveEnabled) } }

    /// The wave's colour and the shell's, as `"r g b a"` — see `WaveTint`.
    @Published var waveTint: String { didSet { persist("waveTint", waveTint) } }
    @Published var waveShellTint: String { didSet { persist("waveShellTint", waveShellTint) } }

    /// Draw the bubble behind the wave. Off, the wave floats on the desktop.
    /// Ignored in the notch, where the shell IS the point.
    @Published var waveShell: Bool { didSet { persist("waveShell", waveShell) } }

    /// Quanto si sta spingendo il riascolto oltre l'originale, come QUOTA 0…1
    /// dello spazio che il file ha (0 = suono nudo).
    ///
    /// Ricordato come la velocità, e per lo stesso motivo: la sua voce non cambia
    /// volume fra ieri e oggi, quindi rimettere la spinta a ogni apertura sarebbe
    /// un lavoro che l'app può risparmiargli. Vive qui e non nel lettore perché il
    /// lettore muore col pannello — che è esattamente il punto della regola sulle
    /// risorse audio, e il motivo per cui la sua impostazione non può vivere lì.
    @Published var playbackGainQuota: Double { didSet { persist("playbackGainQuota", playbackGainQuota) } }

    /// Hanging from the notch, or a free island. See `WavePosition`.
    @Published var wavePosition: WavePosition { didSet { persist("wavePosition", wavePosition.rawValue) } }

    /// Where the free island was last dropped: **its centre**, `"x y"` in screen
    /// points.
    ///
    /// The centre and not the corner, because the island is not always the same
    /// size — 400×128 hanging from the notch, a pill 150×40 once it is free.
    /// A corner saved by one shape and read back by the other moves the island by
    /// half the difference, which looks like a bug in the drag rather than in the
    /// arithmetic. Renamed from `waveOrigin` on 2026-08-16 together with its
    /// meaning, and with no migration on purpose: that key never left this Mac —
    /// the wave was built after v1.2.0 and `defaults read com.kalamos.app` had
    /// never written it — so a compatibility path would have been dead code from
    /// its first day.
    ///
    /// Not a setting anybody decides — the record of a gesture, like a window
    /// frame. Which is why it is not in `SettingsDraft`: a drag is finished the
    /// moment you let go, and asking him to press **Applica** after moving
    /// something with his hand would be asking him to confirm the past.
    @Published var waveCenter: String { didSet { persist("waveCenter", waveCenter) } }

    @Published var hotKeyCode: UInt16 { didSet { persist("hotKeyCode", Int(hotKeyCode)) } }
    @Published var formatterMode: FormatterMode { didSet { persist("formatterMode", formatterMode.rawValue) } }
    @Published var enabledLanguages: Set<Language> { didSet { persistLanguages() } }
    @Published var autoDetectLanguage: Bool { didSet { persist("autoDetectLanguage", autoDetectLanguage) } }
    @Published var defaultLanguage: Language { didSet { persist("defaultLanguage", defaultLanguage.rawValue) } }

    // Translation (Phase 2 / MLX)
    @Published var translationEnabled: Bool { didSet { persist("translationEnabled", translationEnabled) } }
    @Published var translationTarget: Language { didSet { persist("translationTarget", translationTarget.rawValue) } }

    // Which model does the listening (2026-08-01). Default stays Whisper, so an
    // existing install is never moved to another engine by an update.
    @Published var speechEngine: SpeechEngine { didSet { persist("speechEngine", speechEngine.rawValue) } }

    // Whisper model id (downloaded on first use by WhisperKit)
    @Published var whisperModel: String { didSet { persist("whisperModel", whisperModel) } }

    // Cleanup LLM model id (MLX). Default stays the 7B → zero regression; the
    // menu can pin a bigger model. Kept as a plain string so AppState has no
    // dependency on the MLX module (which is compiled behind #if canImport).
    @Published var cleanupModelID: String { didSet { persist("cleanupModelID", cleanupModelID) } }

    // User-editable cleanup system prompt. nil → use the built-in prompt.
    @Published var cleanupPromptOverride: String? {
        didSet {
            if let v = cleanupPromptOverride { defaults.set(v, forKey: "cleanupPromptOverride") }
            else { defaults.removeObject(forKey: "cleanupPromptOverride") }
        }
    }

    // Push-to-talk. true (default) = current behaviour: a single hold of the
    // trigger records immediately (+ double-tap toggles). false = only a
    // double-tap arms hands-free; a lone press/hold is a no-op, so using the
    // trigger key for its normal OS role (e.g. Option to move by word in a
    // terminal) no longer flickers Kalamos.
    /// Which gestures the trigger key answers to. Replaced a boolean that could
    /// not express "hold only" — see `TriggerMode`.
    @Published var triggerMode: TriggerMode { didSet { persist("triggerMode", triggerMode.rawValue) } }

    // Edit Mode: transform the SELECTED text via a spoken instruction instead of
    // inserting new text. Off by default. Activated by holding its own dedicated
    // modifier key (distinct from the dictation trigger) — never auto-inferred
    // from "is something selected", which is ambiguous with dictation-replaces.
    @Published var editModeEnabled: Bool { didSet { persist("editModeEnabled", editModeEnabled) } }
    @Published var editModeKeyCode: UInt16 { didSet { persist("editModeKeyCode", Int(editModeKeyCode)) } }

    /// Whether first-run setup has been seen. Also set, silently, for anyone who
    /// was already using the app before setup existed — see `init`.
    @Published var didCompleteOnboarding: Bool {
        didSet { persist("didCompleteOnboarding", didCompleteOnboarding) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // 0x36 == Right Command — default push-to-talk key. Present on MacBook
        // keyboards (unlike Right Control), not claimed by Claude (Right Option)
        // or macOS dictation (Fn). Accidental shortcut presses self-cancel via
        // the recognizer's abort-on-other-key. Hold to talk, double-tap to toggle.
        let savedKey = defaults.object(forKey: "hotKeyCode") as? Int
        hotKeyCode = UInt16(savedKey ?? 0x36)
        formatterMode = FormatterMode(rawValue: defaults.string(forKey: "formatterMode") ?? "") ?? .ruleBased
        autoDetectLanguage = (defaults.object(forKey: "autoDetectLanguage") as? Bool) ?? true
        defaultLanguage = Language(rawValue: defaults.string(forKey: "defaultLanguage") ?? "") ?? .english
        translationEnabled = (defaults.object(forKey: "translationEnabled") as? Bool) ?? false
        translationTarget = Language(rawValue: defaults.string(forKey: "translationTarget") ?? "") ?? .english
        // **WhisperKit è tornato il motore predefinito il 2026-08-08**, e la ragione per cui
        // era stato tolto il 7 si è rivelata mal misurata.
        //
        // Il banco del 5/08 aveva confrontato i due motori sulla DISPERSIONE, cioè su quanto il
        // conteggio parole balla fra una passata e l'altra, e whisper.cpp vinceva netto. Il banco
        // dell'8/08 sul parlato lungo ha aggiunto la domanda che mancava, cioè se il testo è
        // COMPLETO, e la risposta rovescia il verdetto: su `lungo-noto` whisper.cpp non scrive una
        // frase intera del copione in **16 decodifiche su 16**, e su una dettatura vera di 34
        // secondi ne perde otto parole lasciando una frase sgrammaticata. WhisperKit scrive quella
        // frase 16 volte su 16, e il WER senza numeri è 6,5% contro 16,1%.
        //
        // La stabilità di whisper.cpp era reale ed era la stabilità di chi sbaglia sempre allo
        // stesso modo. Una misura di sola dispersione non poteva vederlo, ed è la lezione che
        // questo commento esiste per non far ripetere.
        //
        // Il difetto ISC-163 di WhisperKit non è sparito: nudo, sui due file più lunghi, oscilla
        // di 12 e di 10 parole. Ma anche la sua passata peggiore contiene più parole della
        // migliore di whisper.cpp, e col vocabolario acceso — che dall'8/08 è il percorso normale
        // — l'oscillazione scende a Δ2 e Δ0, perché il prefill del secondo giro fa da ancoraggio.
        //
        // Chi ha già scelto un motore non viene toccato: questo vale per chi non ha scelto niente.
        // Referto: `03-Plans/kalamos-whispercpp/REFERTO-LUNGO-20260808.md`.
        speechEngine = SpeechEngine(rawValue: defaults.string(forKey: "speechEngine") ?? "")
            ?? .whisper
        whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-large-v3-v20240930_turbo"
        cleanupPromptOverride = defaults.string(forKey: "cleanupPromptOverride")

        // The interface language: whatever was chosen at setup, else the Mac's own.
        uiLanguage = Language(rawValue: defaults.string(forKey: "uiLanguage") ?? "")
            ?? Self.systemLanguage

        // The cleanup model is NOT a question to ask: whoever installs this does
        // not know how much RAM the Mac has, and could not say what changes
        // between a 3B and a 7B if they did. The machine knows both, so it
        // chooses — and the choice is written down at once, so it is a starting
        // point in Preferences rather than a rule that keeps re-deciding.
        //
        // An install that predates this line keeps the 7B it has been running:
        // an app that swaps your model underneath you on an update is a worse
        // failure than a model that is one size too big.
        if let saved = defaults.string(forKey: "cleanupModelID") {
            cleanupModelID = saved
        } else {
            let established = savedKey != nil
                || defaults.bool(forKey: "migratedFromParla")
                || defaults.object(forKey: "vocabulary") != nil
            let chosen = established
                ? ModelCatalog.previousDefaultCleanupID
                : ModelCatalog.recommendedCleanupID()
            cleanupModelID = chosen
            // `didSet` does not fire for a value assigned during init, so the
            // choice is written down here — otherwise it would be re-decided on
            // every launch and would move under someone who upgrades their Mac.
            defaults.set(chosen, forKey: "cleanupModelID")
        }
        // Migrate the old boolean rather than resetting people to the default:
        // it carried two of the three modes, and which two is unambiguous.
        if let raw = defaults.string(forKey: "triggerMode"), let m = TriggerMode(rawValue: raw) {
            triggerMode = m
        } else {
            triggerMode = ((defaults.object(forKey: "pushToTalkEnabled") as? Bool) ?? true)
                ? .both : .doubleTap
        }
        insertionMode = TextInsertionMode(rawValue: defaults.string(forKey: "insertionMode") ?? "")
            ?? .clipboard
        notifyCleanupRejected = (defaults.object(forKey: "notifyCleanupRejected") as? Bool) ?? true
        lowercaseFirstLetter = (defaults.object(forKey: "lowercaseFirstLetter") as? Bool) ?? false
        removeTrailingPeriod = (defaults.object(forKey: "removeTrailingPeriod") as? Bool) ?? false
        spaceBetweenDictations = (defaults.object(forKey: "spaceBetweenDictations") as? Bool) ?? false
        smartCapitalization = (defaults.object(forKey: "smartCapitalization") as? Bool) ?? false
        // The wave. On by default; the two tints start on the family's own pen and
        // ink, so a fresh install already looks like the rest of the app.
        waveEnabled = (defaults.object(forKey: "waveEnabled") as? Bool) ?? true
        waveTint = defaults.string(forKey: "waveTint") ?? WaveTint.defaultWave
        waveShellTint = defaults.string(forKey: "waveShellTint") ?? WaveTint.defaultShell
        waveShell = (defaults.object(forKey: "waveShell") as? Bool) ?? true
        playbackGainQuota = (defaults.object(forKey: "playbackGainQuota") as? Double) ?? 0
        wavePosition = WavePosition(rawValue: defaults.string(forKey: "wavePosition") ?? "") ?? .notch
        waveCenter = defaults.string(forKey: "waveCenter") ?? ""
        editModeEnabled = (defaults.object(forKey: "editModeEnabled") as? Bool) ?? false
        // 0x3F == Fn / Globe — default Edit-Mode modifier. Distinct from the
        // dictation trigger (Right Command), and NOT used to type text, so it
        // won't conflict with capital letters the way Shift would. Held during
        // dictation → transform the selection instead of inserting.
        let savedEditKey = defaults.object(forKey: "editModeKeyCode") as? Int
        editModeKeyCode = UInt16(savedEditKey ?? 0x3F)

        // Setup arrived after the app did. Anyone with a trigger key already on
        // disk, or who came across from the old identity, has configured this app
        // once already and must not be marched through it again — so an existing
        // install is silently marked as done. Only a genuinely fresh one is asked.
        if let done = defaults.object(forKey: "didCompleteOnboarding") as? Bool {
            didCompleteOnboarding = done
        } else {
            let looksEstablished = savedKey != nil
                || defaults.bool(forKey: "migratedFromParla")
                || defaults.object(forKey: "vocabulary") != nil
            didCompleteOnboarding = looksEstablished
            defaults.set(looksEstablished, forKey: "didCompleteOnboarding")
        }

        if let raw = defaults.array(forKey: "enabledLanguages") as? [String] {
            enabledLanguages = Set(raw.compactMap(Language.init(rawValue:)))
        } else {
            enabledLanguages = [.italian, .english, .french]
        }
        if enabledLanguages.isEmpty { enabledLanguages = [.english] }
    }

    /// The Mac's own language, for the first screen someone ever sees — explaining
    /// an app in a language the reader may not have is a strange way to begin.
    nonisolated static var systemLanguage: Language {
        switch Locale.preferredLanguages.first?.prefix(2).lowercased() {
        case "it": return .italian
        case "fr": return .french
        default:   return .english
        }
    }

    private func persist(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    private func persistLanguages() {
        defaults.set(enabledLanguages.map(\.rawValue), forKey: "enabledLanguages")
    }
}
