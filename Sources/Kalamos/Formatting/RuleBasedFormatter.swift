import Foundation

/// Free, instant, on-device cleanup — no model required. Removes filler words,
/// applies spoken punctuation/formatting commands, and tidies spacing and
/// capitalization. Multilingual for IT / EN / FR.
struct RuleBasedFormatter: TextFormatter {

    /// Filler words per language (lowercased, word-boundary matched).
    ///
    /// **Only sounds that are never words.** Until 2026-08-18 this list also
    /// held `cioè`, `tipo`, `insomma`, `praticamente`, `diciamo` — and in
    /// English `like`, `you know`, `i mean`, `sort of`, `kind of`. They were
    /// deleted on sight, with no look at what surrounded them, and two real
    /// dictations came back mutilated the same evening: *«Allora diciamo che il
    /// 15…»* lost its verb, *«…perché? cioè noi avevamo…»* lost its connective.
    /// In English the same list eats the verb in "I like this".
    ///
    /// This is **exactly** the class the punctuation-word guard below was built
    /// for, and that guard's comment already stated the general rule: *a guard
    /// that covers one member of a class is a guard someone has to remember to
    /// copy*. Nobody had copied it here.
    ///
    /// Italian reads from `SpeechRepairs.fillerPuri` instead of keeping a second
    /// copy: two lists that disagreed are how this happened, and the one that
    /// had been measured on the real archive lost to the one that had not.
    /// English and French are trimmed by the same principle but **without
    /// measurement** — conservative, not tuned, and that is the honest word.
    private static let fillers: [Language: [String]] = [
        .english: ["um", "uh", "erm", "hmm"],
        .italian: SpeechRepairs.fillerPuri.sorted(),
        .french:  ["euh"],
    ]

    // Spoken commands → literal output. Order matters (longest first).
    private static let commands: [Language: [(phrase: String, replacement: String)]] = [
        .english: [
            ("new paragraph", "\n\n"), ("new line", "\n"),
            ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
            ("full stop", "."),
            ("colon", ":"), ("semicolon", ";"), ("open quote", "\""), ("close quote", "\""),
        ],
        // NOTE: the bare punctuation NAMES are not here — "punto"/"point"/"period"
        // and "virgola"/"virgule"/"comma" are common nouns as well as commands, so
        // they go through `applyPunctuationWord` (context-aware). Multi-word
        // phrases that CONTAIN them stay here and run first (longest-first), so
        // "punto e virgola" → ";" wins.
        .italian: [
            ("nuovo paragrafo", "\n\n"), ("a capo", "\n"), ("nuova riga", "\n"),
            ("punto interrogativo", "?"), ("punto esclamativo", "!"),
            ("punto e virgola", ";"), ("due punti", ":"),
        ],
        .french: [
            ("nouveau paragraphe", "\n\n"), ("à la ligne", "\n"), ("nouvelle ligne", "\n"),
            ("point d'interrogation", "?"), ("point d'exclamation", "!"),
            ("point virgule", ";"), ("deux points", ":"),
        ],
    ]

    /// Punctuation names that double as common nouns ("il punto 4", "punto di
    /// vista", "una virgola mobile", "not a single comma"). Converted to the
    /// mark ONLY when acting as punctuation, skipped when preceded by a
    /// determiner or quantifier, or followed by a digit or a known noun
    /// continuation.
    ///
    /// `virgola` was a plain blunt replacement until 2026-08-11, when two real
    /// dictations ABOUT commas came back with the word eaten both times
    /// ("arriva senza una sola virgola" → "arriva senza una sola,"). `punto` had
    /// been given this guard long before; its twin never was, and the same hole
    /// was open in all three languages. Hence one table instead of two: a guard
    /// that covers one member of a class is a guard someone has to remember to
    /// copy.
    private struct PunctuationWord {
        let word: String
        let replacement: String
        let determiners: [String]   // a preceding one → it's the noun
        let followNouns: [String]   // a following one → it's the noun
    }
    private static let punctuationWords: [Language: [PunctuationWord]] = [
        .italian: [
            PunctuationWord(
                word: "punto", replacement: ".",
                determiners: ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una",
                              "del", "dello", "della", "dei", "degli", "delle",
                              "al", "allo", "alla", "ai", "agli", "alle",
                              "nel", "nello", "nella", "dal", "dalla", "sul", "sulla",
                              "questo", "questa", "quel", "quello", "quella",
                              "ogni", "tal", "mio", "suo", "loro", "altro", "qualche",
                              "primo", "secondo", "terzo", "quarto", "quinto", "stesso", "certo"],
                followNouns: ["di", "debole", "chiave", "forte", "fermo", "nave", "vendita",
                              "vista", "focale", "cardine", "nascita", "morto", "cruciale", "critico"]),
            PunctuationWord(
                word: "virgola", replacement: ",",
                determiners: ["la", "le", "una", "un", "senza", "sola", "sole", "singola",
                              "nessuna", "qualche", "ogni", "questa", "quella", "altra",
                              "stessa", "ultima", "prima", "della", "delle", "alla", "alle",
                              "dalla", "sulla", "con", "di", "doppia", "mia", "sua"],
                followNouns: ["mobile", "decimale", "fissa"]),
        ],
        .french: [
            PunctuationWord(
                word: "point", replacement: ".",
                determiners: ["le", "la", "les", "un", "une", "du", "des", "au", "aux",
                              "ce", "cet", "cette", "mon", "son", "leur", "chaque", "tout",
                              "premier", "deuxième", "troisième"],
                followNouns: ["de", "faible", "fort", "final", "mort", "cardinal", "chaud"]),
            PunctuationWord(
                word: "virgule", replacement: ",",
                determiners: ["la", "les", "une", "un", "sans", "seule", "seules", "aucune",
                              "chaque", "cette", "autre", "dernière", "première", "même",
                              "de", "avec", "double", "ma", "sa", "leur"],
                followNouns: ["flottante", "décimale", "fixe"]),
        ],
        .english: [
            PunctuationWord(
                word: "period", replacement: ".",
                determiners: ["a", "the", "this", "that", "one", "each", "every", "any",
                              "long", "short", "same", "grace", "trial", "time", "no",
                              "another", "first", "second", "third", "whole", "entire"],
                followNouns: ["of", "piece", "drama", "costume", "furniture", "when", "in"]),
            PunctuationWord(
                word: "comma", replacement: ",",
                determiners: ["a", "the", "no", "one", "single", "without", "any", "each",
                              "every", "this", "that", "another", "final", "first", "last",
                              "oxford", "serial", "extra", "missing"],
                followNouns: ["splice", "separated", "delimited"]),
        ],
    ]

    func format(_ raw: String, context: FormattingContext) async -> String {
        let lang = context.language
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = applyCommands(to: text, lang: lang)
        text = applyPunctuationWord(to: text, lang: lang)
        // Don't strip filler / re-capitalize inside code — preserve verbatim.
        if !context.isCodeEditor {
            text = removeFillers(from: text, lang: lang)
            // **Le riparazioni del parlato girano ANCHE qui, ed è la riparazione
            // che conta.** Fino al 2026-08-18 `SpeechRepairs.rAgg` era chiamata
            // solo da `L1Formatter`, cioè solo sul parlato lungo e non
            // punteggiato. Le sue dettature corte e già punteggiate da Whisper
            // prendono questa strada, quindi la risoluzione delle
            // autocorrezioni — «il 15, anzi no il 17» — non veniva **mai
            // eseguita** su di loro. Tre casi di campo consecutivi lo dicono:
            // zero autocorrezioni risolte, perché la regola non era in questo
            // percorso. Solo italiano: i marcatori e le locuzioni sono parole
            // italiane, e applicarli altrove sarebbe indovinare.
            if lang == .italian { text = SpeechRepairs.rAgg(text) }
            text = capitalizeSentences(text)
            text = ensureTerminalPunctuation(text)
        }
        text = tidySpacing(text)
        return text
    }

    // MARK: - Steps

    func applyCommands(to input: String, lang: Language) -> String {
        var out = input
        // Longest phrase first so "punto e virgola" beats "virgola", etc.
        for (phrase, replacement) in (Self.commands[lang] ?? []).sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Context-aware punctuation names ("punto"/"virgola" and their siblings):
    /// turn one into its mark only when it's punctuation, keep it as a word when
    /// it's the noun.
    func applyPunctuationWord(to input: String, lang: Language) -> String {
        var out = input
        for pw in Self.punctuationWords[lang] ?? [] {
            let det = pw.determiners.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let fol = pw.followNouns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            // Not preceded by a determiner/quantifier, and not followed by a
            // digit or a known noun continuation → it's the spoken mark.
            let pattern = "(?<!\\b(?:\(det))\\s)\\b\(pw.word)\\b(?!\\s+(?:\\d|(?:\(fol))\\b))"
            out = out.replacingOccurrences(of: pattern, with: pw.replacement,
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private func removeFillers(from input: String, lang: Language) -> String {
        var out = input
        for filler in (Self.fillers[lang] ?? []).sorted(by: { $0.count > $1.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: filler) + "\\b[,]?"
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private func capitalizeSentences(_ input: String) -> String {
        var chars = Array(input)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(String(c).uppercased())
                capitalizeNext = false
            } else if ".!?\n".contains(c) {
                // A dot BETWEEN TWO DIGITS is a decimal or thousands separator,
                // not the end of a sentence: "2.5 gigabyte" was coming back as
                // "2. 5 Gigabyte" because this branch armed the capital and
                // `tidySpacing` then split the number in two.
                if c == ".", Self.isBetweenDigits(chars, i) { continue }
                capitalizeNext = true
            }
        }
        return String(chars)
    }

    /// True when `chars[i]` has a digit immediately on both sides — the shape of
    /// "1,73", "2.5", "1.250,40".
    private static func isBetweenDigits(_ chars: [Character], _ i: Int) -> Bool {
        i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
    }

    func ensureTerminalPunctuation(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?\n".contains(last) ? trimmed : trimmed + "."
    }

    func tidySpacing(_ input: String) -> String {
        var out = input
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        // Space after a mark that runs straight into the next word — EXCEPT a
        // `.` or `,` sitting between two digits, which is part of the number
        // ("1,73 ore", "2.5 gigabyte", "1.250,40 euro"). The leading lookahead
        // is the exclusion: it fails the match only when the previous char is a
        // digit, the mark is a separator, and a digit follows.
        out = out.replacingOccurrences(of: "(?!(?<=\\d)[.,](?=\\d))([,.;:!?])(?=[^ \\n])",
                                       with: "$1 ", options: .regularExpression)
        out = out.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
