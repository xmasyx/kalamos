import Foundation
import Testing
@testable import Kalamos

/// La guardia che impedisce al secondo giro del vocabolario di portare via parole.
///
/// I due poli, e il primo è il caso vero. **Polo negativo:** la dettatura del 13
/// agosto deve essere respinta, e se qualcuno toglie la guardia questo test
/// diventa rosso. **Polo positivo:** una fusione legittima — insegnare
/// `endomidollare` fonde «endomi dollare» in una parola sola — deve continuare a
/// passare, altrimenti la guardia ha ucciso la funzione che protegge.
@Suite struct ContentLossTests {

    /// La forma del caso del 13 agosto, non le sue parole.
    ///
    /// La prima passata mappava 11 segmenti fino a 74,8 s; la ri-decodifica col
    /// prompt mirato «Kalamos.» ne mappava 3 e sul tratto 60,0-76,9 s tornava
    /// vuota, e le ultime venticinque parole non arrivavano mai al testo.
    ///
    /// **La dettatura vera non sta qui, e non è pignoleria:** questo repo è
    /// pubblico, e il 2 agosto una registrazione reale è stata tolta da una
    /// sonda per la stessa ragione. Quello che il test deve misurare è la
    /// proprietà, cioè una coda di venticinque parole che sparisce mentre il
    /// resto migliora, e quella si riproduce con qualunque testo della stessa
    /// forma. Le parole di una persona non sono un dato di prova.
    static let primaPassata = """
        Nel manuale del prodotto non scrivere che il programma non spedisce \
        niente da nessuna parte, scrivi piuttosto che è un'applicazione di \
        dettatura per Mac che lavora completamente in locale, così da poter \
        mantenere la massima privacy, giocala su quel modo. Il paragrafo dopo va \
        bene. la parte sulle ragioni va bene quindi è semplicemente la prima riga \
        quella che non convince mentre nella scheda dell'altra applicazione non \
        scrivere copre lo schermo ma blocca lo schermo finché non hai fatto gli \
        esercizi e ti sei preso una pausa bisogna riscriverlo meglio dobbiamo \
        trovare anche un modo per migliorare il modo di scrivere di queste \
        schede perché così non funzionano
        """

    static let secondoGiro = """
        Nel manuale del prodotto non scrivere che il programma non spedisce \
        niente da nessuna parte, scrivi piuttosto che è un'applicazione di \
        dettatura per Mac che lavora completamente in locale, così da poter \
        mantenere la massima privacy. Giocala su quel modo. Il paragrafo dopo va \
        bene. La parte sulle ragioni va bene. Quindi è semplicemente la prima \
        riga quella che non convince. Mentre nella scheda dell'altra \
        applicazione non scrivere copre lo schermo ma blocca lo schermo finché \
        non hai fatto gli esercizi e ti sei preso una pausa.
        """

    @Test("il caso del 13 agosto viene respinto")
    func realCaseIsRejected() {
        // Un solo termine nel prompt mirato: «Kalamos.»
        #expect(ContentLoss.lostContent(first: Self.primaPassata,
                                        second: Self.secondoGiro, terms: 1))
    }

    @Test("e la coda persa era davvero contenuto, non rumore")
    func realCaseLostRealWords() {
        let perse = ContentLoss.words(in: Self.primaPassata)
            - ContentLoss.words(in: Self.secondoGiro)
        // Venticinque parole in cambio di una: è il conto che ha aperto il caso.
        #expect(perse >= 20)
    }

    @Test("una fusione legittima passa")
    func legitimateMergeSurvives() {
        // Il secondo giro insegna `endomidollare` e fonde le due metà: perde una
        // parola, ed è esattamente il lavoro per cui esiste.
        let primo = "il chiodo endomi dollare è la tecnica che uso da otto anni"
        let secondo = "il chiodo endomidollare è la tecnica che uso da otto anni"
        #expect(!ContentLoss.lostContent(first: primo, second: secondo, terms: 1))
    }

    @Test("cinque termini possono fondere cinque volte")
    func budgetFollowsTheNumberOfTerms() {
        #expect(ContentLoss.budget(terms: 5) == 5)
        // Il pavimento: sotto i due termini restano comunque due fusioni, perché
        // il motore sposta i confini anche dove non gliel'abbiamo chiesto.
        #expect(ContentLoss.budget(terms: 1) == 2)
        #expect(ContentLoss.budget(terms: 0) == 2)
    }

    @Test("un secondo giro più lungo non è mai una perdita")
    func longerIsNeverLoss() {
        let primo = "la ragione è ok"
        let secondo = "la ragione è ok quindi semplicemente la prima riga che non mi piace"
        #expect(!ContentLoss.lostContent(first: primo, second: secondo, terms: 1))
    }

    @Test("testo identico non è una perdita")
    func identicalIsNotLoss() {
        #expect(!ContentLoss.lostContent(first: Self.secondoGiro,
                                         second: Self.secondoGiro, terms: 1))
    }

    /// Il banco dell'8 agosto, che passò per vinto perdendo la frase in coda.
    ///
    /// La clip bilingue: sedici passate su sedici si sono mangiate la frase
    /// inglese finale, e il WER non se ne è accorto perché misurava le parole
    /// scritte, non quelle mancanti. La coda qui sotto ha la stessa forma di
    /// quella vera, cioè un cambio di lingua in fondo, e non le stesse parole.
    @Test("anche la clip bilingue del banco viene respinta")
    func benchClipIsRejected() {
        let coda = " and here the recording switches language for one sentence."
        let primo = String(repeating: "parola ", count: 150) + coda
        let secondo = String(repeating: "parola ", count: 150)
        // Due termini nel prompt: «Kalamos, endomidollare.»
        #expect(ContentLoss.lostContent(first: primo, second: secondo, terms: 2))
    }
}
