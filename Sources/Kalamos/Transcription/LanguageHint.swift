import Foundation

/// A second opinion on what language a transcription is actually in.
///
/// ISC-111, the "Amen". On 2026-08-01 at 01:21 Whisper marked this entirely
/// Italian sentence `lang=en`:
///
///   "Un altro problema è che nelle impostazioni di Kalamos, nelle parole tue,
///    dopo l'ultima che ha aggiunto, non mi fa vedere le altre … Amen."
///
/// Decoded with an English prior, it produced the classic trailing-silence
/// hallucination on the end. Measured over 325 dictations: 6 marked `lang=en`,
/// of which 2 plainly Italian.
///
/// Adding "amen" to the hallucination list would hide this one instance. It is a
/// blacklist, so it only ever catches what it already contains, and the next
/// wrong-language dictation invents a different word. The cause is the language
/// decision, so that is where the fix goes.
///
/// **Deliberately conservative.** Guessing wrong here is worse than not guessing:
/// it would force an Italian decode onto real English speech. So it answers
/// `nil` unless one language wins clearly, and short text always answers `nil` —
/// two words carry no evidence.
enum LanguageHint {

    /// Words that belong to ONE of these three languages and are common enough
    /// to appear in ordinary speech.
    ///
    /// Anything ambiguous across the three is left out on purpose — "come" is
    /// both Italian and English, "la" and "le" are Italian and French, "a" is
    /// everywhere. A marker that fires for two languages is not a marker.
    private static let markers: [Language: Set<String>] = [
        .italian: ["che", "perché", "sono", "della", "questo", "quando", "anche",
                   "più", "sempre", "essere", "nel", "alla", "degli", "gli",
                   "molto", "cosa", "però", "quindi", "adesso", "delle", "nelle",
                   "ancora", "dopo", "senza", "fare", "però", "solo", "già"],
        .english: ["the", "and", "that", "with", "this", "have", "from", "they",
                   "what", "would", "there", "which", "about", "been", "because",
                   "should", "could", "these", "them", "your", "will"],
        .french:  ["pas", "pour", "dans", "avec", "cette", "être", "mais", "nous",
                   "vous", "leur", "sont", "tout", "aussi", "très", "alors",
                   "faire", "plus", "cela", "donc", "chez"],
    ]

    /// The least evidence worth acting on.
    private static let minimumHits = 3
    /// And how far ahead the winner has to be. A sentence that mixes languages —
    /// Italian speech quoting an English product name — must not be re-decoded.
    private static let requiredMargin = 2

    /// The language this text looks like, or nil when it is not clear.
    static func guess(_ text: String) -> Language? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 6 else { return nil }   // too short to carry evidence
        let bag = Set(words)

        var scores: [Language: Int] = [:]
        for (language, marks) in markers {
            // Counted over OCCURRENCES, not distinct words: "che" three times is
            // three pieces of evidence for Italian.
            scores[language] = words.filter { marks.contains($0) }.count
            _ = bag
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= minimumHits else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard best.value >= runnerUp * requiredMargin, best.value > runnerUp else { return nil }
        return best.key
    }

    /// Does the text contradict the language Whisper reported?
    ///
    /// Only ever true when the guess is confident AND different. Everything
    /// uncertain resolves to "no", because the cost of a wrong yes is decoding
    /// English speech as Italian.
    static func contradicts(_ detected: Language?, text: String) -> Language? {
        guard let detected, let guessed = guess(text), guessed != detected else { return nil }
        return guessed
    }
}
