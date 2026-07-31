import Foundation

#if canImport(MLXLLM)

/// Summarizes a dictated note on-device via the local LLM (shares the same
/// resident model as the formatter/translator).
struct Summarizer {
    let engine: MLXEngine
    init(engine: MLXEngine = .shared) { self.engine = engine }

    /// Summarize one dictation into `language`.
    ///
    /// One, deliberately. This took a list until 2026-07-31, and was called with
    /// the last twenty entries — unrelated texts summarized as though they were
    /// one train of thought.
    func summarize(_ text: String, language: Language) async throws -> String {
        let system = """
        You summarize a note a person dictated. Write a clear, concise summary \
        in \(language.displayName): capture the key points as short bullet points, \
        and if there are any tasks or decisions, list them under a heading meaning \
        "Action items", written in \(language.displayName). Be faithful to the \
        content; do not invent anything. Output only the summary.
        """
        return try await engine.generate(
            system: system, user: text, purpose: .summarizing, maxTokens: 700, temperature: 0.3)
    }
}
#endif
