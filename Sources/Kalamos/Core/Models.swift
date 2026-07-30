import Foundation

/// One selectable model in the menu: a human title, the underlying engine id,
/// and a short size/behaviour hint shown after the title.
struct ModelChoice: Sendable, Equatable {
    let title: String   // menu label
    let id: String      // WhisperKit variant name OR MLX repo id
    let note: String    // size / speed hint

    var menuLabel: String { note.isEmpty ? title : "\(title) — \(note)" }
}

/// Catalogs of the models Kalamos offers in its menus. The model picker is table
/// stakes (superwhisper/MacWhisper have it) — Kalamos's moat is 100%-local cleanup
/// — but it is also how you reach a bigger model when the default isn't enough.
/// Defaults are unchanged from before the picker existed → zero regression.
enum ModelCatalog {
    /// Speech-to-text (WhisperKit variants). All run on-device (CoreML/ANE).
    static let speech: [ModelChoice] = [
        .init(title: "Turbo",    id: "openai_whisper-large-v3-v20240930_turbo", note: "balanced · default"),
        .init(title: "Large v3", id: "openai_whisper-large-v3",                 note: "most accurate · slower"),
        .init(title: "Small",    id: "openai_whisper-small",                    note: "fast · lighter"),
        .init(title: "Base",     id: "openai_whisper-base",                     note: "fastest · least accurate"),
    ]

    /// On-device cleanup / translation LLM (MLX 4-bit instruct models).
    static let cleanup: [ModelChoice] = [
        .init(title: "Qwen2.5 7B",  id: "mlx-community/Qwen2.5-7B-Instruct-4bit",  note: "~4.3 GB · default"),
        .init(title: "Qwen2.5 14B", id: "mlx-community/Qwen2.5-14B-Instruct-4bit", note: "~8 GB · most accurate"),
        .init(title: "Qwen2.5 3B",  id: "mlx-community/Qwen2.5-3B-Instruct-4bit",  note: "~1.8 GB · fast · light"),
    ]

    /// Title for an id even if it isn't in the catalog (defensive menu labels).
    static func speechTitle(for id: String) -> String {
        speech.first { $0.id == id }?.title ?? id
    }
    static func cleanupTitle(for id: String) -> String {
        cleanup.first { $0.id == id }?.title ?? id
    }
}
