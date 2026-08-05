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

    /// Cambia una parola già salvata, **al suo posto**.
    ///
    /// Non è `remove` più `add`: `add` accoda, quindi correggere un refuso in una
    /// voce a metà lista la manderebbe in fondo. Una modifica che riordina la
    /// lista non è una modifica, è una modifica più uno spostamento che nessuno
    /// ha chiesto — la stessa ragione per cui l'annulla ripristina uno scatto
    /// dell'intera lista invece di ri-aggiungere la parola.
    ///
    /// Un nome vuoto o già presente altrove non passa: nel primo caso resterebbe
    /// una riga fantasma, nel secondo due righe identiche di cui una sola
    /// riparabile.
    @discardableResult
    static func rename(_ old: String, to new: String) -> Bool {
        guard let updated = renamed(terms, old, to: new) else { return false }
        UserDefaults.standard.set(updated, forKey: key)
        return true
    }

    /// La stessa decisione, senza toccare niente: lista dentro, lista fuori.
    ///
    /// Separata perché la versione che scrive nei default non è provabile in
    /// parallelo — i test di questo progetto girano insieme e condividono un solo
    /// `UserDefaults`, quindi si sabotavano a vicenda. La regola generale: la
    /// decisione si prova pura, la scrittura è una riga sola sopra di essa.
    static func renamed(_ list: [String], _ old: String, to new: String) -> [String]? {
        let value = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var all = list
        guard let i = all.firstIndex(of: old) else { return nil }
        if value.caseInsensitiveCompare(old) != .orderedSame,
           all.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            return nil
        }
        all[i] = value
        return all
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
