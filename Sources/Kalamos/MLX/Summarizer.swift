import Foundation

#if canImport(MLXLLM)

/// Summarizes dictated notes on-device via the local LLM (shares the same
/// resident model as the formatter/translator).
struct Summarizer {
    let engine: MLXEngine
    init(engine: MLXEngine = .shared) { self.engine = engine }

    /// Summarize a set of dictation texts (chronological order) into `language`.
    func summarize(_ texts: [String], language: Language) async throws -> String {
        let joined = texts.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let system = """
        You summarize a person's dictated notes. Write a clear, concise summary \
        in \(language.displayName): capture the key points as short bullet points, \
        and if there are any tasks or decisions, list them under "Action items". \
        Be faithful to the content; do not invent anything. Output only the summary.
        """
        return try await engine.generate(
            system: system, user: joined, maxTokens: 700, temperature: 0.3)
    }
}
#endif
