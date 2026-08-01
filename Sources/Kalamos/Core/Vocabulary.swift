import Foundation

/// Personal dictionary: custom terms (names, jargon, special spellings) kept
/// fully on-device. Used to (a) bias WhisperKit recognition via prompt tokens
/// and (b) tell the cleanup/translation LLM to preserve the exact spellings.
/// Backed by UserDefaults so both the menu (main thread) and the transcriber
/// (background) read the same list safely.
enum Vocabulary {
    private static let key = "vocabulary"

    static var terms: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var all = terms
        guard !all.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        all.append(t)
        UserDefaults.standard.set(all, forKey: key)
    }

    static func remove(_ term: String) {
        UserDefaults.standard.set(terms.filter { $0 != term }, forKey: key)
    }

    /// Put the list back exactly as it was (ISC-113, undo).
    ///
    /// Undo restores a SNAPSHOT rather than re-adding the word, because `add`
    /// appends: undoing a deletion from the middle would put the word back at
    /// the bottom. Same words, different list — and an undo that does not
    /// restore what was there is not an undo.
    static func setAll(_ all: [String]) {
        UserDefaults.standard.set(all, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Whisper initial-prompt text that biases recognition toward these terms.
    /// A Whisper initial prompt is *example text in the expected style*, not a
    /// labelled instruction: a "Glossary: …" prefix makes the model think the
    /// audio is a glossary reading and degenerate on unrelated speech. A bare
    /// comma list of the terms is the recommended biasing form.
    static var promptText: String? {
        let t = terms
        return t.isEmpty ? nil : t.joined(separator: ", ") + "."
    }

    /// Comma-joined list for LLM prompts ("keep these spellings…").
    static var list: String? {
        let t = terms
        return t.isEmpty ? nil : t.joined(separator: ", ")
    }
}
