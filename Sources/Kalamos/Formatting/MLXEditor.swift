import Foundation

#if canImport(MLXLLM)

/// Edit Mode transformer: applies a spoken INSTRUCTION to a SELECTED piece of
/// text, entirely on-device via the shared MLX model. This is Kalamos's take on
/// freeflow's "edit" feature, but 100% local (freeflow round-trips to Groq's
/// cloud). Feature #1 stolen and made private.
///
/// The result replaces the live selection (the caller injects it with ⌘V while
/// the text is still highlighted).
struct MLXEditor {
    let engine: MLXEngine

    init(engine: MLXEngine = .shared) { self.engine = engine }

    func transform(instruction: String, selection: String, language: Language) async -> String {
        let lang = language.displayName
        let system = """
        You are a text editor, NOT a chat assistant. You are given a SELECTED \
        TEXT and a spoken INSTRUCTION describing how to change it. Apply the \
        instruction and return ONLY the resulting text — no preamble, no quotes, \
        no explanation, no commentary. Keep the output in \(lang) unless the \
        instruction explicitly asks to translate. Change only what the \
        instruction asks; preserve everything else. If the instruction is \
        unclear, return the selected text unchanged.
        """
        let user = "INSTRUCTION: \(instruction)\n\nSELECTED TEXT:\n\(selection)"
        do {
            let out = try await engine.generate(
                system: system, user: user,
                maxTokens: max(200, selection.count + 160), temperature: 0.2)
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? selection : cleaned
        } catch {
            return selection   // never destroy the selection on error
        }
    }
}
#endif
