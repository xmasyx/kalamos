import AppKit

/// Does the language already have this word?
///
/// Asked by `LearnedCorrections`, and only there. A correction rule rewrites its
/// left-hand side in every future dictation, for ever, silently — so the one
/// thing that must never end up on that side is an ordinary word.
///
/// **The case, 2026-08-15.** A dictation had *«come stavamo facendo»* written as
/// *«come stanno facendo»*. He fixed it, and the app learned `stanno → stavamo`:
/// a global rule on one of the commonest verbs in Italian. Every future "stanno"
/// would have come out as "stavamo", in text nobody re-reads, and the rule that
/// did it would have been invisible in a settings list he has no reason to open.
///
/// The guards that were already there could not catch it. It is six letters, so
/// the length floor passed. It has no digits. It differs from its replacement.
/// What makes it wrong is not its shape, it is that the word exists.
///
/// macOS ships the answer, offline and per language, and this is the whole of
/// the integration.
enum SystemDictionary {

    /// True when the spell checker recognises the word in that language.
    ///
    /// **Fails open, and says so in the log.** If the dictionary for a language
    /// is not installed, every word comes back unknown and the guard would let
    /// everything through — which is exactly today's behaviour, so nothing gets
    /// worse; but a guard that has quietly stopped guarding is the thing worth
    /// knowing about (2026-07-13: a branch that emits nothing is
    /// indistinguishable from a branch that never ran).
    /// Le risposte si ricordano, e non è un'ottimizzazione gratuita.
    ///
    /// Dal 30/08 questa guardia è chiamata anche da `VocabularyRepair`, cioè una
    /// volta per termine per parola invece che una volta per regola imparata: il
    /// banco su 1786 testi non è arrivato in fondo in dieci minuti senza questa
    /// riga. Il dizionario di sistema non cambia sotto i piedi durante una corsa.
    @MainActor private static var cache: [String: Bool] = [:]

    @MainActor
    static func knows(_ word: String, language: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        let key = language + "\u{0}" + w.lowercased()
        if let hit = cache[key] { return hit }

        let checker = NSSpellChecker.shared
        let tag = checker.availableLanguages.contains(where: { $0.hasPrefix(language) })
        if !tag {
            Log.write("dizionario: nessun vocabolario di sistema per «\(language)», la guardia sulle regole non filtra")
            return false
        }
        let found = checker.checkSpelling(of: w, startingAt: 0, language: language,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let known = found.location == NSNotFound
        cache[key] = known
        return known
    }
}
