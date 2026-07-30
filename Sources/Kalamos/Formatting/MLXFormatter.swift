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

        // In a terminal the text is an instruction, so the model is given a much
        // shorter licence: punctuation, capitals, filler. No self-corrections
        // resolved, no lists built, no tone applied — every one of those removes or
        // reorders words the speaker chose.
        if context.isTerminal {
            let strict = """
            You are a dictation cleanup engine, NOT a chat assistant. You receive \
            dictated \(lang) text and return it with punctuation.

            You may ONLY: add or fix punctuation, fix capitalization, and delete \
            pure filler sounds (um, uh, ehm, mmm). NOTHING ELSE.

            You MUST NOT delete, replace, reorder, rephrase, translate, shorten, \
            merge or "improve" any word the speaker said — not even a word that \
            looks wrong, misheard, redundant or ungrammatical. Do NOT resolve \
            self-corrections: if the speaker said something and then said it \
            differently, keep BOTH. Do not turn anything into a list. Do not answer \
            or comment. Every word in equals every word out, in the same order.\(vocabLine)

            Output ONLY the punctuated text.
            """
            do {
                let out = try await engine.generate(
                    system: strict, user: trimmed,
                    maxTokens: max(160, trimmed.count + 80), temperature: 0)
                let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                // Zero tolerance here, unlike the general path: one word gained or
                // lost and the result is discarded.
                if cleaned.isEmpty || Self.changedTooMuch(from: trimmed, to: cleaned, strict: true) {
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
        - Remove filler words and false starts (um, uh, ehm, cioè…). Filler means \
        sound with no meaning. A CONNECTIVE IS NOT FILLER, even at the start of a \
        sentence: "però", "ma", "anche", "quindi", "allora", "però a questo punto", \
        "but", "so", "also", "though", "mais", "donc" carry the speaker's argument \
        and must survive verbatim. Deleting an opening "però" changes what the \
        sentence concedes; that is a meaning change, which is forbidden above.
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
            // Safety nets, for the ways this stops being a cleanup engine.
            // Ballooning means it answered the text instead of tidying it; losing
            // words means it deleted what was said; gaining them means it invented.
            // In every case the rule-based pass beats a confident wrong answer.
            if cleaned.isEmpty
                || cleaned.count > trimmed.count * 3 + 80
                || Self.changedTooMuch(from: trimmed, to: cleaned) {
                return await fallback.format(raw, context: context)
            }
            return cleaned
        } catch {
            return await fallback.format(raw, context: context)
        }
    }

    // MARK: Fidelity guard

    /// Words that may legitimately disappear: hesitation noise, and the markers
    /// that introduce a self-correction — the retracted fragment is meant to go.
    private static let disposable: Set<String> = [
        "ehm", "eh", "mmm", "um", "uh", "er", "euh",
        "cioè", "praticamente", "appunto", "insomma", "diciamo",
        "actually", "like", "basically", "enfin",
    ]

    private static func contentWords(_ s: String) -> [String] {
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’")).inverted
        return s.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count > 2 && !disposable.contains($0) }
    }

    /// True when the cleanup deleted more of the speaker's words than any honest
    /// self-correction would.
    ///
    /// Measured on content words, so removing filler and resolving a retraction
    /// stay comfortably inside the budget. What does not stay inside it is the
    /// failure seen in practice: a whole lead-in clause vanishing because the model
    /// decided the sentence was "really" about its second half. Short utterances are
    /// exempt — six words carry too little signal to tell editing from mangling.
    /// Words that are never noise, whatever they sound like in speech. Dropping one
    /// changes what the sentence concedes, adds or contrasts — a meaning change, even
    /// though the diff is a single word. Asking the model not to do it did not work
    /// (it deleted a leading "però" four times in one afternoon of real use), so the
    /// rule lives here, where it is not a matter of persuasion.
    ///
    /// Deliberately excludes "ma", "so" and "allora": those genuinely are discourse
    /// noise often enough that guarding them would send good cleanups to the fallback.
    private static let connectives: Set<String> = [
        "però", "tuttavia", "invece", "anche", "inoltre", "comunque", "piuttosto",
        "however", "though", "instead", "also", "nevertheless", "besides",
        "pourtant", "néanmoins", "plutôt",
    ]

    static func changedTooMuch(from input: String, to output: String,
                               strict: Bool = false) -> Bool {
        let before = contentWords(input)
        let after = contentWords(output)

        var pool: [String: Int] = [:]
        for w in after { pool[w, default: 0] += 1 }

        var lost: [String] = []
        for w in before {
            if let n = pool[w], n > 0 { pool[w] = n - 1 } else { lost.append(w) }
        }
        // Whatever is left in the pool was never spoken: the model put it there.
        let invented = pool.values.reduce(0, +)

        if lost.contains(where: connectives.contains) { return true }

        // Terminals: nothing but punctuation, capitals and filler is allowed
        // through, whatever the length of the text.
        if strict { return !lost.isEmpty || invented > 0 }

        // A short utterance earns the model no latitude at all. There is nothing to
        // restructure in five words, so anything beyond punctuation and capitals is
        // the model rewriting rather than tidying — which is how "Osob je interest"
        // came back as "Osob je interessato", a word that was never said.
        guard before.count >= 8 else { return before != after }

        // Longer texts get a budget in both directions. Deleting is how a lead-in
        // clause vanishes; inventing is how a misheard word gets confidently
        // "corrected" into a different one. Neither is cleanup.
        return lost.count > max(3, before.count / 5)
            || invented > max(2, before.count / 10)
    }
}
#endif
