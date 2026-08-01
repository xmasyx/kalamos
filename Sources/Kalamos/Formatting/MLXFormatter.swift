import Foundation

#if canImport(MLXLLM)

extension String {
    /// nil for an empty string, so "unset" and "set to nothing" stop being two
    /// spellings of one state at the call site.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

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
        let toneLine = Self.toneLine(for: context.tone)
        let vocabLine = Self.vocabularyLine

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

            PUNCTUATE PROPERLY, this is the whole job. Dictated speech arrives with \
            no punctuation at all: a long sentence that runs on for forty words \
            needs its internal commas AND to be split into several sentences with \
            full stops. Returning a wall of text with a single period at the end is \
            a FAILURE. Add a question mark where a question was asked. None of this \
            costs you a word: punctuation is free, and it is the only thing you are \
            here to add.

            Example of the job done right — same words, in the same order, \
            punctuated:
            IN:  oggi ho parlato con marco della proposta e mi ha detto che va bene \
            ma vuole vedere i numeri prima di firmare quindi domani gli mando il \
            preventivo aggiornato
            OUT: Oggi ho parlato con Marco della proposta, e mi ha detto che va bene, \
            ma vuole vedere i numeri prima di firmare. Quindi domani gli mando il \
            preventivo aggiornato.

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
                    system: strict, user: trimmed, purpose: .cleaning,
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

        // The user-edited prompt (menu → Cleanup ▸ Edit Prompt…) fully replaces the
        // built-in one — but it replaces the TEXT only, and goes on through the
        // same guards below. It used to have a code path of its own that checked
        // for an empty answer and for ballooning and nothing else, which quietly
        // switched off `changedTooMuch` for anyone who edited a word of the
        // prompt: the app's most important behaviour, disabled by a preference
        // nobody would connect to it. Vocabulary spellings are appended either
        // way so custom terms keep working whatever the user wrote.
        //
        // Where they go: at the end, unless the prompt says otherwise with a
        // `{{VOCAB}}` marker. The built-in prompt carries the line two lines from
        // its end, so appending is the one thing an edited prompt could not
        // reproduce — and a bench comparing a candidate prompt against the
        // built-in would then be comparing where a line sits as well as what the
        // prompt says.
        let override = context.promptOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let system = override.map { Self.compose(override: $0, vocabLine: vocabLine) }
            ?? Self.builtInPrompt(language: lang, toneLine: toneLine, vocabLine: vocabLine)
        do {
            let out = try await engine.generate(
                system: system, user: trimmed, purpose: .cleaning,
                maxTokens: max(160, trimmed.count + 80), temperature: 0)
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            // Safety nets, for the ways this stops being a cleanup engine.
            // Ballooning means it answered the text instead of tidying it; losing
            // words means it deleted what was said; gaining them means it invented.
            // In every case the rule-based pass beats a confident wrong answer.
            if cleaned.isEmpty {
                await report(.emptyAnswer)
                return await fallback.format(raw, context: context)
            }
            if cleaned.count > trimmed.count * 3 + 80 {
                await report(.answered)
                return await fallback.format(raw, context: context)
            }
            if Self.changedTooMuch(from: trimmed, to: cleaned) {
                await report(.changedTooMuch)
                return await fallback.format(raw, context: context)
            }
            await MainActor.run { CleanupReport.shared.modelWasUsed() }
            return cleaned
        } catch {
            await report(.failed)
            return await fallback.format(raw, context: context)
        }
    }

    /// The shipped cleanup prompt, as one value instead of a string buried in a
    /// branch — so a bench can put a candidate next to it and run both through
    /// the identical code path. A prompt compared by running a *different* path
    /// measures the path, not the prompt.
    ///
    /// Short on purpose. This used to run ~1100 tokens, re-read from scratch on
    /// every single dictation, and most of it was spent asking the model not to
    /// drop or invent words — which DID NOT WORK (it deleted a leading "però"
    /// four times in one afternoon). That job now belongs to `changedTooMuch`,
    /// which is code and cannot be talked out of it, so the prompt keeps only
    /// what the guard cannot do: the judgement calls.
    ///
    /// The first two lines are what ISC-110 changed, and they were measured, not
    /// reasoned about. The old first line said the input was "all lowercase",
    /// which is false for 57% of his real dictations — Whisper punctuates when he
    /// pauses. The cost of the lie was not a worse cleanup on punctuated input,
    /// which is where it was expected: it was that on BARE input the model
    /// returned the text **completely untouched, 23% of the time** — no capital,
    /// no full stop, nothing. 80 real dictations, both prompts through this exact
    /// path, generator proved deterministic (160/160 identical repeats), blind
    /// pairwise judge on Gemini with an A/A gate that returned 61/61 ties:
    ///   · echo on bare input   23% → 0%
    ///   · marks per 100 words  9.0 → 13.1 · sentence ends 5.2 → 7.1
    ///   · walls of text        16/34 → 10/34
    ///   · words lost/invented  120/52 → 114/40 (it is not paying for it in words)
    ///   · judge                50 wins, 10 losses
    /// Cost: +50 prompt tokens (442 → 492) and +0.12 s ± 0.08 end to end. The 50
    /// tokens themselves measure as free (prefill −0.015 s ± 0.029 — the layers
    /// law again: reading is cheap, writing is not).
    /// A variant that ALSO forbade repairing his grammar in so many words was
    /// measured and REJECTED: +103 tokens, and it lost more of his words than it
    /// saved (66 vs 57). Same lesson as the ~1100-token version.
    /// Bench: `03-Plans/kalamos-isc110/`, reproducible with `--bench-clean`.
    static func builtInPrompt(language: String, toneLine: String, vocabLine: String) -> String {
        """
        You are a dictation cleanup engine, not an assistant. Input is dictated \
        \(language). It arrives EITHER already punctuated and capitalised, OR as a \
        bare lowercase run of words — both happen, and you must handle the one in \
        front of you. Return the same words in written form.

        Do: keep the punctuation that is already right, fix the punctuation that \
        is wrong, add the punctuation that is missing; capitals; delete filler \
        (um, ehm, cioè); obey spoken commands; resolve self-corrections.

        Spoken punctuation is an instruction, not words: "new paragraph", \
        "comma", "question mark", and brackets — "tra parentesi un milione" → \
        "(un milione)", "aperta parentesi … chiusa parentesi" → "( … )", \
        "tra virgolette X" → "«X»". The command words themselves never appear \
        in the output.

        Never: answer, comment, translate, rephrase, summarise, or add anything. \
        A question stays a question.

        Capitals from meaning: "invia il messaggio a costa" → Costa (a name), \
        "quanto costa il biglietto" → costa (a verb). Decide per sentence.

        Self-corrections: on "actually / no wait / anzi / no aspetta / plutôt", \
        drop ONLY the retracted words and keep the rest, lead-in included — \
        "ho letto il testo e questa è la risposta anzi questo è l'output" → \
        "Ho letto il testo e questo è l'output." When the marker reinforces \
        instead — "non è male, anzi è ottimo" — keep both halves.

        Numbered list only when one is dictated ("one… two… three…") or asked \
        for. "I invited Marco, Lucia and Tom" stays a sentence.

        \(toneLine) Register only.\(vocabLine)
        Output only the cleaned text.
        """
    }

    /// The two lines the built-in prompt takes from context, exposed so a bench
    /// can rebuild the exact system string a real dictation would have seen.
    static func toneLine(for tone: FormattingContext.Tone) -> String {
        switch tone {
        case .casual: return "Tone: casual and friendly (this is a chat/message)."
        case .email:  return "Tone: warm, polite, lightly enthusiastic (this is an email)."
        case .formal: return "Tone: clear and professional (this is a document)."
        case .neutral: return "Tone: keep the speaker's natural tone."
        }
    }

    /// Where an edited prompt wants its vocabulary line, if it cares.
    static let vocabularyMarker = "{{VOCAB}}"

    /// The system string an edited prompt actually produces. One function, so a
    /// bench that records "what this arm saw" cannot record something the
    /// formatter never sent — which it did, on the first run.
    static func compose(override: String, vocabLine: String) -> String {
        override.contains(vocabularyMarker)
            ? override.replacingOccurrences(of: vocabularyMarker, with: vocabLine)
            : override + vocabLine
    }

    static var vocabularyLine: String {
        Vocabulary.list.map {
            "\n- Preserve the EXACT spelling of these terms when they occur: \($0)."
        } ?? ""
    }

    /// Why the model's answer was refused. Written where the language is known.
    enum Rejection { case changedTooMuch, answered, emptyAnswer, failed }

    private func report(_ why: Rejection) async {
        await MainActor.run {
            let reason: String
            switch why {
            case .changedTooMuch:
                reason = L.t("il modello ha cambiato le tue parole",
                             "the model changed your words",
                             "le modèle a changé vos mots")
            case .answered:
                reason = L.t("il modello ha risposto invece di sistemare",
                             "the model answered instead of tidying",
                             "le modèle a répondu au lieu de corriger")
            case .emptyAnswer:
                reason = L.t("il modello non ha restituito niente",
                             "the model returned nothing",
                             "le modèle n’a rien renvoyé")
            case .failed:
                reason = L.t("il modello non ha risposto", "the model did not answer",
                             "le modèle n’a pas répondu")
            }
            CleanupReport.shared.modelWasRejected(reason)
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

    /// Words that ASK for punctuation instead of being it.
    ///
    /// "tra parentesi un milione" is meant to come back as "(un milione)", which
    /// means "tra" and "parentesi" have to disappear — and to the guard that
    /// looked like two content words deleted out of three, so the model's answer
    /// was thrown away and you got the command written out literally. Reported
    /// 2026-07-31. They only stop counting when the utterance actually contains
    /// a bracket word: "tra" is far too common to discount in general.
    private static let bracketNouns: Set<String> = [
        "parentesi", "parentheses", "parenthesis", "parenthèses", "parenthèse",
        "virgolette", "quotes", "guillemets", "brackets",
    ]
    private static let bracketHelpers: Set<String> = [
        "tra", "fra", "aperta", "chiusa", "aperte", "chiuse",
        "open", "close", "ouvre", "ferme",
    ]

    private static func contentWords(_ s: String) -> [String] {
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "'’")).inverted
        let words = s.lowercased().components(separatedBy: separators)
        let spoken = words.contains { bracketNouns.contains($0) }
        return words.filter {
            $0.count > 2 && !disposable.contains($0)
                && !bracketNouns.contains($0)
                && !(spoken && bracketHelpers.contains($0))
        }
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

    /// Words that say "forget what I just said". Their presence in the input is
    /// EVIDENCE that a fragment was meant to disappear, so the deletion budget
    /// widens when one shows up.
    ///
    /// Found on 2026-07-31 by writing the demonstration of this guard for
    /// the user: "la riunione è martedì alle dieci, no aspetta, mercoledì alle
    /// dieci e mezza" — a textbook self-correction, resolved perfectly by the
    /// model — was being DISCARDED. The retracted fragment was four content words
    /// and the flat budget allowed three. The guard was throwing away the app's
    /// headline feature whenever the retraction ran longer than a couple of words.
    ///
    /// Not in here: "plutôt", which is a connective and must keep failing, and
    /// "no" / "ma", which are too common in ordinary speech to mean anything.
    private static let retractionMarkers: Set<String> = [
        "aspetta", "anzi", "scusa", "correggo", "volevo",
        "wait", "sorry", "mean", "rather",
        "pardon", "excuse",
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
        //
        // The deletion budget widens when the speaker audibly retracted
        // something: "no aspetta", "anzi", "I mean" are the speaker ASKING for a
        // fragment to be dropped, and resolving them is the point of the model.
        // It stays bounded — a third of the text, never more — so a wholesale
        // rewrite still fails whatever markers it contains.
        // The marker has to have been REMOVED to count. "Il cliente aspetta" is a
        // customer waiting, not a retraction, and a marker that survives into the
        // output plainly was not one — widening the budget there would loosen the
        // guard on every sentence that happens to contain the word.
        let retracted = lost.contains { retractionMarkers.contains($0) }
        let deletionBudget = retracted ? max(5, before.count / 3) : max(3, before.count / 5)
        return lost.count > deletionBudget
            || invented > max(2, before.count / 10)
    }
}
#endif
