import Foundation

/// Turning one correction into a rule that holds for every dictation after it.
///
/// Asked for on 2026-08-12: ⌃⌥V already asks what the dictation should have
/// said, and that answer was only being filed as training material. If the same
/// word is going to be misheard again tomorrow, the app already knows how to fix
/// it — `Corrections` has done exactly that for months — and nobody had joined
/// the two halves.
///
/// The whole file is therefore about what NOT to learn, because a correction
/// rule is global, permanent and silent: it rewrites that word in every future
/// dictation, and a wrong one corrupts text nobody is checking. The rules below
/// each exist to stop a specific way this could go wrong.
enum LearnedCorrections {

    /// At most this many rules from one correction. Beyond it he was not fixing
    /// a misheard word, he was rewriting the sentence, and rewriting is not
    /// something to generalise from.
    static let cap = 3

    /// Shorter than this and the word is grammar, not vocabulary. "e"/"è",
    /// "a"/"ha", "de"/"del": those pairs are decided by the sentence around
    /// them, so a global rule would be right once and wrong for ever after.
    static let shortestLearnableWord = 4

    /// Below this the two texts are not the same sentence, and the alignment
    /// between them means nothing. Rewriting a paragraph must teach nothing.
    static let leastSimilarity = 0.5

    /// What the app should learn from "it heard this, he meant that".
    static func rules(heard: String, meant: String,
                      known: Set<String> = []) -> [CorrectionRule] {
        guard !heard.isEmpty, !meant.isEmpty,
              DictationTruth.similarity(heard, meant) >= leastSimilarity else { return [] }

        var found: [CorrectionRule] = []
        for (was, now) in substitutions(words(heard), words(meant)) {
            guard found.count < cap, learnable(was: was, now: now),
                  !known.contains(bare(was).lowercased()) else { continue }
            found.append(CorrectionRule(wrong: bare(was).lowercased(), correct: bare(now)))
        }
        return found
    }

    /// A single word swapped for a single word, in a context that otherwise
    /// matches.
    ///
    /// One-for-one is the whole point: an insertion has no heard side to key a
    /// rule on, a deletion has nothing to write, and a block of several words
    /// changed at once is a rephrasing. Only the narrow case where he replaced
    /// exactly one word with exactly one word is evidence of a misrecognition.
    static func substitutions(_ was: [String], _ now: [String]) -> [(String, String)] {
        let table = commonLength(was, now)
        var pairs: [(String, String)] = []
        var i = 0, j = 0
        while i < was.count, j < now.count {
            if bare(was[i]).lowercased() == bare(now[j]).lowercased() {
                // The same word to the alignment, but not the same on the page:
                // this is how a name learns its capital letter. Aligning
                // case-insensitively is what makes the rest of the diff work, so
                // the case difference has to be picked up right here or not at
                // all.
                if bare(was[i]) != bare(now[j]) { pairs.append((was[i], now[j])) }
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                // A word vanished. If exactly one word replaced it, that is a
                // substitution; otherwise the shapes do not line up and nothing
                // is learned from here.
                let skipped = table[i + 1][j] > table[i][j + 1]
                if !skipped { pairs.append((was[i], now[j])); i += 1; j += 1 }
                else { i += 1 }
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Every reason a swap is not safe to turn into a rule.
    static func learnable(was: String, now: String) -> Bool {
        let a = bare(was), b = bare(now)
        guard a.count >= shortestLearnableWord, !b.isEmpty else { return false }
        // Numbers are the dangerous case and the one that started all this: the
        // dictation that said one hundred and was written two hundred. A rule
        // «200 → 100» would rewrite every future two hundred. Nothing with a
        // digit in it is ever learned.
        guard !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        // Same word, different comma: the archive's business, not a rule's.
        // A difference of case alone IS kept — that is how a name learns its
        // capital letter.
        return a != b
    }

    /// A word without the punctuation stuck to it. Accented letters are letters,
    /// and this is Italian, so the test is Unicode's and not ASCII's.
    static func bare(_ word: String) -> String {
        String(word.drop(while: { !$0.isLetter && !$0.isNumber })
            .reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Length of the longest common subsequence for every suffix pair.
    private static func commonLength(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = bare(a[i]).lowercased() == bare(b[j]).lowercased()
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }
}
