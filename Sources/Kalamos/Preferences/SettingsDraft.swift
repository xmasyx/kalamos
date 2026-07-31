import Foundation

/// Every setting the window can change, held as one value.
///
/// The window used to write each setting the moment you clicked it. That is the
/// macOS System Settings idea, and it is fine until you want to change three
/// things at once — the trigger key re-registers a global event tap, the models
/// unload and reload, and a half-made decision is applied to a live app while you
/// are still deciding.
///
/// So the window edits a draft, exactly as Otium's preferences do, and **Applica**
/// hands it over. `!=` is the whole dirty-tracking mechanism: `Equatable` on a
/// struct compares every field, so a field added later cannot be forgotten here.
///
/// What is NOT in here: the vocabulary and the correction rules. Those are not
/// settings, they are entries — adding a word is the action, not a decision
/// pending confirmation, and a delete you have to confirm twice is a delete
/// nobody trusts.
struct SettingsDraft: Equatable {
    var uiLanguage: Language
    var hotKeyCode: UInt16
    var spaceBetweenDictations: Bool
    var smartCapitalization: Bool
    var lowercaseFirstLetter: Bool
    var removeTrailingPeriod: Bool
    var insertionMode: TextInsertionMode
    var notifyCleanupRejected: Bool
    var triggerMode: TriggerMode
    var autoDetectLanguage: Bool
    var defaultLanguage: Language
    var translationEnabled: Bool
    var translationTarget: Language
    var whisperModel: String
    var formatterMode: FormatterMode
    var cleanupModelID: String
    /// Empty means "use Kalamos's own instructions" — `nil` and `""` would be two
    /// spellings of one state, and the draft would look dirty for neither reason.
    var cleanupPrompt: String
    var idleSeconds: Int
    var editModeEnabled: Bool
    var editModeKeyCode: UInt16
    var launchAtLogin: Bool

    @MainActor
    init(state: AppState, launchAtLogin: Bool) {
        uiLanguage = state.uiLanguage
        hotKeyCode = state.hotKeyCode
        spaceBetweenDictations = state.spaceBetweenDictations
        smartCapitalization = state.smartCapitalization
        lowercaseFirstLetter = state.lowercaseFirstLetter
        removeTrailingPeriod = state.removeTrailingPeriod
        insertionMode = state.insertionMode
        notifyCleanupRejected = state.notifyCleanupRejected
        triggerMode = state.triggerMode
        autoDetectLanguage = state.autoDetectLanguage
        defaultLanguage = state.defaultLanguage
        translationEnabled = state.translationEnabled
        translationTarget = state.translationTarget
        whisperModel = state.whisperModel
        formatterMode = state.formatterMode
        cleanupModelID = state.cleanupModelID
        cleanupPrompt = state.cleanupPromptOverride ?? ""
        idleSeconds = Tuning.idleUnloadRaw
        editModeEnabled = state.editModeEnabled
        editModeKeyCode = state.editModeKeyCode
        self.launchAtLogin = launchAtLogin
    }

    /// How many settings differ — the number the window puts next to **Applica**,
    /// so "unapplied changes" is a fact you can check rather than a warning light.
    func changeCount(from other: SettingsDraft) -> Int {
        var n = 0
        if uiLanguage != other.uiLanguage { n += 1 }
        if hotKeyCode != other.hotKeyCode { n += 1 }
        if spaceBetweenDictations != other.spaceBetweenDictations { n += 1 }
        if smartCapitalization != other.smartCapitalization { n += 1 }
        if lowercaseFirstLetter != other.lowercaseFirstLetter { n += 1 }
        if removeTrailingPeriod != other.removeTrailingPeriod { n += 1 }
        if insertionMode != other.insertionMode { n += 1 }
        if notifyCleanupRejected != other.notifyCleanupRejected { n += 1 }
        if triggerMode != other.triggerMode { n += 1 }
        if autoDetectLanguage != other.autoDetectLanguage || defaultLanguage != other.defaultLanguage { n += 1 }
        if translationEnabled != other.translationEnabled || translationTarget != other.translationTarget { n += 1 }
        if whisperModel != other.whisperModel { n += 1 }
        if formatterMode != other.formatterMode { n += 1 }
        if cleanupModelID != other.cleanupModelID { n += 1 }
        if cleanupPrompt != other.cleanupPrompt { n += 1 }
        if idleSeconds != other.idleSeconds { n += 1 }
        if editModeEnabled != other.editModeEnabled || editModeKeyCode != other.editModeKeyCode { n += 1 }
        if launchAtLogin != other.launchAtLogin { n += 1 }
        return n
    }
}
