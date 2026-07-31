import Foundation

/// How a finished transcription is fitted to the text that is already there.
///
/// Dictation does not land in an empty world: there is a cursor, and usually
/// something to the left of it. Two small decisions make chained dictations feel
/// like continuing to write instead of restarting — a space, and a capital.
///
/// Pure functions on purpose. The Accessibility read that produces `before`
/// belongs to `TextInjector` and cannot be unit-tested; these rules can, and
/// they are where the edge cases live.
enum TextShaping {

    /// Punctuation that binds to the word on its LEFT. A space in front of it is
    /// always wrong — "parola ," is not a thing in any of the three languages.
    private static let bindsLeft: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "»", "”", "'"]

    /// After these, the next dictation starts a new sentence.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", "\n", "•", "-"]

    /// - Parameters:
    ///   - text: the cleaned transcription, about to be injected.
    ///   - before: the characters immediately left of the cursor, as read over
    ///     Accessibility. `nil` means the app would not say — Electron and most
    ///     terminals — and every rule that needs it is skipped rather than guessed.
    static func prepare(_ text: String,
                        before: String?,
                        addSpace: Bool,
                        smartCapitals: Bool,
                        forceLowercase: Bool = false,
                        dropTrailingPeriod: Bool = false,
                        chaining: Bool = true) -> String {
        var out = text
        guard !out.isEmpty else { return out }

        // A full stop at the end of a search query or a shell command is noise
        // the cleanup added, not something you said. Only the period: a question
        // mark or an exclamation carries meaning and stays.
        if dropTrailingPeriod, out.hasSuffix(".") , !out.hasSuffix("..") {
            out.removeLast()
        }

        // The last character that is not whitespace, and whether there was any
        // whitespace after it. Both questions are asked of the same string once.
        let trimmed = before?.reversed().drop { $0 == " " || $0 == "\t" }
        let lastMeaningful = trimmed?.first
        let endsWithSpace = before.map { $0.last == " " || $0.last == "\t" || $0.last == "\n" } ?? false
        let atVeryStart = before?.isEmpty ?? false

        // An explicit "always lowercase" wins over the context rule: you asked
        // for it precisely because the context is not what you want followed.
        if forceLowercase {
            out = lowercasingFirst(out)
        } else if smartCapitals, let last = lastMeaningful ?? (atVeryStart ? "\n" : nil) {
            // Mid-sentence: "…and then" + "we shipped" must not become "We shipped".
            // After a full stop, or at the start of an empty field, it must.
            if sentenceEnders.contains(last) {
                out = capitalisingFirst(out)
            } else {
                out = lowercasingFirst(out)
            }
        }

        if addSpace, !atVeryStart, !endsWithSpace, let first = out.first, !bindsLeft.contains(first) {
            // When the app WILL say what is before the cursor, the rules above
            // decided already. When it will not — terminals, Electron, which is
            // where he actually dictates — the space is added only if we are
            // continuing: another dictation went into this same app a moment
            // ago. A shell prompt after a pause gets nothing, because a leading
            // space there is not neutral: with `HIST_IGNORE_SPACE` set, zsh and
            // bash quietly drop that command from your history.
            if before != nil || chaining { out = " " + out }
        }

        return out
    }

    /// First letter only — `capitalized` would lowercase every other word, which
    /// destroys "API", "MacBook" and every name in the sentence.
    private static func capitalisingFirst(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        // Never touch an all-caps opener: "API returns a list" is an acronym,
        // not a capitalised sentence.
        let second = s.dropFirst().first
        if let second, second.isUppercase { return s }
        return first.lowercased() + s.dropFirst()
    }
}
