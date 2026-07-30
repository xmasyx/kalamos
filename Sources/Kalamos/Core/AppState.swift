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
}

/// What the dictation pipeline is currently doing — drives the menu-bar icon.
enum DictationStatus: Equatable {
    case idle
    case listening
    case transcribing
    case loadingModel(String)   // one-time model download / load progress
    case error(String)
}

/// Single source of truth for user configuration + live status.
/// Persisted to UserDefaults; observed by the UI. Main-actor isolated.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Live status (not persisted)
    @Published var status: DictationStatus = .idle

    // MARK: Configuration (persisted)
    @Published var hotKeyCode: UInt16 { didSet { persist("hotKeyCode", Int(hotKeyCode)) } }
    @Published var formatterMode: FormatterMode { didSet { persist("formatterMode", formatterMode.rawValue) } }
    @Published var enabledLanguages: Set<Language> { didSet { persistLanguages() } }
    @Published var autoDetectLanguage: Bool { didSet { persist("autoDetectLanguage", autoDetectLanguage) } }
    @Published var defaultLanguage: Language { didSet { persist("defaultLanguage", defaultLanguage.rawValue) } }

    // Translation (Phase 2 / MLX)
    @Published var translationEnabled: Bool { didSet { persist("translationEnabled", translationEnabled) } }
    @Published var translationTarget: Language { didSet { persist("translationTarget", translationTarget.rawValue) } }

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
    @Published var pushToTalkEnabled: Bool { didSet { persist("pushToTalkEnabled", pushToTalkEnabled) } }

    // Edit Mode: transform the SELECTED text via a spoken instruction instead of
    // inserting new text. Off by default. Activated by holding its own dedicated
    // modifier key (distinct from the dictation trigger) — never auto-inferred
    // from "is something selected", which is ambiguous with dictation-replaces.
    @Published var editModeEnabled: Bool { didSet { persist("editModeEnabled", editModeEnabled) } }
    @Published var editModeKeyCode: UInt16 { didSet { persist("editModeKeyCode", Int(editModeKeyCode)) } }

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
        whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-large-v3-v20240930_turbo"
        cleanupModelID = defaults.string(forKey: "cleanupModelID") ?? "mlx-community/Qwen2.5-7B-Instruct-4bit"
        cleanupPromptOverride = defaults.string(forKey: "cleanupPromptOverride")
        pushToTalkEnabled = (defaults.object(forKey: "pushToTalkEnabled") as? Bool) ?? true
        editModeEnabled = (defaults.object(forKey: "editModeEnabled") as? Bool) ?? false
        // 0x3F == Fn / Globe — default Edit-Mode modifier. Distinct from the
        // dictation trigger (Right Command), and NOT used to type text, so it
        // won't conflict with capital letters the way Shift would. Held during
        // dictation → transform the selection instead of inserting.
        let savedEditKey = defaults.object(forKey: "editModeKeyCode") as? Int
        editModeKeyCode = UInt16(savedEditKey ?? 0x3F)

        if let raw = defaults.array(forKey: "enabledLanguages") as? [String] {
            enabledLanguages = Set(raw.compactMap(Language.init(rawValue:)))
        } else {
            enabledLanguages = [.italian, .english, .french]
        }
        if enabledLanguages.isEmpty { enabledLanguages = [.english] }
    }

    private func persist(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    private func persistLanguages() {
        defaults.set(enabledLanguages.map(\.rawValue), forKey: "enabledLanguages")
    }
}
