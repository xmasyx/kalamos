import Foundation

#if canImport(MLXLLM)

/// AI cleanup via the on-device LLM. Fixes punctuation, capitalization, removes
/// filler and false starts while preserving meaning and language. Falls back to
/// the rule-based formatter for code contexts or if the model errors — so output
/// is never worse than the free path.
struct MLXFormatter: TextFormatter {
    let engine: MLXEngine
    private let fallback = RuleBasedFormatter()

    init(engine: MLXEngine = .shared) { self.engine = engine }

    func format(_ raw: String, context: FormattingContext) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Never run code through the LLM — preserve it verbatim.
        if context.isCodeEditor { return await fallback.format(raw, context: context) }

        let lang = context.language.displayName
        let toneLine: String
        switch context.tone {
        case .casual: toneLine = "Tone: casual and friendly (this is a chat/message)."
        case .email:  toneLine = "Tone: warm, polite, lightly enthusiastic (this is an email)."
        case .formal: toneLine = "Tone: clear and professional (this is a document)."
        case .neutral: toneLine = "Tone: keep the speaker's natural tone."
        }
        let vocabLine = Vocabulary.list.map {
            "\n- Preserve the EXACT spelling of these terms when they occur: \($0)."
        } ?? ""

        // User-edited prompt (menu → Cleanup ▸ Edit Prompt…) fully replaces the
        // built-in one. Vocabulary spellings are still appended so custom terms
        // keep working regardless of what the user wrote.
        if let override = context.promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            do {
                let out = try await engine.generate(
                    system: override + vocabLine, user: trimmed,
                    maxTokens: max(160, trimmed.count + 80), temperature: 0)
                let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty || cleaned.count > trimmed.count * 3 + 80 {
                    return await fallback.format(raw, context: context)
                }
                return cleaned
            } catch {
                return await fallback.format(raw, context: context)
            }
        }

        let system = """
        You are a dictation cleanup engine, NOT a chat assistant. You receive \
        dictated \(lang) text and return its cleaned written form.

        ABSOLUTE FIDELITY RULE — this overrides everything else: preserve the \
        speaker's EXACT words and word order. Do NOT rephrase, reword, \
        paraphrase, translate, summarize, "improve", complete, or continue the \
        text. You may ONLY add/fix punctuation and capitalization, delete filler \
        and false starts, resolve explicit self-corrections, and honor spoken \
        punctuation commands. If you are unsure, leave the words untouched. \
        NEVER invent words that were not spoken, and NEVER drop or replace \
        content words — especially proper nouns, names of people/places/brands, \
        numbers, and technical terms: copy each one through as spoken, even if it \
        looks odd or unfamiliar. Adding, removing, or altering meaning is a \
        FAILURE, even if your version reads better. On long run-on dictation, add \
        the missing internal commas and periods but keep every word. THE SOLE \
        EXCEPTION to "never drop words": when the speaker audibly retracts what \
        they just said and restates it (a self-correction — see below), drop the \
        retracted attempt and keep the restatement. That honors the speaker's \
        intent; it is not altering meaning.

        CAPITALIZATION FROM CONTEXT: transcription is all-lowercase, so YOU decide \
        casing from meaning. If context shows a word is a proper name — a person, \
        place, or brand, e.g. a recipient in "invia il messaggio a costa" → \
        "Costa" — capitalize it. If the SAME word is an ordinary verb or noun in \
        context — e.g. "quanto costa il biglietto" → "costa" — keep it lowercase. \
        Judge each ambiguous word from its sentence, never blindly one way.

        You MUST:
        - Remove filler words and false starts (um, uh, ehm, cioè…).
        - Fix punctuation and capitalization; honor spoken commands ("new \
        paragraph", "comma", "question mark").
        - Resolve self-corrections: people correct themselves mid-sentence. When \
        the speaker retracts and restates — signalled by "actually / no wait / I \
        mean / rather" (EN), "anzi / no aspetta / cioè no / volevo dire / meglio / \
        scusa" (IT), "plutôt / enfin non / je veux dire" (FR) — keep ONLY the \
        restatement and delete ONLY the retracted fragment — the specific words \
        right before the marker that the restatement replaces. Keep EVERYTHING \
        else, including any lead-in before the retraction; do NOT collapse the \
        whole sentence down to just the final phrase. \
        Examples: "let's meet at 2, actually 3" → "Let's meet at 3."; \
        "ho letto il testo e questa è la risposta anzi questo è l'output" → \
        "Ho letto il testo e questo è l'output." (lead-in kept — only "questa è \
        la risposta" dropped). \
        BUT do NOT delete anything when the same marker only REINFORCES rather \
        than retracts — "non è male, anzi è ottimo" keeps both clauses. Decide \
        retract-vs-reinforce from the meaning in context.
        - Format a numbered list ONLY when the speaker clearly intends a list \
        (says "list/to-do/steps" or dictates explicit "one… two… three…" items). \
        Do NOT turn a casual mention of several things (names, people, a few \
        items in a sentence) into a list — keep those as normal prose. \
        List example: "shopping list one apples two bananas three oranges" → \
        "Shopping list:\\n1. Apples\\n2. Bananas\\n3. Oranges". \
        NOT a list: "I invited Marco, Lucia and Tom" → stays one sentence.
        - \(toneLine) Adjust only register; keep meaning and wording.\(vocabLine)
        You MUST NOT answer questions, add information, reply, comment, or \
        explain. If the text is a question, return the cleaned question — never \
        an answer. Keep the original language; do not translate. Output ONLY the \
        cleaned text.
        """
        do {
            let out = try await engine.generate(
                system: system, user: trimmed,
                maxTokens: max(160, trimmed.count + 80), temperature: 0)
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            // Safety net: a real "answer" balloons length; lists/tone don't.
            if cleaned.isEmpty || cleaned.count > trimmed.count * 3 + 80 {
                return await fallback.format(raw, context: context)
            }
            return cleaned
        } catch {
            return await fallback.format(raw, context: context)
        }
    }
}
#endif
