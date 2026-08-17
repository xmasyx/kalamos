import Foundation

/// Finds the failure mode that `carry_initial_prompt` exists to prevent.
///
/// Measured on 2026-08-05: with an initial prompt set and `carry_initial_prompt`
/// OFF, whisper.cpp on an 82-second file returned 198 words instead of 128 — of
/// which thirteen were the SAME invented sentence, repeated. It did it eight
/// times out of eight, so the output was perfectly stable and perfectly wrong,
/// which is the worst shape a defect can take: nothing downstream notices.
///
/// This is deliberately a property of the TEXT and not a check on a flag. A test
/// that asserts `params.carry_initial_prompt == true` restates the line it is
/// meant to protect and can never fail for a real reason. This one goes red if
/// somebody removes the flag, and it also goes red if a future engine finds a new
/// way into the same hole.
enum RepetitionGuard {
    /// The longest run of consecutive identical sentences, and the sentence.
    ///
    /// Consecutive on purpose: ordinary speech repeats a phrase across a
    /// paragraph all the time ("va bene … va bene"), and flagging that would make
    /// the guard cry wolf on his real dictations. A decode in a loop repeats
    /// back to back, with nothing in between.
    static func longestRun(in text: String) -> (sentence: String, count: Int) {
        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return ("", 0) }

        var best = (sentence: sentences[0], count: 1)
        var current = (sentence: sentences[0], count: 1)
        for s in sentences.dropFirst() {
            if s == current.sentence {
                current.count += 1
            } else {
                current = (s, 1)
            }
            if current.count > best.count { best = current }
        }
        return best
    }

    /// Three is the threshold because two is speech and thirteen was the defect.
    /// A person saying the same short sentence twice in a row is ordinary; three
    /// identical sentences back to back has never appeared in the 240 dictations
    /// on record.
    static let limit = 3

    /// The longest run of consecutive identical WORDS.
    ///
    /// The sentence-level run above cannot see this one, and the difference is
    /// punctuation: a decode that loops on a single word writes it separated by
    /// commas, so `longestRun` reads the whole thing as ONE sentence and answers
    /// 1. Measured 2026-08-16 on `d-reale-77s` with the audio cut into pieces:
    /// whisper.cpp, handed the recording's trailing room tone as a piece of its
    /// own, answered «No, no, no…» a hundred and ten times, and the guard said
    /// the text was fine.
    static func longestWordRun(in text: String) -> (word: String, count: Int) {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return ("", 0) }
        var best = (word: words[0], count: 1)
        var current = (word: words[0], count: 1)
        for w in words.dropFirst() {
            current = w == current.word ? (current.word, current.count + 1) : (w, 1)
            if current.count > best.count { best = current }
        }
        return best
    }

    /// Eight, and the distance from `limit` is the point rather than an accident.
    ///
    /// He really does repeat a word three times in a row — «tutto tutto tutto, lì
    /// mettiamo proprio tutto» is in a real dictation, and `TextSeam` is built
    /// around not editing it. So this threshold sits far above anything a person
    /// says, and still an order of magnitude below the hundred-and-ten-word loop
    /// it exists to catch. Anything in between is left alone on purpose: the cost
    /// of dropping a piece of his speech is much higher than the cost of letting
    /// a short repetition through.
    static let wordLimit = 8

    static func degenerated(_ text: String) -> Bool {
        longestRun(in: text).count >= limit
            || longestWordRun(in: text).count >= wordLimit
    }
}
