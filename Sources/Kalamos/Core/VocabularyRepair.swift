import Foundation

/// Puts your words back into the transcription, in your spelling.
///
/// Until 2026-08-01 the vocabulary was **decorative**. It fed two things and
/// neither worked: Whisper's `promptTokens` biasing, disabled on purpose because
/// it returned empty transcriptions deterministically, and a line in the cleanup
/// prompt ("Preserve the EXACT spelling of these terms"). That line was measured
/// on 180 transcriptions from three engines with "Kalamos" sitting in the prompt:
/// **zero names repaired**, on every engine. On one of them the model made it
/// worse, turning "endomidollare" into "indomarelllo", a word that does not exist.
///
/// So the repair moved to where the report said it belonged: code, which cannot
/// be talked out of it. `Corrections` already does this for pairs you type in by
/// hand; this does it for the words you only had to name once.
///
/// **The failure mode this is built against** is not "misses a name" — it is the
/// opposite. On 2026-07-31 an acoustic vocabulary rescorer with default settings
/// rewrote "nella sala grande" into "nella sala Claude" and "il 23 settembre"
/// into "il 23 iTerm": it inserted the terms into sentences that contained none.
/// A repair that vandalises ordinary speech is worse than no repair at all,
/// because you cannot see it happen. Hence three brakes, all measured:
///
///   1. **Exact-but-miscased is free** and always safe: "rossi" → "Rossi".
///      No distance, no threshold, no judgement.
///   2. **Fuzzy repair needs a term of 5+ characters**, swept over his corpus
///      rather than picked. Below that a term is one edit from ordinary words:
///      "repo" is four characters and one edit from "reso", "rete", "remo".
///      Short terms get case normalisation and nothing else.
///   3. **The edit budget is absolute, not a ratio**: `max(1, length/5)`. A ratio
///      alone lets a long term swallow a long unrelated word — "controllare" is
///      54% similar to "endomidollare", and that substitution actually happened.
///
/// Measured on his 240 real dictations plus the 180 bench transcriptions; the
/// sweep that set the budget is in `--selftest-vocab`.
enum VocabularyRepair {

    /// Longest window of words compared against one term. "ai term" → "iTerm"
    /// needs two; "Claude Desktop" mistranscribed needs three.
    static let maxWindow = 3

    /// Below this a term is only case-normalised, never fuzzy-matched.
    ///
    /// **Swept, not chosen**, twice — and the first sweep was measuring the wrong
    /// thing. `--selftest-vocab` over his 240 real dictations (480 texts):
    ///
    ///     min-fuzzy   cambi   riparazioni giuste   danni
    ///        4         23            23              0   ← ma vedi sotto
    ///        5         15            15              0
    ///        6         15            15              0
    ///        7         15            15              0
    ///
    /// The first sweep put the floor at seven, because at five the corpus threw
    /// up a real casualty: "una cartella temporanea di **cloud e** per me"
    /// came back as "di **Claude** per me". That was never about the threshold —
    /// it was the window widening in BOTH directions. Widening now only leftward
    /// (see the core-at-the-end rule below), the casualty is gone and five is
    /// free. Which matters, because "iTerm" is five characters and "lifeOS" six:
    /// at seven, the two terms Parakeet gets wrong most were unreachable.
    ///
    /// **Four is where it stops, and not because the corpus complained** — at
    /// four it made eight MORE correct repairs and zero wrong ones, all of them
    /// "QEN"/"Quen"/"Gwen" → "QWEN". It stops there because "repo" is four
    /// characters and one edit from "reso", "rete", "remo", "reti", "rene". The
    /// corpus happens not to contain them; the language does. A floor set by what
    /// a sample did not happen to say is not a floor.
    /// For a four-letter term, the right tool is a `Corrections` rule.
    static let minFuzzyLength = 5

    /// **Il budget più largo per Parakeet è stato provato e BOCCIATO** (19/08).
    ///
    /// L'idea era buona sulla carta: i due motori sbagliano a distanze diverse.
    /// WhisperKit manca il termine di poco («Calamos» per «Kalamos», un edit) e
    /// il budget stretto lo prende; Parakeet lo manca di più — «noce» e
    /// «noccia» per «notch», «mitli» per «Meetly» — e con budget 1 su un
    /// termine di cinque lettere resta fuori. Da qui `extraBudget`, che allarga
    /// il budget di uno sui termini corti.
    ///
    /// Il cancello sulla metà di taratura ha prodotto 16 cambi in più, e
    /// leggerli — che è l'unica prova che conta — ne ha bocciati **dieci**:
    ///
    ///     la narrativa reale     → la narrativa README
    ///     quando si chiude       → quando si Claude
    ///     rilasciato ieri        → rilasciato iTerm
    ///     le note generate       → le notch generate
    ///     del colore e del toggle → del colore excel toggle
    ///     un numero reale        → un numero README
    ///
    /// Contro sei riparazioni giuste. È esattamente il vandalismo del 31/07,
    /// e la regola è che ne basta uno. Il difetto non è il numero scelto: è che
    /// un budget più largo mangia **parole italiane vere**, e la frenata che lo
    /// impediva era proprio quella. Nessun ritocco lo salva, perché le parole
    /// mangiate («reale», «note», «ieri», «chiude») sono più comuni dei termini
    /// che si volevano riparare.
    ///
    /// Il parametro resta, e `--selftest-vocab --budget-extra N` lo esercita:
    /// serve a poter **rimisurare** la bocciatura invece di ricordarsela. In
    /// produzione nessun motore lo alza — `apply` è chiamata senza.
    /// Apply the vocabulary to a raw transcription.
    /// `knows` è la guardia del dizionario: risponde «la lingua conosce questa
    /// parola?», e una parola che la lingua conosce non viene MAI sostituita per
    /// somiglianza. È la stessa guardia che `LearnedCorrections` ha dal 15/08,
    /// portata qui il 30/08 dal caso «forse» → «Forge»: il termine ha cinque
    /// lettere, quindi passa la frenata 2, e dista un edit da una delle parole
    /// più comuni della lingua, quindi passa la 3. Nessuna soglia lo prende,
    /// perché il difetto non è nella distanza: è che la parola scritta era
    /// giusta. Passata `nil`, la riparazione si comporta come prima.
    static func apply(to text: String, terms: [String] = Vocabulary.terms,
                      minFuzzyLength: Int = minFuzzyLength,
                      extraBudget: Int = 0,
                      knows: ((String) -> Bool)? = nil) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var result = text
        // Longest terms first: "Claude Desktop" must win over "Claude", or the
        // single-word term consumes the first half and the pair never matches.
        for term in terms.sorted(by: { $0.count > $1.count }) {
            result = applyOne(term, to: result, minFuzzyLength: minFuzzyLength,
                              extraBudget: extraBudget, knows: knows)
        }
        return result
    }

    // MARK: - One term

    private static func applyOne(_ term: String, to text: String, minFuzzyLength: Int,
                                 extraBudget: Int, knows: ((String) -> Bool)? = nil) -> String {
        let target = fold(term)
        guard !target.isEmpty else { return text }
        // Il supplemento vale solo per i termini corti, ed è lì che serve: su
        // «notch» (5) porta il budget da 1 a 2 e raggiunge «noce». Su
        // «endomidollare» (13) il budget è già 2, e portarlo a 3 vorrebbe dire
        // riaprire proprio il caso che la frenata esiste per chiudere.
        let budget = max(1, target.count / 5) + (target.count <= 7 ? extraBudget : 0)

        var tokens = tokenize(text)
        let termWords = term.split(separator: " ").count
        // Windows measured in WORDS, widest first. A two-word term can arrive as
        // one word ("Claude Desktop" heard as one) or as three; a one-word term
        // can arrive as two ("iTerm" → "ai term", "LifeOS" → "l'iFOS"). Widest
        // first so "ai term" is taken as a pair before "term" is judged alone.
        let widths = Set([termWords, termWords + 1, max(1, termWords - 1)])
            .filter { $0 >= 1 && $0 <= maxWindow }
            .sorted(by: >)

        // Position in the WORD sequence, not in the token array — the first
        // version counted tokens, so a two-word window was "word + space" and
        // nothing multi-word could ever match. Caught by the tests, not by me.
        var wordSlot = 0
        while true {
            let words = tokens.indices.filter { tokens[$0].isWord }
            guard wordSlot < words.count else { break }
            var advanced = false

            for width in widths where wordSlot + width <= words.count {
                let from = words[wordSlot], to = words[wordSlot + width - 1]
                let span = tokens[from...to]
                // What sits BETWEEN the words of a window: a space, an
                // apostrophe or a hyphen is nothing; a full stop is a sentence
                // boundary, and a window that crosses one is joining two
                // different sentences into a name.
                let joiners = span.filter { !$0.isWord }.map(\.text).joined()
                guard joiners.allSatisfy({ " '’-\u{2019}".contains($0) }) else { continue }

                let joined = span.map(\.text).joined()
                let candidate = fold(joined)
                guard !candidate.isEmpty else { continue }

                // Already the term, possibly miscased. Free, and always right.
                if candidate == target {
                    if joined != term {
                        tokens.replaceSubrange(from...to, with: [.word(term)])
                        advanced = true
                    }
                    break
                }
                // Fuzzy. Short terms are excluded: see brake 2.
                guard target.count >= minFuzzyLength, candidate.count >= 3 else { continue }
                // A wide window is tried before a narrow one, which is right for
                // "ai term" → "iTerm" and wrong the moment one of the words is
                // ALREADY the term: "a claude" is one edit from "claude", so
                // "ho chiesto a claude" came back as "ho chiesto Claude" and the
                // preposition was gone. If the exact word is in there, the exact
                // match at the narrower width is the answer.
                let alreadyExact = (wordSlot..<(wordSlot + width)).contains {
                    fold(tokens[words[$0]].text) == target
                }
                guard !alreadyExact else { continue }

                // A window wider than the term is a bet that the engine split one
                // word in two, and that bet is only ever right in ONE direction:
                // the head of a foreign word leaks into the word BEFORE it —
                // "iTerm" arrives as "ai term", "LifeOS" as "l'iFOS",
                // "endomidollare" as "e indomidollare". The tail does not leak
                // into the word after.
                //
                // Without this the widening is symmetric, and symmetric is what
                // ate a real sentence of his: "una cartella temporanea di cloud e
                // per me" came back as "di Claude per me", because "cloud e"
                // folds to one edit from "claude". So the core must sit at the END
                // of the window — the last words closer to the term than the first.
                // This is what lets the threshold go below seven at all.
                if width > termWords {
                    let core = fold(((wordSlot + width - termWords)..<(wordSlot + width))
                        .map { tokens[words[$0]].text }.joined())
                    let head = fold((wordSlot..<(wordSlot + termWords))
                        .map { tokens[words[$0]].text }.joined())
                    guard distance(core, target, cap: target.count) <
                            distance(head, target, cap: target.count) else { continue }
                }
                // Il plurale del termine NON è il termine.
                //
                // Trovato il 19/08 leggendo il cancello sulle sue dettature:
                // «le **dettature** brevi» tornava «le **dettatura** brevi», e
                // «sono delle dettature» tornava «delle dettatura». Il termine
                // «dettatura» è un sostantivo italiano comunissimo, il suo
                // plurale dista un edit, e il budget di un termine di nove
                // lettere è esattamente uno: la riparazione non poteva non
                // scattare. Girava in produzione su ENTRAMBI i motori, e il
                // danno è invisibile — un plurale sbagliato in un testo che
                // nessuno rilegge non somiglia a un errore di trascrizione.
                //
                // La firma dell'inflessione italiana è precisa: stessa
                // lunghezza, differenza SOLO nell'ultima lettera, e le due
                // ultime lettere sono vocali (-a/-e/-i/-o). Nessuna
                // riparazione misurata la incrocia: «Calamos» differisce sulla
                // prima lettera, «notce» finisce per consonante, «Antropic» ha
                // lunghezza diversa, «dentatura» differisce in mezzo e resta
                // riparata. Quello che si perde è un termine dettato davvero al
                // singolare quando la lista lo ha al plurale, che è un caso da
                // `Corrections`, non da indovinare.
                if èSoloUnaDesinenza(candidate, target) { continue }
                // Una parola che la lingua conosce è già una parola: il motore
                // non ha sbagliato a scriverla, e sostituirla per somiglianza
                // vandalizza una frase corretta. Vale solo sulla finestra di una
                // parola sola — «cloud e» non è una parola, e per quel caso la
                // frenata è il nucleo-in-fondo qui sopra.
                if width == 1, let knows, knows(joined) { continue }
                if distance(candidate, target, cap: budget) <= budget {
                    tokens.replaceSubrange(from...to, with: [.word(term)])
                    advanced = true
                    break
                }
            }
            // One step past whatever was consumed. A replacement collapses a
            // window to one word, so the next slot is the one after it.
            wordSlot += advanced ? 1 : 1
        }
        return tokens.map(\.text).joined()
    }

    // MARK: - Tokens
    //
    // The text is split into words and everything-else, and rebuilt by
    // concatenation, so punctuation and spacing survive a replacement exactly as
    // they were. A regex that replaced words in place would have to guess how to
    // put the sentence back together.

    enum Token {
        case word(String)
        case gap(String)
        var text: String {
            switch self { case .word(let s), .gap(let s): return s }
        }
        var isWord: Bool { if case .word = self { return true }; return false }
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber
            if currentIsWord == nil || isWord == currentIsWord {
                current.append(ch)
            } else {
                tokens.append(currentIsWord! ? .word(current) : .gap(current))
                current = String(ch)
            }
            currentIsWord = isWord
        }
        if let isWord = currentIsWord, !current.isEmpty {
            tokens.append(isWord ? .word(current) : .gap(current))
        }
        return tokens
    }

    /// Lowercase, strip accents, drop everything that is not a letter or digit.
    ///
    /// Dropping the spaces is what makes "ai term" one edit from "iTerm" instead
    /// of two, and "l'iFOS" one edit from "LifeOS". Where the engine puts its word
    /// boundaries is not information about what it heard.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Le due parole differiscono solo per la vocale finale?
    ///
    /// È la firma dell'inflessione italiana, e serve a non far passare per
    /// riparazione ciò che è una declinazione: `dettature` → `dettatura`.
    static func èSoloUnaDesinenza(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count, a.count >= 2, a != b else { return false }
        let x = Array(a), y = Array(b)
        guard x.dropLast() == y.dropLast() else { return false }
        let vocali: Set<Character> = ["a", "e", "i", "o", "u"]
        return vocali.contains(x[x.count - 1]) && vocali.contains(y[y.count - 1])
    }

    /// Levenshtein, abandoned as soon as every cell in a row exceeds `cap`.
    ///
    /// The cap is not only speed: it is the guard's shape. Without it the
    /// function computes exact distances for pairs that were never going to
    /// match, on every word of every dictation, for every term in the list.
    static func distance(_ a: String, _ b: String, cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(1, x.count) where !x.isEmpty {
            current[0] = i
            var best = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                best = Swift.min(best, current[j])
            }
            if best > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
