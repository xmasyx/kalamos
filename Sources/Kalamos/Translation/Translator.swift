import Foundation

/// On-device translation among the v1 languages. Backed by the MLX local LLM
/// (Phase 2) — Whisper's own translate task only outputs English, so arbitrary
/// IT↔EN↔FR must go through the LLM.
protocol Translator: Sendable {
    func translate(_ text: String, from: Language, to: Language) async throws -> String
}

/// Default no-op used until the MLX model is wired (Phase 2). Returns input
/// unchanged so the pipeline runs without translation.
struct NoOpTranslator: Translator {
    func translate(_ text: String, from: Language, to: Language) async throws -> String { text }
}
