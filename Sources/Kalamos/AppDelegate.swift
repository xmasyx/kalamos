import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState.shared
    private let history = TranscriptHistory.shared
    private var hotkey: HotkeyManager!
    private var editHotkey: HotkeyManager?   // Edit-Mode trigger (optional feature)
    private var controller: DictationController!
    private var recentMenu: NSMenu!
    private var hintItem: NSMenuItem!
    private var statusItem_: NSMenuItem!
    private var headerSeparator: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        observeStatus()
        observeLanguage()

        let transcriber: Transcriber
        #if canImport(WhisperKit)
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

        hotkey = HotkeyManager(keyCode: state.hotKeyCode)
        hotkey.onAction = { [weak self] action in
            Task { @MainActor in self?.controller.handle(action) }
        }
        hotkey.onLearn = { [weak self] in
            Task { @MainActor in self?.learnSelectedWord() }
        }

        // Pin the on-device cleanup model to the saved choice and apply the saved
        // push-to-talk preference before the tap goes live.
        controller.setCleanupModel(state.cleanupModelID)
        hotkey.setMode(state.triggerMode)

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
    private func setupMenuBar() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        updateIcon(for: state.status)

        let menu = NSMenu()
        menu.delegate = self

        // The status line and the trigger hint are NOT permanent rows.
        //
        // "Kalamos — idle" says nothing is happening, which is true almost every
        // time you open this menu, and the hint teaches a key you learned on day
        // one. Two lines and a separator of pure furniture above the things you
        // actually came here to click. Both are built here and then shown or
        // hidden per open, in `menuNeedsUpdate`: the status when there IS
        // something happening, the hint until you have dictated a few times.
        statusItem_ = NSMenuItem(title: L.statusLine(state.status), action: nil, keyEquivalent: "")
        statusItem_.isEnabled = false
        menu.addItem(statusItem_)
        hintItem = NSMenuItem(title: triggerHint(), action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        headerSeparator = NSMenuItem.separator()
        menu.addItem(headerSeparator)

        let copyLast = NSMenuItem(title: L.t("Copia l'ultima trascrizione",
                                             "Copy Last Transcription",
                                             "Copier la dernière transcription"),
                                  action: #selector(copyLast), keyEquivalent: "c")
        menu.addItem(copyLast)
        let summarize = NSMenuItem(title: L.t("Riassumi le ultime dettature",
                                              "Summarize Recent Dictations",
                                              "Résumer les dictées récentes"),
                                   action: #selector(summarizeRecent), keyEquivalent: "s")
        menu.addItem(summarize)
        recentMenu = NSMenu()
        let recentItem = NSMenuItem(title: L.t("Trascrizioni recenti", "Recent Transcriptions",
                                               "Transcriptions récentes"),
                                    action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

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
        let key = HotkeyManager.displayName(for: state.hotKeyCode)
        switch state.triggerMode {
        case .both:
            return L.t("Tieni premuto \(key) per parlare · doppio tocco = mani libere",
                       "Hold \(key) to talk · double-tap = hands-free",
                       "Maintenez \(key) · double-appui = mains libres")
        case .hold:
            return L.t("Tieni premuto \(key) per parlare",
                       "Hold \(key) to talk",
                       "Maintenez \(key) pour parler")
        case .doubleTap:
            return L.t("Doppio tocco su \(key) = mani libere",
                       "Double-tap \(key) = hands-free",
                       "Double-appui sur \(key) = mains libres")
        }
    }

    // MARK: Menu refresh
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }

        // Say what is happening only when something is.
        let busy = state.status != .idle
        statusItem_.title = L.statusLine(state.status)
        statusItem_.isHidden = !busy

        // The hint retires itself. Five dictations is enough to know which key
        // you hold; after that it is a line you read past forever.
        let stillLearning = history.entries.count < 5
        hintItem.title = triggerHint()
        hintItem.isHidden = !stillLearning

        headerSeparator.isHidden = !busy && !stillLearning
        rebuildRecentMenu()
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
    private func learnSelectedWord() {
        // Strategy 1: read the selection straight from the focused UI element.
        if let s = Self.selectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            commitLearnedWord(s, source: "AX")
            return
        }

        // Strategy 2: whatever the user last copied (non-destructive read).
        if let s = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            commitLearnedWord(s, source: "clipboard")
        } else {
            Log.write("learn ⌃⌥L: nothing to learn (AX empty, clipboard empty)")
            NSSound(named: "Funk")?.play()
        }
    }

    /// Validate + store a learned word, with a confirmation sound.
    private func commitLearnedWord(_ s: String, source: String) {
        guard !s.isEmpty, s.count <= 60, !s.contains("\n") else {
            Log.write("learn ⌃⌥L: ignored via \(source) (\"\(s)\" — empty/too long/multiline)")
            NSSound(named: "Funk")?.play()
            return
        }
        Vocabulary.add(s)
        Log.write("learn ⌃⌥L: added \"\(s)\" via \(source)")
        NSSound(named: "Glass")?.play()
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
        hintItem.title = triggerHint()
        startEditHotkeyIfNeeded()   // re-evaluate the edit-key ≠ trigger-key guard
    }

    /// Writing the id down and telling the engine are one operation, done in one
    /// place. Split between a view and a delegate they can disagree, and the
    /// setting then shows a model the engine is not running.
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

    /// The live recogniser has to be told, or the setting only takes effect on the
    /// next launch. Shared with setup, same reason as the trigger key.
    func applyTriggerMode(_ mode: TriggerMode) {
        state.triggerMode = mode
        hotkey.setMode(mode)
        hintItem.title = triggerHint()
    }

    static func modeTitle(_ mode: TriggerMode) -> String {
        switch mode {
        case .hold:      return L.t("Tieni premuto", "Hold to talk", "Maintenir")
        case .doubleTap: return L.t("Doppio tocco", "Double-tap", "Double-appui")
        case .both:      return L.t("Entrambi", "Both", "Les deux")
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

    @objc private func summarizeRecent() {
        let texts = history.entries.prefix(20).reversed().map(\.text)   // chronological
        guard !texts.isEmpty else { NSSound.beep(); return }
        let language = state.translationEnabled ? state.translationTarget : state.defaultLanguage
        #if canImport(MLXLLM)
        state.status = .working(.summarizing)
        Task {
            do {
                let summary = try await Summarizer().summarize(Array(texts), language: language)
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
                }
            }
            .store(in: &cancellables)
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
    private func updateIcon(for status: DictationStatus) {
        let label = L.statusLine(status)
        let image: NSImage?
        switch status {
        case .idle:         image = CalamoIcon.image(filled: false)
        case .listening:    image = CalamoIcon.image(filled: true)
        case .transcribing: image = NSImage(systemSymbolName: "waveform", accessibilityDescription: label)
        case .downloading:  image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: label)
        case .loading:      image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: label)
        case .working:      image = NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: label)
        case .error:        image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: label)
        }
        statusItem.button?.image = image
        statusItem_?.title = label
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
