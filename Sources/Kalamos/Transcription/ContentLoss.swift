import Foundation

/// Il secondo giro del vocabolario non può portare via parole.
///
/// **Il caso vero, 13 agosto 2026, 22:47, 77,1 secondi di dettatura.** La prima
/// passata mappa 11 segmenti fino a 74,8 s e scrive tutto. Poi parte la
/// ri-decodifica col prompt mirato «Kalamos.», che rimappa lo stesso audio in 3
/// soli segmenti e sul tratto 60,0-76,9 s torna **vuota** — tre tentativi e una
/// ricarica del modello compresi. Il risultato più corto viene accettato, perché
/// la guardia in quel punto guardava solo *vuoto* e *degenerato*. Il secondo giro
/// aveva comprato una parola, il nome del prodotto scritto giusto, pagandone
/// venticinque: **104 parole diventate 79**, e le venticinque erano le ultime,
/// cioè due frasi intere di istruzioni che non sono mai arrivate al testo.
///
/// **E non era il primo.** Sul registro completo, 17 secondi giri su 107 hanno
/// perso 3 o più parole, 173 parole in tutto. Sedici sono il banco dell'8 agosto
/// sulla clip bilingue, dove ogni singola passata si mangiava la frase inglese in
/// coda — e quel banco fu dichiarato vinto misurando il WER, che sulle parole
/// sparite non ha niente da dire. È esattamente la trappola già pagata sul
/// parlato lungo: una misura di accuratezza non è una misura di completezza.
///
/// **Perché il conteggio delle parole e non la mappa dei segmenti.** La mappa è
/// il segnale più forte, ma esiste solo dentro il percorso WhisperKit, e il
/// difetto è dei due motori. Il testo è l'unica cosa che entrambi consegnano,
/// quindi la guardia vive dove vive il difetto invece che dove è più comodo.
///
/// **Perché una tolleranza e non zero.** Il secondo giro accorcia anche quando ha
/// ragione: insegnargli `endomidollare` fonde «endomi dollare» in una parola
/// sola, e ogni termine del prompt può farlo una volta. La soglia è quindi legata
/// a quanti termini stiamo insegnando, non a un numero tondo — con un pavimento a
/// due, perché sotto ci sono le fusioni ordinarie e non la perdita di contenuto.
enum ContentLoss {
    /// Le parole di un testo, contate come le conta il vocabolario.
    ///
    /// Deliberatamente `VocabularyRepair.tokenize` e non uno `split` locale: due
    /// misuratori diversi per la stessa domanda divergono in silenzio, e in
    /// questo progetto è già successo (`VocabularyPrompt` fa la stessa scelta per
    /// la stessa ragione).
    static func words(in text: String) -> Int {
        VocabularyRepair.tokenize(text).filter(\.isWord).count
    }

    /// Quante parole il secondo giro può perdere restando accettabile.
    ///
    /// Una per termine insegnato, cioè la fusione che quel termine può produrre,
    /// e mai meno di due.
    static func budget(terms: Int) -> Int {
        max(2, terms)
    }

    /// `true` se il secondo giro ha portato via contenuto e va scartato.
    ///
    /// Un secondo giro **più lungo** non è mai una perdita: allungare è il modo in
    /// cui un prompt recupera una parola che il primo giro non aveva sentito.
    static func lostContent(first: String, second: String, terms: Int) -> Bool {
        let lost = words(in: first) - words(in: second)
        return lost > budget(terms: terms)
    }
}
