import Foundation

/// Decides, from the raw transcript alone, whether the AI cleanup is worth the
/// seconds it costs. This is the whole brain of the `auto` formatter mode.
///
/// **Why the text and not the clock.** The obvious trigger is duration: short
/// audio goes to the rules, long audio goes to the model. Measured against 957
/// real dictations on 2026-08-11, that trigger is wrong. Of the dictations over
/// 50 words, **58% already came back correctly punctuated by Whisper**, because
/// Whisper punctuates from prosody: when the speaker pauses, it writes the
/// commas. A duration trigger sends all of those to the model and buys nothing.
///
/// The defect is not "the audio was long", it is "Whisper did not punctuate
/// this one" — and that is visible directly in the raw text. So the trigger is
/// punctuation density, which fires on 15% of the same corpus and fires where
/// the defect actually is.
///
/// The two numbers, from that corpus:
///
///   · over 25 words with ZERO marks          →  85 / 957  (8%)
///   · over 25 words and >20 words per mark   → 151 / 957  (15%)   ← chosen
///   · over 25 words and >15 words per mark   → 180 / 957  (18%)
enum CleanupNeed {

    /// Below this, the rules are enough by construction: a short dictation that
    /// lost a comma is still readable, and the wait would cost more than the
    /// comma is worth.
    static let minWords = 25

    /// Above this many words per punctuation mark, the sentence is a run-on
    /// that no rule can break up, because where to break it is a question about
    /// meaning.
    static let maxWordsPerMark = 20.0

    /// Marks that count as punctuation the reader can navigate by. Quotes,
    /// parentheses and hyphens are deliberately absent: they organise a phrase,
    /// they do not end or divide a clause.
    private static let marks: Set<Character> = [",", ";", ":", ".", "!", "?"]

    /// True when the AI cleanup would earn its seconds on this text.
    static func needsModel(_ raw: String) -> Bool {
        let words = raw.split(whereSeparator: \.isWhitespace).count
        guard words > minWords else { return false }
        let count = raw.reduce(into: 0) { n, c in if marks.contains(c) { n += 1 } }
        // Zero marks is the strongest possible signal, and dividing by it is
        // not: a wall of words with no punctuation at all always goes to the
        // model, without asking arithmetic to represent infinity.
        guard count > 0 else { return true }
        return Double(words) / Double(count) > maxWordsPerMark
    }
}
