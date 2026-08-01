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
///   2. **Fuzzy repair needs a term of 7+ characters**, swept over his corpus
///      rather than picked. Below that a term is one edit from ordinary words:
///      "repo" from "reso"/"rete"/"remo", and "Claude" from "cloud". Short terms
///      get case normalisation and nothing else.
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
    /// **Swept, not chosen.** `--selftest-vocab` over his 240 real dictations
    /// (480 texts), his own ten-term list:
    ///
    ///     min-fuzzy   cambi   di cui Calamos→Kalamos
    ///        4         25            13
    ///        5         17            13
    ///        6         17            13
    ///        7         15            13     ← ogni riparazione, nessun danno
    ///        8          2             0     ← "Kalamos" è di 7 caratteri
    ///
    /// Five let a six-letter term match a real word: "una cartella temporanea di
    /// **cloud e** per me" came back as "di **Claude** per me" — one edit from
    /// "Claude", and the "e" eaten with it. Eight throws away every repair,
    /// because the name being repaired is itself seven characters. Seven keeps
    /// all thirteen and costs nothing, and the two changes it still makes are the
    /// list being obeyed literally (his entry reads "lifeOS", so "LifeOS" becomes
    /// "lifeOS" — a typo in the list, not a bug here).
    static let minFuzzyLength = 7

    /// Apply the vocabulary to a raw transcription.
    static func apply(to text: String, terms: [String] = Vocabulary.terms,
                      minFuzzyLength: Int = minFuzzyLength) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var result = text
        // Longest terms first: "Claude Desktop" must win over "Claude", or the
        // single-word term consumes the first half and the pair never matches.
        for term in terms.sorted(by: { $0.count > $1.count }) {
            result = applyOne(term, to: result, minFuzzyLength: minFuzzyLength)
        }
        return result
    }

    // MARK: - One term

    private static func applyOne(_ term: String, to text: String, minFuzzyLength: Int) -> String {
        let target = fold(term)
        guard !target.isEmpty else { return text }
        let budget = max(1, target.count / 5)

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
