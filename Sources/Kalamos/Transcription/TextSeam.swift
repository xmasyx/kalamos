import Foundation

/// Joining two pieces of a transcription without saying the same thing twice.
///
/// A repaired stretch is decoded from audio that deliberately overlaps its
/// neighbours by a fraction of a second, because a word straddling the edge is
/// otherwise transcribed from its second half. The cost of that overlap is a
/// word said twice at the seam: measured 2026-08-12, the repaired recording came
/// back with «tutti i progetti che stiamo sviluppando **sviluppando**, qui
/// abbiamo parlato…».
///
/// The whole difficulty is that he genuinely repeats himself when he
/// dictates — «tutto tutto tutto, lì mettiamo proprio tutto» is in the same
/// recording — so an eager de-duplicator would edit his speech. The rule
/// therefore leans hard towards leaving text alone: a single repeated word is
/// only dropped when it is long enough that saying it twice in a row is not
/// something people do.
enum TextSeam {
    /// The longest run of words compared across a seam.
    private static let maximumRun = 5

    /// A single repeated word is dropped only from this length up. Five-letter
    /// words like "tutto" stay: that repetition is his, not the decoder's.
    private static let shortestRepeatableWord = 6

    static func join(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce("") { joined, next in joined.isEmpty ? next : join(joined, next) }
    }

    static func join(_ first: String, _ second: String) -> String {
        let left = words(of: first)
        let right = words(of: second)
        guard !left.isEmpty, !right.isEmpty else {
            return [first, second].filter { !$0.isEmpty }.joined(separator: " ")
        }

        for run in stride(from: min(maximumRun, left.count, right.count), through: 1, by: -1) {
            let tail = left.suffix(run).map { normalized($0) }
            let head = right.prefix(run).map { normalized($0) }
            guard tail == head, !tail.contains(where: \.isEmpty) else { continue }
            if run == 1 && (tail[0].count < shortestRepeatableWord) { continue }

            // The repetition is dropped from the LEFT, keeping the right-hand
            // rendering. The two sides disagree about punctuation, and it is the
            // second one that carries the comma joining it to what follows:
            // «…stiamo sviluppando» + «sviluppando, qui abbiamo parlato» has to
            // come out with that comma, not without it.
            let kept = left.dropFirst(0).dropLast(run).joined(separator: " ")
            guard !kept.isEmpty else { return second }
            return kept + " " + lowercasedIfMidSentence(second, after: kept)
        }
        return first + " " + second
    }

    /// A sentence does not restart in the middle of itself.
    ///
    /// The right-hand piece was decoded as its own recording, so its first word
    /// is capitalised whether or not it began a sentence. Once it lands after
    /// something that does not end a sentence, that capital is an artefact.
    private static func lowercasedIfMidSentence(_ text: String, after left: String) -> String {
        guard let last = left.last, !".!?…:".contains(last) else { return text }
        guard let first = text.first, first.isUppercase else { return text }
        return text.replacingCharacters(in: ...text.startIndex, with: first.lowercased())
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Words match across a seam when their letters do; the decoder puts the
    /// punctuation wherever it thinks the sentence ended, and the two sides of a
    /// seam rarely agree about that.
    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
