import Foundation

#if canImport(MLXLLM)

/// Instant on-device translation among IT/EN/FR via the local LLM. Whisper's own
/// translate task only outputs English, so arbitrary direction translation runs
/// through the instruct model.
struct MLXTranslator: Translator {
    let engine: MLXEngine

    init(engine: MLXEngine = .shared) { self.engine = engine }

    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, from != to else { return trimmed }

        let keepLine = Vocabulary.list.map {
            " Keep these names/terms unchanged: \($0)."
        } ?? ""
        let system = """
        You are an expert \(to.displayName) translator and native speaker. \
        Translate the user's \(from.displayName) text into natural, idiomatic, \
        conversational \(to.displayName) — phrase it the way a native speaker \
        would actually say it, conveying meaning and tone, NOT word-for-word. \
        Prefer common everyday wording over literal equivalents (e.g. for \
        Italian "in realtà" use "actually", not "in reality"). Keep it concise \
        and preserve the register (casual stays casual).\(keepLine) Output ONLY the \
        translation: no preamble, no quotes, no notes, no alternatives.
        """
        let out = try await engine.generate(
            system: system, user: trimmed, purpose: .translating,
            maxTokens: max(128, trimmed.count * 2), temperature: 0.3)
        return out.isEmpty ? trimmed : out
    }
}
#endif
