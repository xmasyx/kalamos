import Foundation

/// Writes a dictated keyboard shortcut the way a keyboard shortcut is written.
///
/// You say "CMD A" and you mean ⌘A, so the text should read `CMD+A`. Saying the
/// plus out loud is not something anyone does, and typing it afterwards defeats
/// the point of dictating.
///
/// **In code, not in the cleanup prompt**, and the reason is measured rather
/// than stylistic: the prompt is asked for judgement calls the guard cannot make,
/// and every attempt this project has made to add a mechanical rule to it has
/// either not worked or cost more than it bought (the ~1100-token version, and
/// the variant that forbade repairing grammar). A rule that can be written as a
/// rule belongs where it cannot be talked out of it.
///
/// **The failure to avoid is not the missed shortcut, it is the mangled
/// sentence.** "L'opzione B è migliore" is ordinary Italian, and turning it into
/// "L'opzione+B è migliore" would be worse than never firing at all. So the
/// modifiers split into two classes: words that are only ever modifiers, and
/// words that are also ordinary Italian. The second class has to earn it.
enum KeyCombos {

    /// The modifiers, and every one of them is a word Italian does not have.
    ///
    /// The first version also accepted "comando", "controllo" and "opzione",
    /// with a guard that refused them after an article. It was not enough, and
    /// the test that caught it is ordinary speech: "la prima **opzione B** non mi
    /// convince" puts an adjective between the article and the noun, so the word
    /// in front is "prima" and the guard never fires. Any rule that tries to
    /// decide whether an Italian noun is being used as a noun will keep losing
    /// sentences like that one.
    ///
    /// So the list holds only words that cannot be anything else in an Italian
    /// dictation. The cost is stated rather than hidden: "comando S" gets no
    /// plus. The benefit is that no sentence he actually speaks can be damaged
    /// by this, which is the trade every guard in this app has made.
    private static let modifiers: Set<String> = [
        "cmd", "command", "ctrl", "control", "alt", "option", "shift",
        "fn", "meta", "super",
    ]

    /// What can sit to the RIGHT of a modifier and still be a shortcut: one
    /// letter, one digit, or a key with a name.
    private static let namedKeys: Set<String> = [
        "invio", "enter", "return", "esc", "escape", "tab", "spazio", "space",
        "canc", "delete", "backspace", "home", "end", "fine",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// An article in front turns even an English key name into a noun — "the
    /// option B" is a choice, not a chord. A cheap belt on top of the braces,
    /// and it costs nothing because no shortcut is ever spoken with an article.
    private static let articles: Set<String> = [
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "l",
        "dell", "della", "delle", "degli", "del", "dei",
        "nell", "nella", "sull", "sulla", "all", "alla",
        "quest", "questa", "questo", "quel", "quella", "ogni",
        "the", "a", "an", "his", "her",
    ]

    /// True when this word can only be a modifier, or can be one here.
    private static func isModifier(_ word: String, precededBy previous: String?) -> Bool {
        guard modifiers.contains(word.lowercased()) else { return false }
        guard let previous else { return true }
        return !articles.contains(previous.lowercased())
    }

    /// Single letters that are also whole words. In Italian "e", "o" and "a" are
    /// conjunctions and prepositions, and they turn up right after a key name all
    /// the time: "premi shift **e** vai avanti" came back as "shift+e vai avanti"
    /// on the first build.
    private static let letterWords: Set<Character> = ["a", "e", "i", "o", "è", "y"]

    /// True when this word is something a modifier can be pressed WITH.
    ///
    /// A letter that is also a word has to be CAPITAL to count. A dictated
    /// shortcut arrives capitalised — "CMD A", "CTRL 3" — and a conjunction does
    /// not, so the case is the only evidence available and it happens to be
    /// reliable. The cost: "cmd a" all in lowercase gets no plus, while
    /// "cmd b" does.
    private static func isTarget(_ word: String) -> Bool {
        let lower = word.lowercased()
        if namedKeys.contains(lower) { return true }
        guard word.count == 1, let c = word.first, c.isLetter || c.isNumber else { return false }
        guard let low = lower.first, letterWords.contains(low) else { return true }
        return c.isUppercase
    }

    /// Join dictated shortcuts with a plus, leaving everything else alone.
    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var tokens = VocabularyRepair.tokenize(text)
        let words = tokens.indices.filter { tokens[$0].isWord }
        guard words.count >= 2 else { return text }

        // Walk the word sequence, and for each run of modifiers followed by a
        // target, replace the gaps INSIDE the run with a plus. Only the gaps:
        // the words themselves are left exactly as they were said, because
        // "CMD" and "comando" are the speaker's choice and not ours to
        // normalise.
        var joins: [Int] = []          // token indices of gaps to replace
        var i = 0
        while i < words.count {
            let previous = i > 0 ? tokens[words[i - 1]].text : nil
            guard isModifier(tokens[words[i]].text, precededBy: previous) else { i += 1; continue }

            var run = [i]
            var j = i + 1
            while j < words.count,
                  isModifier(tokens[words[j]].text, precededBy: tokens[words[j - 1]].text) {
                run.append(j)
                j += 1
            }
            // A run of modifiers with nothing to press is just words.
            guard j < words.count, isTarget(tokens[words[j]].text) else { i = j + 1; continue }
            run.append(j)

            // Every gap between consecutive words of the run must be plain
            // space. A comma or a full stop between them means the sentence
            // moved on, whatever the words say.
            var ok = true
            var gaps: [Int] = []
            for k in 0..<(run.count - 1) {
                let from = words[run[k]], to = words[run[k + 1]]
                guard to == from + 2, case .gap(let g) = tokens[from + 1],
                      g.allSatisfy({ $0 == " " }) else { ok = false; break }
                gaps.append(from + 1)
            }
            if ok { joins.append(contentsOf: gaps) }
            i = j + 1
        }

        guard !joins.isEmpty else { return text }
        for index in joins { tokens[index] = .gap("+") }
        return tokens.map(\.text).joined()
    }
}
