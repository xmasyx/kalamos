import Foundation

/// Sceglie QUALI parole del vocabolario mettere nel prompt, invece di metterle
/// tutte.
///
/// **Misurato il 2026-08-05, ed è controintuitivo: un prompt lungo danneggia un
/// termine che è dentro il prompt stesso.** Sulla clip r02, con `endomidollare`
/// presente in tutte e tre le prove:
///
///   · 16 termini, com'è il suo vocabolario  → «endomi-dollare» (2 su 2)
///   · 15 termini, tolto `limb-lengthening`  → «endomi dollare» (2 su 2)
///   · 3 termini mirati                      → «endomidollare» (2 su 2)
///
/// Due cose separate, e vale la pena distinguerle. Il **trattino** arriva da
/// `limb-lengthening`: un prompt di Whisper è testo d'esempio, e lo stile di una
/// voce contagia le altre. La **spaccatura** arriva invece dalla lunghezza:
/// quindici termini bastano a spezzare la parola comunque. Lo stesso effetto era
/// già uscito sulle scorciatoie, dove il lessico corto riparava «control alt
/// canc» 3 su 3 e lo stesso termine dentro il vocabolario lungo non lo riparava.
///
/// Quindi il prompt si costruisce **dopo una prima decodifica**, tenendo solo i
/// termini che quella decodifica sembra aver sbagliato. Costa un secondo decode
/// (0,4 s sul suo Mac) e solo quando serve davvero: se il grezzo non somiglia a
/// nessun termine, non c'è nessun secondo giro.
enum VocabularyPrompt {
    /// Quanti termini al massimo. Cinque perché tre funzionavano e sedici no, e
    /// perché un prompt mirato che ne contiene cinque è già più lungo di quello
    /// che ha riparato tutto nel banco.
    static let maxTerms = 5

    /// I termini che il testo grezzo sembra aver sbagliato: somigliano a una
    /// parola scritta, ma non ci sono scritti giusti.
    ///
    /// È deliberatamente la stessa distanza che usa `VocabularyRepair` a valle.
    /// Due misuratori diversi per la stessa domanda divergono in silenzio, e in
    /// questo progetto è già successo.
    static func candidates(for raw: String, terms: [String] = Vocabulary.terms) -> [String] {
        let folded = VocabularyRepair.fold(raw)
        let words = VocabularyRepair.tokenize(raw)
            .filter(\.isWord)
            .map { VocabularyRepair.fold($0.text) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var chosen: [String] = []
        for term in terms {
            let target = VocabularyRepair.fold(term)
            guard target.count >= VocabularyRepair.minFuzzyLength else { continue }
            // Già scritto giusto: insegnarglielo di nuovo è solo rumore nel prompt.
            if folded.contains(target) { continue }
            let budget = max(1, target.count / 5)
            // Una parola sola, oppure due parole attaccate: il motore sposta i
            // confini («ai term» per «iTerm»), ed è lo stesso motivo per cui
            // `fold` butta via gli spazi.
            let coppie = zip(words, words.dropFirst()).map { $0 + $1 }
            if (words + coppie).contains(where: {
                VocabularyRepair.distance($0, target, cap: budget) <= budget
            }) {
                chosen.append(term)
                if chosen.count == maxTerms { break }
            }
        }
        return chosen
    }

    /// Il prompt vero e proprio, o `nil` se non c'è niente da insegnare.
    ///
    /// Lista di termini separati da virgola e nient'altro. Non «Glossario:», non
    /// una frase: un prompt di Whisper è contesto precedente, e un'etichetta gli
    /// fa credere di stare trascrivendo un glossario.
    static func text(for raw: String, terms: [String] = Vocabulary.terms) -> String? {
        let c = candidates(for: raw, terms: terms)
        return c.isEmpty ? nil : c.joined(separator: ", ") + "."
    }
}
