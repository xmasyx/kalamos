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
    private var cleanupMenu: NSMenu!
    private var speechModelMenu: NSMenu!
    private var cleanupModelMenu: NSMenu!
    private var editKeyMenu: NSMenu!
    private var modeMenu: NSMenu!
    private var editModeItem: NSMenuItem!
    private var inputLangMenu: NSMenu!
    private var translateMenu: NSMenu!
    private var triggerMenu: NSMenu!
    private var idleMenu: NSMenu!
    private var vocabMenu: NSMenu!
    private var corrMenu: NSMenu!
    private var hintItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupEditMenu()
        setupMenuBar()
        observeStatus()

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

        // Pin the on-device cleanup model to the saved choice (default 7B → no-op)
        // and apply the saved push-to-talk preference before the tap goes live.
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

    // MARK: Edit menu (⌘X ⌘C ⌘V ⌘A ⌘Z)
    /// macOS does NOT implement copy & paste inside the text field: it routes
    /// ⌘X/⌘C/⌘V/⌘A/⌘Z through the application's MAIN menu. `NSApp.sendEvent`
    /// offers every key-down to `mainMenu.performKeyEquivalent(with:)` before
    /// any window sees it, and a menu-bar app has no main menu unless it builds
    /// one. Without this, every text field in Kalamos — Add Correction, Add
    /// Vocabulary Word, Edit Cleanup Prompt — silently refuses paste: the field
    /// works fine, the keystroke just never reaches it.
    ///
    /// The menu is never visible. An `.accessory` app never owns the menu bar
    /// (see `main.swift`), so this exists purely as the dispatch table for the
    /// shortcuts. Each item keeps `target == nil`, which sends the action down
    /// the responder chain to whichever field editor currently has focus — so
    /// it also covers any text field added later, with no extra wiring.
    ///
    /// Selectors are written as strings on purpose: `undo:`/`redo:` are declared
    /// on no public type (NSUndoManager receives them through the chain), and
    /// `#selector(NSText.copy(_:))` is ambiguous against `NSObject.copy()`.
    private func setupEditMenu() {
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ selector: String, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        add("Undo", "undo:", "z")
        add("Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift])
        edit.addItem(.separator())
        add("Select All", "selectAll:", "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Menu bar
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .idle)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Kalamos — idle", action: nil, keyEquivalent: ""))  // status (idx 0)
        menu.addItem(.separator())

        hintItem = NSMenuItem(title: triggerHint(), action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())

        // ─── Actions (frequent — kept at the top) ─────────────────────────
        let copyLast = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLast), keyEquivalent: "c")
        menu.addItem(copyLast)
        let summarize = NSMenuItem(title: "Summarize Recent Dictations", action: #selector(summarizeRecent), keyEquivalent: "s")
        menu.addItem(summarize)
        recentMenu = NSMenu()
        addSubmenu(to: menu, title: "Recent Transcriptions", submenu: recentMenu)
        menu.addItem(.separator())

        // ─── Cleanup ▸ — AI cleanup: mode · model · prompt ────────────────
        cleanupMenu = NSMenu()
        addRadio(to: cleanupMenu, title: "Off", raw: FormatterMode.off.rawValue, action: #selector(setFormatter(_:)))
        addRadio(to: cleanupMenu, title: "Rule-based (instant)", raw: FormatterMode.ruleBased.rawValue, action: #selector(setFormatter(_:)))
        addRadio(to: cleanupMenu, title: "Local AI (downloads model)", raw: FormatterMode.localLLM.rawValue, action: #selector(setFormatter(_:)))
        cleanupMenu.addItem(.separator())
        cleanupModelMenu = NSMenu()
        for m in ModelCatalog.cleanup {
            addRadio(to: cleanupModelMenu, title: m.menuLabel, raw: m.id, action: #selector(setCleanupModelMenu(_:)))
        }
        addSubmenu(to: cleanupMenu, title: "AI Model", submenu: cleanupModelMenu)
        let editPrompt = NSMenuItem(title: "Edit Prompt…", action: #selector(editCleanupPrompt), keyEquivalent: "")
        editPrompt.target = self
        cleanupMenu.addItem(editPrompt)
        let resetPrompt = NSMenuItem(title: "Reset Prompt to Default", action: #selector(resetCleanupPrompt), keyEquivalent: "")
        resetPrompt.target = self
        cleanupMenu.addItem(resetPrompt)
        addSubmenu(to: menu, title: "Cleanup", submenu: cleanupMenu)

        // ─── Speech & Language ▸ — models · languages · custom words ──────
        speechModelMenu = NSMenu()
        for m in ModelCatalog.speech {
            addRadio(to: speechModelMenu, title: m.menuLabel, raw: m.id, action: #selector(setSpeechModelMenu(_:)))
        }
        inputLangMenu = NSMenu()   // pin the spoken language (auto-detect is unreliable on short clips)
        addRadio(to: inputLangMenu, title: "Auto-detect", raw: "auto", action: #selector(setInputLanguage(_:)))
        for lang in Language.allCases {
            addRadio(to: inputLangMenu, title: lang.displayName, raw: lang.rawValue, action: #selector(setInputLanguage(_:)))
        }
        translateMenu = NSMenu()
        addRadio(to: translateMenu, title: "Off", raw: "off", action: #selector(setTranslate(_:)))
        for lang in Language.allCases {
            addRadio(to: translateMenu, title: lang.displayName, raw: lang.rawValue, action: #selector(setTranslate(_:)))
        }
        vocabMenu = NSMenu()
        corrMenu = NSMenu()
        let speechLangMenu = NSMenu()
        addSubmenu(to: speechLangMenu, title: "Speech Model", submenu: speechModelMenu)
        addSubmenu(to: speechLangMenu, title: "Input Language", submenu: inputLangMenu)
        addSubmenu(to: speechLangMenu, title: "Translate to", submenu: translateMenu)
        speechLangMenu.addItem(.separator())
        addSubmenu(to: speechLangMenu, title: "Vocabulary", submenu: vocabMenu)
        addSubmenu(to: speechLangMenu, title: "Corrections", submenu: corrMenu)
        addSubmenu(to: menu, title: "Speech & Language", submenu: speechLangMenu)

        // ─── Dictation Trigger ▸ — the key + push-to-talk ─────────────────
        triggerMenu = NSMenu()
        for k in [UInt16(0x36), 0x3D, 0x3C, 0x3F] {   // R-Command, R-Option, R-Shift, Fn/Globe
            addRadio(to: triggerMenu, title: HotkeyManager.displayName(for: k), raw: String(k), action: #selector(setTriggerKey(_:)))
        }
        triggerMenu.addItem(.separator())
        // Three radios, not one checkbox. The setting has three states since setup
        // learned to offer them, and a tick can carry two — so "hold only" chosen in
        // setup was unrepresentable here, and toggling the box silently discarded it.
        modeMenu = NSMenu()
        for m in TriggerMode.allCases {
            addRadio(to: modeMenu, title: Self.modeTitle(m), raw: m.rawValue,
                     action: #selector(setTriggerMode(_:)))
        }
        addSubmenu(to: triggerMenu, title: "Activation", submenu: modeMenu)
        addSubmenu(to: menu, title: "Dictation Trigger", submenu: triggerMenu)

        // ─── Edit Mode ▸ — transform the selected text by voice ───────────
        editKeyMenu = NSMenu()
        editModeItem = NSMenuItem(title: "Enabled", action: #selector(toggleEditMode), keyEquivalent: "")
        editModeItem.target = self
        editKeyMenu.addItem(editModeItem)
        let editHelp = NSMenuItem(title: "Hold the key + speak an instruction to transform your selection", action: nil, keyEquivalent: "")
        editHelp.isEnabled = false
        editKeyMenu.addItem(editHelp)
        editKeyMenu.addItem(.separator())
        let editKeyLabel = NSMenuItem(title: "Activation Key", action: nil, keyEquivalent: "")
        editKeyLabel.isEnabled = false
        editKeyMenu.addItem(editKeyLabel)
        for k in [UInt16(0x3F), 0x3D, 0x3C] {   // Fn/Globe, R-Option, R-Shift
            addRadio(to: editKeyMenu, title: HotkeyManager.displayName(for: k), raw: String(k), action: #selector(setEditKey(_:)))
        }
        addSubmenu(to: menu, title: "Edit Mode", submenu: editKeyMenu)

        menu.addItem(.separator())

        // ─── Advanced ▸ — memory + login ──────────────────────────────────
        idleMenu = NSMenu()
        for (title, secs) in [("1 min", 60), ("2 min", 120), ("5 min", 300),
                              ("10 min", 600), ("15 min", 900), ("30 min", 1800),
                              ("Never (keep in memory)", 0)] {
            addRadio(to: idleMenu, title: title, raw: String(secs), action: #selector(setIdleTimeout(_:)))
        }
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        let diagnosticsItem = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        let setupItem = NSMenuItem(title: "Run Setup Again…", action: #selector(rerunOnboarding), keyEquivalent: "")
        setupItem.target = self
        let advancedMenu = NSMenu()
        addSubmenu(to: advancedMenu, title: "Unload Models After", submenu: idleMenu)
        advancedMenu.addItem(launchAtLoginItem)
        advancedMenu.addItem(diagnosticsItem)
        advancedMenu.addItem(setupItem)
        addSubmenu(to: menu, title: "Advanced", submenu: advancedMenu)

        let quit = NSMenuItem(title: "Quit Kalamos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp   // terminate: lives on NSApplication, not AppDelegate
        menu.addItem(quit)

        menu.items.forEach { if $0.action != nil && $0.target == nil { $0.target = self } }
        statusItem.menu = menu
    }

    private func addRadio(to menu: NSMenu, title: String, raw: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = raw
        menu.addItem(item)
    }

    /// Add a titled parent item that opens `submenu` (grouping helper).
    private func addSubmenu(to menu: NSMenu, title: String, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func triggerHint() -> String {
        let key = HotkeyManager.displayName(for: state.hotKeyCode)
        return state.triggerMode == .both || state.triggerMode == .hold
            ? "Hold \(key) to talk · double-tap = hands-free"
            : "Double-tap \(key) = hands-free"
    }

    // MARK: Menu refresh (checkmarks + recent)
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        hintItem.title = triggerHint()
        for item in cleanupMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == state.formatterMode.rawValue) ? .on : .off
            }
        }
        for item in translateMenu.items {
            guard let raw = item.representedObject as? String else { continue }
            let on = raw == "off" ? !state.translationEnabled
                                  : (state.translationEnabled && state.translationTarget.rawValue == raw)
            item.state = on ? .on : .off
        }
        for item in triggerMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == String(state.hotKeyCode)) ? .on : .off
            }
        }
        for item in inputLangMenu.items {
            guard let raw = item.representedObject as? String else { continue }
            let on = raw == "auto" ? state.autoDetectLanguage
                                   : (!state.autoDetectLanguage && state.defaultLanguage.rawValue == raw)
            item.state = on ? .on : .off
        }
        for item in idleMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (Int(raw) == Tuning.idleUnloadRaw) ? .on : .off
            }
        }
        for item in speechModelMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == state.whisperModel) ? .on : .off
            }
        }
        for item in cleanupModelMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == state.cleanupModelID) ? .on : .off
            }
        }
        for item in editKeyMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == String(state.editModeKeyCode)) ? .on : .off
            }
        }
        for item in modeMenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == state.triggerMode.rawValue) ? .on : .off
            }
        }
        editModeItem.state = state.editModeEnabled ? .on : .off
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        rebuildRecentMenu()
        rebuildVocabMenu()
        rebuildCorrMenu()
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let entries = history.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: "")
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
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    private func rebuildVocabMenu() {
        vocabMenu.removeAllItems()
        let add = NSMenuItem(title: "Add Word…", action: #selector(addVocabWord), keyEquivalent: "")
        add.target = self
        vocabMenu.addItem(add)
        let hint = NSMenuItem(title: "Or select a word and press ⌃⌥L", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        vocabMenu.addItem(hint)
        let terms = Vocabulary.terms
        if !terms.isEmpty {
            vocabMenu.addItem(.separator())
            for term in terms {
                let item = NSMenuItem(title: term, action: #selector(removeVocabWord(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = term
                item.toolTip = "Click to remove"
                vocabMenu.addItem(item)
            }
            vocabMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear All", action: #selector(clearVocab), keyEquivalent: "")
            clear.target = self
            vocabMenu.addItem(clear)
        }
    }

    private func rebuildCorrMenu() {
        corrMenu.removeAllItems()
        let add = NSMenuItem(title: "Add Correction…", action: #selector(addCorrection), keyEquivalent: "")
        add.target = self
        corrMenu.addItem(add)
        let hint = NSMenuItem(title: "Fix a word Kalamos keeps hearing wrong", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        corrMenu.addItem(hint)
        let rules = Corrections.rules
        if !rules.isEmpty {
            corrMenu.addItem(.separator())
            for rule in rules {
                let item = NSMenuItem(title: "\(rule.wrong)  →  \(rule.correct)",
                                      action: #selector(removeCorrection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = rule.wrong
                item.toolTip = "Click to remove"
                corrMenu.addItem(item)
            }
            corrMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear All", action: #selector(clearCorrections), keyEquivalent: "")
            clear.target = self
            corrMenu.addItem(clear)
        }
    }

    @objc private func addCorrection() {
        let alert = NSAlert()
        alert.messageText = "Add Correction"
        alert.informativeText = "When Kalamos transcribes the word on the left, it will write the one on the right instead."
        let heard = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        heard.placeholderString = "Kalamos hears… (e.g. rosi)"
        let written = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        written.placeholderString = "…write instead (e.g. Rossi)"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        container.addSubview(heard); container.addSubview(written)
        alert.accessoryView = container
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = heard
        heard.nextKeyView = written
        if alert.runModal() == .alertFirstButtonReturn {
            Corrections.add(wrong: heard.stringValue, correct: written.stringValue)
        }
    }

    @objc private func removeCorrection(_ sender: NSMenuItem) {
        if let wrong = sender.representedObject as? String { Corrections.remove(wrong: wrong) }
    }

    @objc private func clearCorrections() { Corrections.clear() }

    @objc private func addVocabWord() {
        let alert = NSAlert()
        alert.messageText = "Add Vocabulary Word"
        alert.informativeText = "A name, term, or special spelling Kalamos should always recognize."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { Vocabulary.add(field.stringValue) }
    }

    @objc private func removeVocabWord(_ sender: NSMenuItem) {
        if let term = sender.representedObject as? String { Vocabulary.remove(term) }
    }

    @objc private func clearVocab() { Vocabulary.clear() }

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

    // MARK: Actions
    @objc private func setFormatter(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = FormatterMode(rawValue: raw) {
            state.formatterMode = mode
        }
    }

    @objc private func setTranslate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "off" {
            state.translationEnabled = false
        } else if let lang = Language(rawValue: raw) {
            state.translationTarget = lang
            state.translationEnabled = true
        }
    }

    @objc private func setInputLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "auto" {
            state.autoDetectLanguage = true
        } else if let lang = Language(rawValue: raw) {
            state.autoDetectLanguage = false
            state.defaultLanguage = lang
        }
    }

    @objc private func setIdleTimeout(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let secs = Int(raw) {
            Tuning.setIdleUnload(secs)
        }
    }

    @objc private func setTriggerKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let code = UInt16(raw) else { return }
        applyTriggerKey(code)
    }

    /// Changing the trigger is not a matter of writing a number down: the global
    /// event tap must be torn down and re-registered on the new key. Shared by the
    /// menu and by first-run setup, so the two cannot drift apart.
    func applyTriggerKey(_ code: UInt16) {
        state.hotKeyCode = code
        hotkey.stop()
        hotkey.updateKeyCode(code)
        if Permissions.accessibilityTrusted(prompt: false) { _ = hotkey.start() }
        hintItem.title = triggerHint()
        startEditHotkeyIfNeeded()   // re-evaluate the edit-key ≠ trigger-key guard
    }

    /// Show first-run setup: at launch for a fresh install, on demand from the menu.
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

    @objc private func rerunOnboarding() { showOnboarding() }

    @objc private func setSpeechModelMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != state.whisperModel else { return }
        state.whisperModel = id
        controller.setSpeechModel(id)
    }

    @objc private func setCleanupModelMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != state.cleanupModelID else { return }
        state.cleanupModelID = id
        controller.setCleanupModel(id)
    }

    @objc private func editCleanupPrompt() {
        let alert = NSAlert()
        alert.messageText = "Edit Cleanup Prompt"
        alert.informativeText = "ADVANCED. Leave this EMPTY to use Kalamos's built-in cleanup prompt (recommended — it's tuned for punctuation and fidelity). Type here ONLY to fully replace it with your own instructions."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = true
        text.isRichText = false
        text.font = .userFixedPitchFont(ofSize: 12)
        text.string = state.cleanupPromptOverride ?? ""
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = text
        if alert.runModal() == .alertFirstButtonReturn {
            let v = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            state.cleanupPromptOverride = v.isEmpty ? nil : v
        }
    }

    @objc private func resetCleanupPrompt() {
        state.cleanupPromptOverride = nil
        NSSound(named: "Glass")?.play()
    }

    @objc private func setTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TriggerMode(rawValue: raw) else { return }
        applyTriggerMode(mode)
    }

    static func modeTitle(_ mode: TriggerMode) -> String {
        switch mode {
        case .hold:      return "Hold to talk"
        case .doubleTap: return "Double-tap (hands-free)"
        case .both:      return "Both"
        }
    }

    /// The live recogniser has to be told, or the setting only takes effect on the
    /// next launch. Shared with setup, same reason as the trigger key.
    func applyTriggerMode(_ mode: TriggerMode) {
        state.triggerMode = mode
        hotkey.setMode(mode)
        hintItem.title = triggerHint()
    }

    @objc private func toggleEditMode() {
        state.editModeEnabled.toggle()
        startEditHotkeyIfNeeded()
    }

    @objc private func setEditKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let code = UInt16(raw) else { return }
        state.editModeKeyCode = code
        startEditHotkeyIfNeeded()
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
        state.status = .loadingModel("Summarizing…")
        Task {
            do {
                let summary = try await Summarizer().summarize(Array(texts), language: language)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
                state.status = .idle
                self.showSummary(summary)
            } catch {
                state.status = .error("Summary failed")
            }
        }
        #else
        NSSound.beep()
        #endif
    }

    private func showSummary(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Summary (copied to clipboard)"
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
            ? "Kalamos is healthy"
            : "\(failures) problem\(failures == 1 ? "" : "s") found"
        alert.alertStyle = failures == 0 ? .informational : .warning
        alert.accessoryView = scroll
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")   // so it can be pasted into a bug report
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            state.status = .error("Login item failed: \(error.localizedDescription)")
        }
    }

    // MARK: Status icon
    private func observeStatus() {
        state.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                MainActor.assumeIsolated { self?.updateIcon(for: s) }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for status: DictationStatus) {
        let symbol: String, label: String
        switch status {
        case .idle:               symbol = "mic"; label = "Kalamos — idle"
        case .listening:          symbol = "mic.fill"; label = "Kalamos — listening…"
        case .transcribing:       symbol = "waveform"; label = "Kalamos — working…"
        case .loadingModel(let m):symbol = "arrow.down.circle"; label = "Kalamos — \(m)"
        case .error(let m):       symbol = "exclamationmark.triangle"; label = "Kalamos — \(m)"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        statusItem.menu?.items.first?.title = label
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
        state.status = .error("Grant Accessibility — Kalamos starts automatically")
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
            state.status = .error("Couldn't install hot key (Accessibility?)")
        }
    }
}
