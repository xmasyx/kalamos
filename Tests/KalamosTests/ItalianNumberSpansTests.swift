import Foundation
import Testing
@testable import Kalamos

/// I numeri di Parakeet in cifre, e soprattutto le frasi che NON devono
/// diventare numeri.
///
/// Ogni «non deve» qui sotto è una frase vera del suo corpus, presa dal cancello
/// `--selftest-numeri` sulla metà di taratura il 19/08: la prima versione del
/// normalizzatore convertiva ogni parola-numero, e su nove cambi cinque erano
/// modi di dire — «costruirlo a zero», «tutte e tre», «l'occupazione in due».
/// Il numero glielo aveva già detto (0,13 punti contro 0,22, con cinque
/// dettature peggiorate), ma è leggerli che ha deciso la regola.
@Suite struct ItalianNumberSpansTests {

    // MARK: - Quello che deve fare

    @Test func unDecimaleAttaccatoDiventaUnNumero() {
        #expect(ItalianNumberSpans.apply(to: "occupa uno.cinque più") == "occupa 1.5 più")
    }

    @Test func laBarraFraDueDecimaliDiventaUnaFrazione() {
        #expect(ItalianNumberSpans.apply(to: "occupa uno.cinque barra uno.sette più Windows")
                == "occupa 1.5/1.7 più Windows")
    }

    @Test func perCentoDopoUnNumeroDiventaIlSegno() {
        #expect(ItalianNumberSpans.apply(to: "Abbassiamo il suono al trenta per cento.")
                == "Abbassiamo il suono al 30%.")
    }

    @Test func laVirgolaFraDueNumeriDiventaUnSeparatore() {
        #expect(ItalianNumberSpans.apply(to: "sono trenta virgola cinque gradi")
                == "sono 30,5 gradi")
    }

    /// Le decine composte si scrivono attaccate in italiano, e la troncatura
    /// davanti a «uno» e «otto» è una regola, non un elenco.
    @Test func leDecineComposteSonoUnaParolaSola() {
        #expect(ItalianNumberSpans.value["ventuno"] == 21)
        #expect(ItalianNumberSpans.value["ventotto"] == 28)
        #expect(ItalianNumberSpans.value["ventitré"] == 23)
        #expect(ItalianNumberSpans.value["novantanove"] == 99)
    }

    // MARK: - Quello che NON deve fare, che è il punto

    /// «Sei» è il verbo essere, e questa frase è sua, dal corpus: la conversione
    /// ingenua la manderebbe in «6 sicuro che siano».
    @Test func seiVerboNonDiventaUnNumero() {
        let f = "Sei sicuro che siano 1,73 ore di audio in 37 giorni"
        #expect(ItalianNumberSpans.apply(to: f) == f)
    }

    @Test func lArticoloIndeterminativoNonDiventaUnNumero() {
        let f = "mi serve una app web e un file di configurazione, uno solo"
        #expect(ItalianNumberSpans.apply(to: f) == f)
    }

    /// I cinque modi di dire che hanno bocciato la prima versione.
    @Test func iModiDiDireRestanoParole() {
        for f in ["è meglio costruirlo a zero come stavamo facendo",
                  "voglio vederle tutte e tre",
                  "WhisperKit spezzetta l'occupazione in due",
                  "lunedì agosto 2026 zero registrazioni",
                  "dammi a piacere due righe"] {
            #expect(ItalianNumberSpans.apply(to: f) == f, "toccata: \(f)")
        }
    }

    /// «punto» è un sostantivo e davanti ha un articolo: nessun numero a
    /// sinistra del segno, quindi nessun separatore.
    @Test func ilPuntoSostantivoNonDiventaUnSeparatore() {
        let f = "Il punto sette non ho capito."
        #expect(ItalianNumberSpans.apply(to: f) == f)
    }

    /// «per» preposizione: senza un numero davanti, «per cento» resta due parole.
    @Test func perPreposizioneNonDiventaIlSegno() {
        let f = "vale per cento persone diverse"
        #expect(ItalianNumberSpans.apply(to: f) == f)
    }

    /// Il polo negativo generale: un testo senza numeri esce identico. È la
    /// stessa domanda che il cancello sul corpus fa su 158 dettature, ed è qui
    /// perché una riparazione che tocca una frase che non la riguarda è il
    /// guasto che nessuno vede.
    @Test func unTestoSenzaNumeriEsceIdentico() {
        let f = "Nella barra menu il bordo intorno mi sembra troppo, e lo spazio anche."
        #expect(ItalianNumberSpans.apply(to: f) == f)
    }

    /// Il marcatore interno non deve mai sopravvivere nel testo consegnato,
    /// nemmeno quando la costruzione non si chiude.
    @Test func ilMarcatoreInternoNonEsceMai() {
        for f in ["al trenta per cento", "vale per cento persone", "30 per cento", "per cento"] {
            #expect(!ItalianNumberSpans.apply(to: f).contains("\u{0}"))
        }
    }
}
