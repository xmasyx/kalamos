import Testing
@testable import Kalamos

// Il livello L1 senza il modello: le parti deterministiche della pipeline
// (spoglia/tokenizza/allinea, politica I5W, riparazioni del parlato) si provano
// qui coi DUE poli; l'equivalenza col banco, che richiede il modello da 1,1 GB,
// passa da `--bench-l1` / `--bench-i5w` ed è refertata nel banco stesso.
//
// Nessuna frase qui dentro viene da una dettatura vera: il repo è pubblico.

struct PunctuationAlignTests {

    @Test func spogliaTogliSegniETieneDecimali() {
        #expect(PunctuationAlign.spoglia("Costa 1.250,40 euro, non 2.5!") == "costa 1.250,40 euro non 2.5")
        #expect(PunctuationAlign.spoglia("Sei sicuro che siano 1,73 ore?") == "sei sicuro che siano 1,73 ore")
    }

    @Test func tokenizzaLeggeSegniMaiuscoleEAperture() {
        let tok = PunctuationAlign.tokenizza("Domani vengo, forse. E tu?")
        #expect(tok.map(\.core) == ["domani", "vengo", "forse", "e", "tu"])
        #expect(tok.map(\.mark) == ["", ",", ".", "", "?"])
        #expect(tok.map(\.cap) == [true, false, false, true, false])
        #expect(tok.map(\.inizioFrase) == [true, false, false, true, false])
    }

    @Test func allineaAppaiaSoloLeParoleUguali() {
        let ref = PunctuationAlign.tokenizza("la porta verde resta chiusa")
        let hyp = PunctuationAlign.tokenizza("la porta rossa resta chiusa")
        let coppie = PunctuationAlign.allinea(ref, hyp)
        // «verde»≠«rossa»: 4 coppie su 5, e la parola diversa resta fuori.
        #expect(coppie.count == 4)
        #expect(!coppie.contains { $0.r == 2 })
    }

    @Test func allineaReggeParoleInPiuEInMeno() {
        let ref = PunctuationAlign.tokenizza("mandalo a lucia stasera")
        let hyp = PunctuationAlign.tokenizza("mandalo subito a lucia")
        let coppie = PunctuationAlign.allinea(ref, hyp)
        #expect(coppie.count == 3)  // mandalo, a, lucia
    }
}

struct PunctuationHybridTests {

    // La tabella della politica I5: il terminale di Whisper vince, la sua
    // virgola vale solo dove L1 non chiude la frase, il resto è di L1.
    @Test func laSceltaDiSegnoSegueLaPoliticaMisurata() {
        #expect(PunctuationHybrid.scegliSegno(whisper: ".", l1: ",") == ".")
        #expect(PunctuationHybrid.scegliSegno(whisper: "?", l1: "") == "?")
        #expect(PunctuationHybrid.scegliSegno(whisper: ",", l1: "") == ",")
        #expect(PunctuationHybrid.scegliSegno(whisper: ",", l1: ".") == ".")  // mai sopra un terminale di L1
        #expect(PunctuationHybrid.scegliSegno(whisper: "", l1: ",") == ",")
        #expect(PunctuationHybrid.scegliSegno(whisper: "", l1: "") == "")
    }

    @Test func smorzaConnettiviSoloInAperturaDiFrase() {
        // In apertura la virgola cade…
        var pezzi = [PunctuationHybrid.Pezzo(parola: "inoltre", mark: ","),
                     PunctuationHybrid.Pezzo(parola: "non", mark: ""),
                     PunctuationHybrid.Pezzo(parola: "ricordo", mark: ".")]
        #expect(PunctuationHybrid.smorzaConnettivi(pezzi).map(\.mark) == ["", "", "."])
        // …dopo un terminale pure…
        pezzi = [PunctuationHybrid.Pezzo(parola: "bene", mark: "."),
                 PunctuationHybrid.Pezzo(parola: "però", mark: ","),
                 PunctuationHybrid.Pezzo(parola: "resta", mark: ".")]
        #expect(PunctuationHybrid.smorzaConnettivi(pezzi).map(\.mark) == [".", "", "."])
        // …a metà frase l'inciso resta, e una parola fuori novero resta ovunque.
        pezzi = [PunctuationHybrid.Pezzo(parola: "domani", mark: ","),
                 PunctuationHybrid.Pezzo(parola: "infatti", mark: ","),
                 PunctuationHybrid.Pezzo(parola: "vengo", mark: ".")]
        #expect(PunctuationHybrid.smorzaConnettivi(pezzi).map(\.mark) == [",", ",", "."])
    }

    @Test func i5wEreditaDomandaEMaiuscoleDaWhisper() {
        // Whisper ha sentito la domanda e conosce il nome proprio; L1 mette la
        // virgola che Whisper non ha. La fusione tiene tutto.
        let parole = ["domani", "chiamo", "kalamos", "e", "poi", "vediamo"]
        let etichette = ["0", ",", "0", "0", "0", "."]
        let grezzo = "Domani chiamo Kalamos e poi vediamo?"
        let out = PunctuationHybrid.i5w(parole: parole, etichette: etichette, grezzo: grezzo)
        #expect(out == "Domani chiamo, Kalamos e poi vediamo?")
    }

    @Test func i5wSenzaGrezzoRestaPuroL1() {
        // Polo A/A: un grezzo senza segni né maiuscole non eredita niente, e
        // l'uscita è L1 più la sola regola d'inizio frase.
        let parole = ["il", "file", "non", "si", "apre"]
        let etichette = ["0", ",", "0", "0", "."]
        let out = PunctuationHybrid.i5w(parole: parole, etichette: etichette,
                                        grezzo: "il file non si apre")
        #expect(out == "Il file, non si apre.")
    }

    @Test func i5wNonSpaccaIDecimali() {
        let parole = ["costa", "1.250,40", "euro"]
        let etichette = ["0", "0", "."]
        let out = PunctuationHybrid.i5w(parole: parole, etichette: etichette,
                                        grezzo: "Costa 1.250,40 euro.")
        #expect(out == "Costa 1.250,40 euro.")
    }
}

struct SpeechRepairsTests {

    // Gli otto casi del selftest del banco sintetico, poli negativi compresi.
    @Test func rMinTogliSoloIFillerPuri() {
        #expect(SpeechRepairs.rMin("Ehm, però il file non si apre.") == "però il file non si apre.")
        #expect(SpeechRepairs.rMin("il file ehm, non si apre più") == "il file non si apre più")
        #expect(SpeechRepairs.rMin("Allora, cioè il punto è questo, ok?") == "Allora, cioè il punto è questo, ok?")
    }

    @Test func rAggTagliaSoloConLaRipetizione() {
        #expect(SpeechRepairs.rAgg("devo correggere la grammatica anzi la punteggiatura del testo")
            == "devo correggere la punteggiatura del testo")
        #expect(SpeechRepairs.rAgg("mandalo a marco no aspetta mandalo a lucia stasera")
            == "mandalo a lucia stasera")
    }

    // I poli che uccidono le regole ingenue: senza ripetizione non si tocca.
    @Test func rAggNonToccaGliUsiLegittimi() {
        #expect(SpeechRepairs.rAgg("non è male, anzi è ottimo direi")
            == "non è male, anzi è ottimo direi")
        #expect(SpeechRepairs.rAgg("no, aspetta un attimo prima di partire")
            == "no, aspetta un attimo prima di partire")
        #expect(SpeechRepairs.rAgg("volevo dire la verità a tutti quanti")
            == "volevo dire la verità a tutti quanti")
    }
}
