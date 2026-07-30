import Foundation

/// Free, instant, on-device cleanup — no model required. Removes filler words,
/// applies spoken punctuation/formatting commands, and tidies spacing and
/// capitalization. Multilingual for IT / EN / FR.
struct RuleBasedFormatter: TextFormatter {

    // Filler words per language (lowercased, word-boundary matched).
    private static let fillers: [Language: [String]] = [
        .english: ["um", "uh", "erm", "hmm", "like", "you know", "i mean", "sort of", "kind of"],
        .italian: ["ehm", "eh", "cioè", "tipo", "insomma", "praticamente", "diciamo"],
        .french:  ["euh", "bah", "ben", "genre", "tu vois", "enfin", "du coup", "quoi"],
    ]

    // Spoken commands → literal output. Order matters (longest first).
    private static let commands: [Language: [(phrase: String, replacement: String)]] = [
        .english: [
            ("new paragraph", "\n\n"), ("new line", "\n"),
            ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
            ("full stop", "."), ("period", "."), ("comma", ","),
            ("colon", ":"), ("semicolon", ";"), ("open quote", "\""), ("close quote", "\""),
        ],
        // NOTE: bare "punto"/"point" are NOT here — they are common nouns as
        // well as the full-stop command, so they go through `applyPeriodWord`
        // (context-aware). Multi-word phrases that CONTAIN them stay here and
        // run first (longest-first), so "punto e virgola" → ";" wins.
        .italian: [
            ("nuovo paragrafo", "\n\n"), ("a capo", "\n"), ("nuova riga", "\n"),
            ("punto interrogativo", "?"), ("punto esclamativo", "!"),
            ("punto e virgola", ";"), ("due punti", ":"),
            ("virgola", ","),
        ],
        .french: [
            ("nouveau paragraphe", "\n\n"), ("à la ligne", "\n"), ("nouvelle ligne", "\n"),
            ("point d'interrogation", "?"), ("point d'exclamation", "!"),
            ("point virgule", ";"), ("deux points", ":"),
            ("virgule", ","),
        ],
    ]

    /// Full-stop words that double as common nouns ("il punto 4", "punto di
    /// vista", "le point fort"). Converted to "." ONLY when acting as
    /// punctuation — skipped when preceded by a determiner/ordinal or followed
    /// by a digit or a known noun continuation.
    private struct PeriodWord {
        let word: String
        let determiners: [String]   // a preceding one → it's the noun
        let followNouns: [String]   // a following one → it's the noun
    }
    private static let periodWords: [Language: PeriodWord] = [
        .italian: PeriodWord(
            word: "punto",
            determiners: ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una",
                          "del", "dello", "della", "dei", "degli", "delle",
                          "al", "allo", "alla", "ai", "agli", "alle",
                          "nel", "nello", "nella", "dal", "dalla", "sul", "sulla",
                          "questo", "questa", "quel", "quello", "quella",
                          "ogni", "tal", "mio", "suo", "loro", "altro", "qualche",
                          "primo", "secondo", "terzo", "quarto", "quinto", "stesso", "certo"],
            followNouns: ["di", "debole", "chiave", "forte", "fermo", "nave", "vendita",
                          "vista", "focale", "cardine", "nascita", "morto", "cruciale", "critico"]),
        .french: PeriodWord(
            word: "point",
            determiners: ["le", "la", "les", "un", "une", "du", "des", "au", "aux",
                          "ce", "cet", "cette", "mon", "son", "leur", "chaque", "tout",
                          "premier", "deuxième", "troisième"],
            followNouns: ["de", "faible", "fort", "final", "mort", "cardinal", "chaud"]),
    ]

    func format(_ raw: String, context: FormattingContext) async -> String {
        let lang = context.language
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = applyCommands(to: text, lang: lang)
        text = applyPeriodWord(to: text, lang: lang)
        // Don't strip filler / re-capitalize inside code — preserve verbatim.
        if !context.isCodeEditor {
            text = removeFillers(from: text, lang: lang)
            text = capitalizeSentences(text)
            text = ensureTerminalPunctuation(text)
        }
        text = tidySpacing(text)
        return text
    }

    // MARK: - Steps

    private func applyCommands(to input: String, lang: Language) -> String {
        var out = input
        // Longest phrase first so "punto e virgola" beats "virgola", etc.
        for (phrase, replacement) in (Self.commands[lang] ?? []).sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Context-aware full-stop word ("punto"/"point"): turn it into "." only
    /// when it's punctuation, keep it as a word when it's the noun.
    private func applyPeriodWord(to input: String, lang: Language) -> String {
        guard let pw = Self.periodWords[lang] else { return input }
        let det = pw.determiners.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let fol = pw.followNouns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Not preceded by a determiner/ordinal, and not followed by a digit or
        // a known noun continuation → it's a spoken full stop.
        let pattern = "(?<!\\b(?:\(det))\\s)\\b\(pw.word)\\b(?!\\s+(?:\\d|(?:\(fol))\\b))"
        return input.replacingOccurrences(of: pattern, with: ".",
                                          options: [.regularExpression, .caseInsensitive])
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
                capitalizeNext = true
            }
        }
        return String(chars)
    }

    private func ensureTerminalPunctuation(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?\n".contains(last) ? trimmed : trimmed + "."
    }

    private func tidySpacing(_ input: String) -> String {
        var out = input
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,.;:!?])(?=[^ \\n])", with: "$1 ", options: .regularExpression)
        out = out.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
