import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Non privato per una ragione sola: la sonda `--scatta --menu-aperto` deve poter cliccare
    /// questo bottone per fotografare il menu VERO, invece di ridisegnarne una copia.
    var statusItem: NSStatusItem!
    private let state = AppState.shared
    private let history = TranscriptHistory.shared
    private var hotkey: HotkeyManager!
    private var editHotkey: HotkeyManager?   // Edit-Mode trigger (optional feature)
    private var controller: DictationController!
    private var recentMenu: NSMenu!
    private var languageMenu: NSMenu!
    /// Il pannello disegnato in testa al menu e la vista che lo ospita. Tenuta perché il contenuto
    /// si ricostruisce a ogni apertura: vedi `menuNeedsUpdate`.
    private var panelHost: NSHostingView<MenuPanel>!
    private var accessibilityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Tenuto per una ragione sola: liberarlo prima che l'app esca. Vedi
    /// `applicationWillTerminate`.

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        observeStatus()
        observeLanguage()

        // Both engines from launch, neither loaded until used, and one switch
        // between them. `speechSwitch` is kept so Preferences can change the
        // choice without rebuilding the controller.
        let transcriber: Transcriber
        #if canImport(WhisperKit) && canImport(FluidAudio)
        let bothEngines = SpeechEngineSwitch(
            engine: state.speechEngine,
            whisper: WhisperKitTranscriber(modelName: state.whisperModel),
            parakeet: ParakeetTranscriber())
        speechSwitch = bothEngines
        transcriber = bothEngines
        #elseif canImport(WhisperKit)
        transcriber = WhisperKitTranscriber(modelName: state.whisperModel)
        #else
        transcriber = MockTranscriber()
        #endif

        let translator: Translator
        #if canImport(MLXLLM)
        translator = MLXTranslator(engine: .shared)
        #else
        translator = NoOpTranslator()
        #endif

        controller = DictationController(state: state, transcriber: transcriber, translator: translator)
        controller.warmUp()   // preload models in the background → instant first dictation

        // Sleep evicts what "never free the memory" promised to keep. Re-warming
        // on wake is what makes that setting true for the whole day rather than
        // until the first time he closes the lid.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.controller.warmUpAfterWake() }
        }

        hotkey = HotkeyManager(keyCode: state.hotKeyCode)
        hotkey.onAction = { [weak self] action in
            // `isHandsFree` is read at emit time, when the recogniser has already
            // moved into its listening state — that is what tells the controller
            // this recording has no finger holding it open.
            let handsFree = self?.hotkey.isHandsFree ?? false
            Task { @MainActor in self?.controller.handle(action, handsFree: handsFree) }
        }
        controller.onSilenceStop = { [weak self] in self?.hotkey.settleToIdle() }
        hotkey.onLearn = { [weak self] in
            Task { @MainActor in self?.learnSelectedWord() }
        }
        hotkey.onAddCorrection = { [weak self] in
            Task { @MainActor in self?.addCorrection() }
        }
        hotkey.onCopyLast = { [weak self] in
            Task { @MainActor in self?.copyLast() }
        }
        hotkey.onSummarize = { [weak self] in
            Task { @MainActor in self?.summarizeLast() }
        }
        hotkey.onFixLast = { [weak self] in
            Task { @MainActor in self?.correctLastDictation() }
        }

        // Pin the on-device cleanup model to the saved choice and apply the saved
        // push-to-talk preference before the tap goes live.
        controller.setCleanupModel(state.cleanupModelID)
        hotkey.setMode(state.triggerMode)

        // ISC-107 is closed; this is the guard that keeps it closed. Silent
        // unless the footprint climbs back over the ceiling.
        Footprint.startWatching()

        // Le registrazioni senza testo non sono dettature: si buttano all'avvio,
        // così il pannello non gliele mette davanti da correggere.
        Task.detached(priority: .utility) { DictationArchive.discardOrphans() }

        // A fresh install goes through setup instead of the silent permission
        // prompts: the flow asks for the same two permissions, but with the reason
        // next to each, and it ends knowing which key to hold. An existing install
        // never sees it (AppState marks those as already done).
        if state.didCompleteOnboarding {
            requestPermissionsThenStart()
        } else {
            showOnboarding()
        }
    }

    // `applicationWillTerminate` è stato tolto col motore whisper.cpp
    // (2026-08-19): esisteva solo per chiudere il contesto ggml prima dei
    // distruttori statici, che altrimenti facevano abortire l'app in uscita con
    // exit 134. Senza quel motore non resta niente da spegnere a mano.

    // MARK: Main menu (only visible while a window of ours is up)

    /// macOS does NOT implement copy & paste inside the text field: it routes
    /// ⌘X/⌘C/⌘V/⌘A/⌘Z through the application's MAIN menu. `NSApp.sendEvent`
    /// offers every key-down to `mainMenu.performKeyEquivalent(with:)` before
    /// any window sees it, and a menu-bar app has no main menu unless it builds
    /// one. Without this, every text field in Kalamos — the vocabulary, the
    /// corrections, the cleanup instructions — silently refuses paste: the field
    /// works fine, the keystroke just never reaches it.
    ///
    /// An `.accessory` app never owns the menu bar, so most of the time this is
    /// invisible dispatch table. It becomes visible for exactly as long as
    /// Preferences or setup is open (those switch the app to `.regular`), which
    /// is why it carries a proper application menu and not only Edit.
    ///
    /// Selectors are written as strings on purpose: `undo:`/`redo:` are declared
    /// on no public type (NSUndoManager receives them through the chain), and
    /// `#selector(NSText.copy(_:))` is ambiguous against `NSObject.copy()`.
    private func setupMainMenu() {
        let app = NSMenu()
        let prefs = NSMenuItem(title: L.t("Preferenze…", "Preferences…", "Préférences…"),
                               action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        app.addItem(prefs)
        app.addItem(.separator())
        let quit = NSMenuItem(title: L.t("Esci da Kalamos", "Quit Kalamos", "Quitter Kalamos"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        app.addItem(quit)
        let appItem = NSMenuItem()
        appItem.submenu = app

        let edit = NSMenu(title: L.t("Modifica", "Edit", "Édition"))
        func add(_ title: String, _ selector: String, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add(L.t("Annulla", "Undo", "Annuler"), "undo:", "z")
        add(L.t("Ripristina", "Redo", "Rétablir"), "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add(L.t("Taglia", "Cut", "Couper"), "cut:", "x")
        add(L.t("Copia", "Copy", "Copier"), "copy:", "c")
        add(L.t("Incolla", "Paste", "Coller"), "paste:", "v")
        add(L.t("Incolla senza formato", "Paste and Match Style", "Coller sans mise en forme"),
            "pasteAsPlainText:", "v", [.command, .option, .shift])
        edit.addItem(.separator())
        add(L.t("Seleziona tutto", "Select All", "Tout sélectionner"), "selectAll:", "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu bar

    /// What you DO, not what you decide.
    ///
    /// This menu used to carry every setting the app has, three levels deep —
    /// Cleanup ▸ AI Model ▸ a list of models, Speech & Language ▸ Vocabulary ▸ a
    /// list of words. Choosing anything meant holding the mouse still through two
    /// hover-open animations, and the deeper a setting sat the less it existed.
    /// All of it moved to Preferences on 2026-07-31; what stays here is the
    /// handful of things you reach for while working.
    /// Live handle on the engine choice. Nil only in a build without one of the
    /// two engines compiled in, which is the mock path.
    private var speechSwitch: AnyObject?

    /// Non privata: la sonda costruisce il menu con QUESTO codice, così la fotografia non può
    /// mostrare un menu che nell'app non esiste.
    func setupMenuBar() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        updateIcon(for: state.status)

        let menu = NSMenu()
        menu.delegate = self

        // Il pannello, che è la testa del menu e la livrea dell'app.
        //
        // Prima qui c'erano due voci disabilitate — la riga di stato e il suggerimento del tasto —
        // che si nascondevano quando non avevano niente da dire, perché come voci di menu erano
        // arredamento: "Kalamos — in attesa" è vero quasi ogni volta che apri, e il suggerimento
        // insegna un tasto che hai imparato il primo giorno. Disegnate invece che scritte cambiano
        // mestiere: il nome dell'app grande, lo stato piccolo sulla destra e una riga di dettaglio
        // sotto sono la stessa forma con cui si aprono Otium e NoSleep, e a quel punto la riga
        // "in attesa" non è più rumore, è il posto dove uno guarda per sapere come sta.
        //
        // **L'altezza la detta il contenuto, mai una costante**: la riga di sotto va a capo quando
        // il suggerimento del tasto è lungo, e un numero scritto a mano scommette sull'altezza del
        // testo — scommessa che si perde alla prima traduzione più lunga dell'originale.
        panelHost = MenuPanel.host(panelContent())
        let panelItem = NSMenuItem()
        panelItem.view = panelHost
        menu.addItem(panelItem)
        menu.addItem(.separator())

        // ⌃⌥, not ⌘. These two used to print ⌘C and ⌘S, which never worked from
        // anywhere except this menu while it was open: a status-bar menu is not
        // the main menu, and an `.accessory` app never owns the menu bar. The
        // shortcuts are real now — `HotkeyManager` catches them in the global tap —
        // and the mask makes the menu print the keys you actually press.
        // The language of the dictation, one click away (ISC-114).
        //
        // It lived only in Preferences, and it is not only a convenience there:
        // it is the practical remedy for the "Amen". Whisper marked an entirely
        // Italian sentence `lang=en`, decoded it with an English prior and stuck
        // a trailing-silence hallucination on the end. The app already writes the
        // diagnosis under those chips — *choosing one is more accurate than
        // having it guessed every sentence* — and until now applying it meant
        // opening a window.
        //
        // Immediate, not a draft. Preferences batches settings behind "Apply
        // changes" because a settings screen is where you DECIDE; the menu bar is
        // where you DO, and a language you have to confirm twice is a language
        // you stop switching.
        languageMenu = NSMenu()
        let languageItem = NSMenuItem(title: L.t("Lingua della dettatura", "Dictation Language",
                                                 "Langue de la dictée"),
                                      action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let copyLast = NSMenuItem(title: L.t("Copia l'ultima trascrizione",
                                             "Copy Last Transcription",
                                             "Copier la dernière transcription"),
                                  action: #selector(copyLast), keyEquivalent: "c")
        copyLast.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(copyLast)
        let summarize = NSMenuItem(title: L.t("Riassumi l'ultima dettatura",
                                              "Summarize Last Dictation",
                                              "Résumer la dernière dictée"),
                                   action: #selector(summarizeLast), keyEquivalent: "s")
        summarize.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(summarize)
        recentMenu = NSMenu()
        let recentItem = NSMenuItem(title: L.t("Trascrizioni recenti", "Recent Transcriptions",
                                               "Transcriptions récentes"),
                                    action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        // Teaching Kalamos, the two of them together.
        //
        // ⌃⌥L has worked since the day it was written and NOTHING said so: the
        // only place it appeared was a note under a text field in Preferences,
        // which you read once. A shortcut nobody can discover is a shortcut only
        // its author has. Its sibling ⌃⌥K arrives with a menu item from the
        // start, and the two sit next to each other because they are the same
        // move — teaching it a word it gets wrong.
        menu.addItem(.separator())
        let learn = NSMenuItem(title: L.t("Impara la parola selezionata",
                                          "Learn Selected Word",
                                          "Apprendre le mot sélectionné"),
                               action: #selector(learnSelectedWord), keyEquivalent: "l")
        learn.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(learn)
        let correction = NSMenuItem(title: L.t("Aggiungi una correzione…",
                                               "Add a Correction…",
                                               "Ajouter une correction…"),
                                    action: #selector(addCorrection), keyEquivalent: "k")
        correction.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(correction)
        // The third of the family, and the only one that teaches the ear instead
        // of the spelling: ⌃⌥L and ⌃⌥K fix a word from now on, ⌃⌥V writes down
        // what was said, so the sound and the truth end up in the same folder.
        let truth = NSMenuItem(title: L.t("Correggi l’ultima dettatura…",
                                          "Fix the Last Dictation…",
                                          "Corriger la dernière dictée…"),
                               action: #selector(correctLastDictation), keyEquivalent: "v")
        truth.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(truth)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: L.t("Preferenze…", "Preferences…", "Préférences…"),
                               action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(prefs)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L.t("Esci da Kalamos", "Quit Kalamos", "Quitter Kalamos"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp   // terminate: lives on NSApplication, not AppDelegate
        menu.addItem(quit)

        menu.items.forEach { if $0.action != nil && $0.target == nil { $0.target = self } }
        statusItem.menu = menu
    }

    private func triggerHint() -> String {
        MenuPanel.Content.triggerHint(key: HotkeyManager.displayName(for: state.hotKeyCode),
                                      mode: state.triggerMode)
    }

    /// Quello che il pannello dice adesso. Un posto solo, letto dal menu vero e dalla sonda che lo
    /// fotografa, così la fotografia mostra la stessa cosa che vedi aprendo il menu.
    private func panelContent() -> MenuPanel.Content {
        let language = state.autoDetectLanguage
            ? L.t("lingua automatica", "language detected", "langue automatique")
            : state.defaultLanguage.displayName
        return MenuPanel.Content(
            status: state.status,
            phrase: L.statusPhrase(state.status),
            detail: MenuPanel.Content.detail(dictationCount: history.entries.count,
                                             hint: triggerHint(),
                                             engine: state.speechEngine.title,
                                             language: language))
    }

    // MARK: Menu refresh
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }

        // Il pannello si ricostruisce qui, non si tiene in sincrono: l'apertura del menu è l'unico
        // istante in cui qualcuno lo guarda, e una vista dentro un `NSMenuItem` non ha un ciclo di
        // aggiornamento su cui contare. L'altezza si ricalcola con lui, perché la riga di sotto
        // cambia lunghezza quando il suggerimento del tasto lascia il posto a motore e lingua.
        panelHost.rootView = MenuPanel(content: panelContent())
        MenuPanel.resize(panelHost)

        rebuildRecentMenu()
        rebuildLanguageMenu()
    }

    /// Automatic + one row per language the user has enabled, ticked on the live
    /// choice. Rebuilt per open rather than kept in sync: Preferences can change
    /// both values behind this menu's back, and a tick that lies is worse than no
    /// tick at all.
    private func rebuildLanguageMenu() {
        languageMenu.removeAllItems()

        let auto = NSMenuItem(title: L.t("Automatico", "Detect it", "Automatique"),
                              action: #selector(pickLanguage(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = "auto"
        auto.state = state.autoDetectLanguage ? .on : .off
        languageMenu.addItem(auto)
        languageMenu.addItem(.separator())

        // Only the enabled ones: offering a language the transcriber is not
        // allowed to return would be a control that does nothing.
        for language in Language.allCases where state.enabledLanguages.contains(language) {
            let item = NSMenuItem(title: language.displayName,
                                  action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = (!state.autoDetectLanguage && state.defaultLanguage == language)
                ? .on : .off
            languageMenu.addItem(item)
        }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "auto" {
            state.autoDetectLanguage = true
            Log.write("language: auto-detect (from the menu)")
        } else if let language = Language(rawValue: raw) {
            state.autoDetectLanguage = false
            state.defaultLanguage = language
            Log.write("language: forced to \(language.rawValue) (from the menu)")
        }
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let entries = history.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: L.t("Ancora niente", "No transcriptions yet",
                                              "Rien pour l’instant"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.menuLabel, action: #selector(copyEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.toolTip = entry.text
            recentMenu.addItem(item)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: L.t("Svuota la cronologia", "Clear History",
                                          "Vider l’historique"),
                               action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    // MARK: Preferences

    @objc private func showPreferences() {
        PreferencesWindow.shared.show(state: state, actions: PreferencesActions(
            apply: { [weak self] draft in self?.apply(draft) },
            isLaunchAtLogin: { SMAppService.mainApp.status == .enabled },
            showDiagnostics: { [weak self] in self?.showDiagnostics() },
            rerunOnboarding: { [weak self] in self?.showOnboarding() }))
    }

    /// Take a draft and make it true.
    ///
    /// One writer for every setting the window can change, and every field is
    /// compared before it is written: re-registering the event tap tears down a
    /// global tap, and swapping a model throws away a loaded one. Applying what
    /// did not change would pay both costs for nothing.
    func apply(_ draft: SettingsDraft) {
        if draft.uiLanguage != state.uiLanguage { state.uiLanguage = draft.uiLanguage }
        if draft.hotKeyCode != state.hotKeyCode { applyTriggerKey(draft.hotKeyCode) }
        if draft.triggerMode != state.triggerMode { applyTriggerMode(draft.triggerMode) }

        state.autoDetectLanguage = draft.autoDetectLanguage
        state.defaultLanguage = draft.defaultLanguage
        state.translationEnabled = draft.translationEnabled
        state.translationTarget = draft.translationTarget
        state.formatterMode = draft.formatterMode
        state.spaceBetweenDictations = draft.spaceBetweenDictations
        state.smartCapitalization = draft.smartCapitalization
        state.lowercaseFirstLetter = draft.lowercaseFirstLetter
        state.removeTrailingPeriod = draft.removeTrailingPeriod
        state.insertionMode = draft.insertionMode
        state.notifyCleanupRejected = draft.notifyCleanupRejected

        applySpeechEngine(draft.speechEngine)
        applySpeechModel(draft.whisperModel)
        applyCleanupModel(draft.cleanupModelID)

        let prompt = draft.cleanupPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        state.cleanupPromptOverride = prompt.isEmpty ? nil : prompt

        if draft.idleSeconds != Tuning.idleUnloadRaw { Tuning.setIdleUnload(draft.idleSeconds) }

        if draft.editModeEnabled != state.editModeEnabled
            || draft.editModeKeyCode != state.editModeKeyCode {
            state.editModeEnabled = draft.editModeEnabled
            state.editModeKeyCode = draft.editModeKeyCode
            startEditHotkeyIfNeeded()
        }

        if draft.launchAtLogin != (SMAppService.mainApp.status == .enabled) {
            setLaunchAtLogin(draft.launchAtLogin)
        }
    }

    /// The menu is built once, in one language. When that language changes the
    /// menu has to be built again — otherwise the setting appears to do nothing
    /// until the next launch, which is indistinguishable from a broken control.
    private func observeLanguage() {
        state.$uiLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setupMainMenu()
                    self?.setupMenuBar()
                }
            }
            .store(in: &cancellables)
    }

    /// Learn the currently-selected word (⌃⌥L). Two strategies, in order:
    ///  1. Accessibility API — read the focused element's selected text
    ///     directly (native apps: instant, nothing for the user to do).
    ///  2. Clipboard read — for apps that expose no selection over AX
    ///     (Electron/Chromium like Claude, or anything behind Secure Input).
    ///     We deliberately do NOT synthesize ⌘C there: Electron ignores injected
    ///     keys and macOS Secure Input blocks them outright (verified:
    ///     "changeCount moved: false"). The user copies the word (⌘C) first; we
    ///     just read the clipboard. Gesture in those apps: select → ⌘C → ⌃⌥L.
    @objc private func learnSelectedWord() {
        guard let picked = Self.selectedWord() else {
            Log.write("learn ⌃⌥L: nothing to learn (AX empty, clipboard empty)")
            Sounds.no()
            return
        }
        commitLearnedWord(picked.text, source: picked.source)
    }

    /// The word the user means, read the same way for ⌃⌥L and ⌃⌥K.
    ///
    /// One reader for both, because they drifted the first time they were
    /// written apart — see `pick(ax:clipboard:)` for what the drift cost.
    static func selectedWord() -> (text: String, source: String)? {
        pick(ax: selectedTextViaAX(), clipboard: NSPasteboard.general.string(forType: .string))
    }

    /// Which of the two reads to use — the whole decision, as a pure function.
    ///
    /// **An empty selection is a string, not a nil.** A focused text field that
    /// supports `kAXSelectedText` and has nothing selected answers with `""`.
    /// `ax ?? clipboard` therefore takes the empty answer and never asks the
    /// clipboard at all — which is precisely why ⌃⌥K shipped with no prefill on
    /// 2026-08-01 while ⌃⌥L, which happened to test for emptiness, worked. The
    /// two paths look identical when you read them; only one of them is right.
    static func pick(ax: String?, clipboard: String?) -> (text: String, source: String)? {
        if let s = ax?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return (s, "AX")
        }
        if let s = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return (s, "clipboard")
        }
        return nil
    }

    /// Word-shaped enough to be a vocabulary entry or the left half of a rule.
    /// A paragraph on the clipboard is not a misheard word.
    static func isWordShaped(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 60 && !s.contains("\n")
    }

    /// Validate + store a learned word, with a confirmation sound.
    private func commitLearnedWord(_ s: String, source: String) {
        guard Self.isWordShaped(s) else {
            Log.write("learn ⌃⌥L: ignored via \(source) (\"\(s)\" — empty/too long/multiline)")
            Sounds.no()
            return
        }
        Vocabulary.add(s)
        Log.write("learn ⌃⌥L: added \"\(s)\" via \(source)")
        Self.markLastDictation(teaching: s)
        Sounds.ok()
    }

    /// Teaching it a word seconds after a dictation IS a report that the
    /// dictation was wrong, so it is worth recording as one. Free evidence: he
    /// made the gesture for his own reasons and this costs him nothing extra.
    ///
    /// The window is deliberately short. Teaching a word an hour later is
    /// housekeeping, not a reaction, and marking a stale recording would put
    /// noise into the one place that is supposed to be signal.
    private static func markLastDictation(teaching term: String) {
        guard let recent = LastDictation.shared.recent(within: 60) else { return }
        DictationArchive.mark(recent.wav, reason: L.t(
            "gli hai insegnato «\(term)» subito dopo",
            "you taught it “\(term)” right afterwards",
            "vous lui avez appris « \(term) » juste après"))
    }

    /// Add a replacement rule (⌃⌥K) — the two-valued sibling of ⌃⌥L.
    ///
    /// A vocabulary word is ONE value, so ⌃⌥L can finish in silence. A
    /// correction is two, what it hears and what it should write, and the second
    /// half only exists in your head: this one has to ask. What it can do is
    /// arrive with the first half already filled, using the same read as ⌃⌥L —
    /// the AX selection, then the clipboard. So the gesture is: select the wrong
    /// word Kalamos just wrote, press ⌃⌥K, type the right one, Enter.
    @objc private func addCorrection() {
        let picked = Self.selectedWord()
        let heard = picked.map { Self.isWordShaped($0.text) ? $0.text : "" } ?? ""
        Log.write("correction ⌃⌥K: prefill \"\(heard)\" via \(picked?.source ?? "nothing")")
        CorrectionWindow.shared.show(heard: heard) { [weak self] wrong, correct in
            Corrections.add(wrong: wrong, correct: correct)
            Log.write("correction ⌃⌥K: added \"\(wrong)\" → \"\(correct)\"")
            Self.markLastDictation(teaching: correct)
            Sounds.ok()
            _ = self
        }
    }

    /// Write down what the last dictation should have said (⌃⌥V).
    ///
    /// The archive keeps the sound and what came out of it; neither of those is
    /// the truth when the transcription is the thing that went wrong. This is the
    /// only path by which a correct verbatim ever reaches the disk, which is why
    /// the panel opens already filled with the raw text: correcting three words
    /// is a gesture, retyping a paragraph is a chore nobody does twice.
    ///
    /// It reads the raw text from memory when the dictation happened in this run,
    /// and from the sidecar otherwise, so it still works the morning after.
    @objc private func correctLastDictation() {
        guard let opening = LastDictation.shared.snapshot?.wav ?? DictationArchive.latest else {
            Log.write("verbatim ⌃⌥V: no dictation archived — nothing to correct")
            Sounds.no()
            return
        }
        Log.write("verbatim ⌃⌥V: opened for \(opening.lastPathComponent)")
        // The recording arrives with the correction, because in a list the
        // selection moves: a verbatim written against whichever dictation
        // happened to be last would teach the app somebody else's sentence.
        TruthWindow.shared.show(initial: opening) { wav, verbatim, how in
            let raw = DictationArchive.section("GREZZO", in: wav) ?? ""
            DictationArchive.recordTruth(wav, verbatim: verbatim, how: how)
            // ISC-178, sua richiesta del 2026-08-12: la correzione non serve solo
            // a fare da materiale d'allenamento, deve valere anche in avanti. Le
            // parole che ha rimesso a posto diventano regole, e la stessa parola
            // esce giusta dalla prossima dettatura invece che dalla prossima
            // versione dell'app.
            //
            // Quello che NON diventa una regola sta in `LearnedCorrections`, ed è
            // la parte che conta: una regola è globale, permanente e silenziosa.
            // Only a correction teaches a rule. A confirmation says the words
            // were already right, so there is no wrong-to-right pair in it, and
            // running the learner on one would mine a difference that is not
            // there.
            let known = Set(Corrections.rules.map(\.wrong))
            let lang = DictationIndex.details(of: wav).language ?? "it"
            for rule in how == .corrected
                ? LearnedCorrections.rules(heard: raw, meant: verbatim, known: known,
                                           knowsWord: { SystemDictionary.knows($0, language: lang) })
                : [] {
                Corrections.add(wrong: rule.wrong, correct: rule.correct)
                Log.write("verbatim ⌃⌥V: imparata la correzione «\(rule.wrong)» → «\(rule.correct)»")
            }
            // Sua richiesta del 2026-08-15: le coppie corrette servono a un
            // fine-tuning, e l'archivio è potato per progetto. Ogni tanto, in
            // blocco, escono di lì e vanno in una cartella che nessuna potatura
            // tocca.
            TrainingCorpus.exportIfBatchFull()
            // Niente suono qui (sua richiesta, 2026-08-16): il bottone si
            // disabilita e compare «Salvata.», la conferma è già negli occhi.
            // Il suono resta su ⌃⌥L e ⌃⌥K, gesti senza finestra dove è l'unico
            // segnale che qualcosa è successo.
        }
    }

    /// Selected text of the system-wide focused UI element, via Accessibility.
    /// Returns nil when the focused app exposes no selection over AX.
    private static func selectedTextViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    // MARK: Settings that need more than being written down

    /// Changing the trigger is not a matter of writing a number down: the global
    /// event tap must be torn down and re-registered on the new key. Shared by
    /// Preferences and first-run setup, so the two cannot drift apart.
    func applyTriggerKey(_ code: UInt16) {
        state.hotKeyCode = code
        hotkey.stop()
        hotkey.updateKeyCode(code)
        if Permissions.accessibilityTrusted(prompt: false) { _ = hotkey.start() }
        startEditHotkeyIfNeeded()   // re-evaluate the edit-key ≠ trigger-key guard
    }

    /// Writing the id down and telling the engine are one operation, done in one
    /// place. Split between a view and a delegate they can disagree, and the
    /// setting then shows a model the engine is not running.
    /// Same shape as `applySpeechModel`: writing the choice down and telling the
    /// engine are one operation in one place, so the setting cannot show an
    /// engine that is not the one listening.
    func applySpeechEngine(_ engine: SpeechEngine) {
        guard engine != state.speechEngine else { return }
        state.speechEngine = engine
        #if canImport(WhisperKit) && canImport(FluidAudio)
        (speechSwitch as? SpeechEngineSwitch)?.use(engine)
        #endif
    }

    func applySpeechModel(_ id: String) {
        guard id != state.whisperModel else { return }
        state.whisperModel = id
        controller.setSpeechModel(id)
    }

    func applyCleanupModel(_ id: String) {
        guard id != state.cleanupModelID else { return }
        state.cleanupModelID = id
        controller.setCleanupModel(id)
    }

    /// What setup proposes for this Mac, put into effect.
    ///
    /// It goes through the same three `apply…` calls the Preferences window uses,
    /// rather than assigning the fields: those are where the live engine is told,
    /// and a setting written down without telling it only takes effect at the next
    /// launch — which looks exactly like a control that does nothing.
    ///
    /// The cleanup model id is written even when the proposal is punctuation-only,
    /// so turning the model on later lands on the right one for the machine.
    func applyRecommendation(_ proposal: Recommendation) {
        applySpeechEngine(proposal.engine)
        applyCleanupModel(proposal.cleanupModelID)
        state.formatterMode = proposal.formatterMode
        Tuning.setIdleUnload(proposal.idleUnloadSeconds)
    }

    /// The live recogniser has to be told, or the setting only takes effect on the
    /// next launch. Shared with setup, same reason as the trigger key.
    func applyTriggerMode(_ mode: TriggerMode) {
        state.triggerMode = mode
        hotkey.setMode(mode)
    }

    /// The name of each mode, everywhere: the menu, Preferences and setup.
    ///
    /// `.both` was called "Both" back when there were two modes to be both of.
    /// With four on the page — hold, one tap, double-tap, both — "Both" stopped
    /// naming anything: both of which? It now says which two it means. His point,
    /// 2026-08-02, looking at the four tiles side by side.
    static func modeTitle(_ mode: TriggerMode) -> String {
        switch mode {
        case .hold:      return L.t("Tieni premuto", "Hold to talk", "Maintenir")
        case .doubleTap: return L.t("Doppio tocco", "Double-tap", "Double-appui")
        case .both:      return L.t("Premuto o doppio tocco", "Hold or double-tap",
                                    "Maintenir ou double-appui")
        case .singleTap: return L.t("Un tocco", "One tap", "Un appui")
        }
    }

    /// (Re)install the Edit-Mode hot key. Active only when Edit Mode is on AND
    /// its key differs from the dictation trigger (else it would double-fire).
    /// The edit recognizer is always hold-to-talk regardless of the global
    /// push-to-talk setting — you hold the key and speak the instruction.
    private func startEditHotkeyIfNeeded() {
        editHotkey?.stop()
        editHotkey = nil
        guard state.editModeEnabled, state.editModeKeyCode != state.hotKeyCode else { return }
        let h = HotkeyManager(keyCode: state.editModeKeyCode)
        h.onAction = { [weak self] action in
            Task { @MainActor in self?.controller.handle(action, editMode: true) }
        }
        if Permissions.accessibilityTrusted(prompt: false) { _ = h.start() }
        editHotkey = h
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            state.status = .error(L.t("Avvio al login non riuscito", "Login item failed",
                                      "Élément d’ouverture impossible")
                                  + ": \(error.localizedDescription)")
        }
    }

    /// Show first-run setup: at launch for a fresh install, on demand from Preferences.
    func showOnboarding() {
        OnboardingWindow.shared.show(state: state, actions: OnboardingActions(
            applyTriggerKey: { [weak self] in self?.applyTriggerKey($0) },
            applyTriggerMode: { [weak self] in self?.applyTriggerMode($0) },
            applyRecommendation: { [weak self] in self?.applyRecommendation($0) },
            // These two must ASK, not merely report. Setup previously showed a row
            // per permission with a link to System Settings and never triggered the
            // system prompt at all — so you could walk to the end of the flow, be
            // told everything was ready, and own an app that could not hear you.
            requestMicrophone: { done in Permissions.requestMicrophone { done($0) } },
            requestAccessibility: { _ = Permissions.accessibilityTrusted(prompt: true) },
            openMicrophoneSettings: { Permissions.openMicrophoneSettings() },
            finish: { [weak self] in
                self?.state.didCompleteOnboarding = true
                // Setup is also where the permissions get granted, so the tap may
                // only have become installable just now.
                if Permissions.accessibilityTrusted(prompt: false) { _ = self?.hotkey.start() }
            }))
    }

    // MARK: Actions

    @objc private func copyLast() {
        guard let last = history.last else { NSSound.beep(); return }
        history.copyToClipboard(last)
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? TranscriptEntry else { return }
        history.copyToClipboard(entry)
    }

    @objc private func clearHistory() { history.clear() }

    /// Summarize the LAST dictation, not the last twenty.
    ///
    /// It used to pile the last twenty entries into one numbered list and
    /// summarize that. Dictations are not a conversation: an email, a shopping
    /// list and a stray thought are three unrelated texts, and a summary of all
    /// three at once is a fruit salad. What is worth summarizing is the one long
    /// thing you just said.
    @objc private func summarizeLast() {
        guard let last = history.last else { NSSound.beep(); return }
        let language = state.translationEnabled ? state.translationTarget : state.defaultLanguage
        #if canImport(MLXLLM)
        state.status = .working(.summarizing)
        Task {
            do {
                let summary = try await Summarizer().summarize(last.text, language: language)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
                state.status = .idle
                self.showSummary(summary)
            } catch {
                state.status = .error(L.t("Riassunto non riuscito", "Summary failed",
                                          "Résumé impossible"))
            }
        }
        #else
        NSSound.beep()
        #endif
    }

    private func showSummary(_ text: String) {
        let alert = NSAlert()
        alert.messageText = L.t("Riassunto (copiato negli appunti)",
                                "Summary (copied to clipboard)",
                                "Résumé (copié dans le presse-papiers)")
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The same report `--doctor` prints — but run from HERE it is trustworthy.
    /// macOS attributes privacy grants to the responsible process, so a terminal
    /// invocation reads the terminal's Microphone and Accessibility rather than
    /// Kalamos's. Inside the app, the answer is Kalamos's own.
    @objc private func showDiagnostics() {
        let (text, failures) = Doctor.report()

        // Monospaced, because the report is column-aligned and a proportional
        // font turns it into ragged soup.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.drawsBackground = false
        // Never wrap. A wrapped line restarts at column zero and silently breaks
        // the alignment that makes the report readable — scroll sideways instead.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let alert = NSAlert()
        alert.messageText = failures == 0
            ? L.t("Kalamos sta bene", "Kalamos is healthy", "Kalamos va bien")
            : L.t("\(failures) problem\(failures == 1 ? "a" : "i")",
                  "\(failures) problem\(failures == 1 ? "" : "s") found",
                  "\(failures) problème\(failures == 1 ? "" : "s")")
        alert.alertStyle = failures == 0 ? .informational : .warning
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L.t("Copia", "Copy", "Copier"))   // for a bug report
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Status icon
    private func observeStatus() {
        state.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                MainActor.assumeIsolated {
                    self?.updateIcon(for: s)
                    DownloadPanel.shared.update(for: s)
                    self?.updateWave(for: s)
                }
            }
            .store(in: &cancellables)
    }

    /// The wave is on screen for exactly as long as the microphone is open.
    ///
    /// `.listening` is the one status that means the microphone is open — set when
    /// the recorder starts, replaced by `.transcribing` the instant the recording
    /// ends — so hanging the island off it needs no second piece of state that
    /// could fall out of step with the first. Everything else, the seconds of
    /// cleanup after a dictation included, is not listening and shows nothing.
    private func updateWave(for status: DictationStatus) {
        if status == .listening {
            WaveIsland.shared.show(sampling: { [weak self] in
                self?.controller?.microphoneLevel() ?? 0
            })
        } else {
            WaveIsland.shared.hide()
        }
    }

    /// One icon per thing that is actually happening.
    ///
    /// Every one of these used to be a download arrow, because three different
    /// states shared one case. So the arrow appeared when a cached model was
    /// being read off the disk — every launch, and again after every idle unload
    /// — and while summarising, which touches no network at all. Reported on
    /// 2026-07-31 as "why does a download keep starting?"; nothing was starting.
    /// At rest and while recording, the app's own mark — a reed pen and the
    /// stroke it left. For everything else, the system symbol that says what is
    /// happening: those states are information, and information beats identity
    /// while you are waiting for something.
    ///
    /// La scelta del glifo sta in `StatusGlyph` e non più qui, perché adesso la fanno in due — la
    /// barra e il pannello in testa al menu — e scritta due volte sarebbe divergita alla prima
    /// aggiunta di uno stato, lasciando un'icona che contraddice la frase accanto.
    private func updateIcon(for status: DictationStatus) {
        statusItem.button?.image = StatusGlyph.image(for: status)
        // **No explicit width here, and that is a measured decision.** Asked on 2026-08-12 to make
        // the bar items narrower, the obvious move was `statusItem.length = size + small padding`.
        // macOS raises it back in silence: measured in Otium, a request for 35 points came back as
        // 51, and here the icon did not move by a single pixel. A width you ask for and never read
        // back is a hope, so the request is gone and the finding stays written down.
    }

    // MARK: Permissions → start hot key (auto-detects Accessibility grant; no restart)
    private func requestPermissionsThenStart() {
        Permissions.requestMicrophone { [weak self] micOK in
            guard let self else { return }
            if !micOK { Permissions.openMicrophoneSettings() }
            self.startOrAwaitAccessibility()
        }
    }

    private func startOrAwaitAccessibility() {
        if Permissions.accessibilityTrusted(prompt: true) {
            startHotkey()
            return
        }
        state.status = .error(L.t("Concedi l'accessibilità — Kalamos parte da solo",
                                  "Grant Accessibility — Kalamos starts automatically",
                                  "Accordez l’accessibilité — Kalamos démarre seul"))
        Permissions.openAccessibilitySettings()
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Permissions.accessibilityTrusted(prompt: false) {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                    self.startHotkey()
                }
            }
        }
    }

    private func startHotkey() {
        if hotkey.start() {
            state.status = .idle
            startEditHotkeyIfNeeded()   // needs Accessibility → start it here too
        } else {
            state.status = .error(L.t("Non riesco a installare il tasto (accessibilità?)",
                                      "Couldn't install hot key (Accessibility?)",
                                      "Impossible d’installer la touche (accessibilité ?)"))
        }
    }
}
