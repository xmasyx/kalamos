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

    /// **Il caso di campo del 2026-08-18.** Provata sul campo, la funzione non
    /// è scattata: una correzione di data del tipo «il 15, anzi no il 17» è
    /// uscita con la correzione ancora dentro. Due cose mancavano, e nessuna
    /// delle due si vedeva sul banco sintetico:
    ///
    /// · il marcatore vero è **«anzi no»**, due parole, e va provato PRIMA di
    ///   «anzi» secco, per la stessa ragione per cui i comandi parlati si
    ///   ordinano dal più lungo — altrimenti il corto vince e l'ancora cerca la
    ///   ripetizione partendo da «no», che non è mai stato detto prima;
    /// · l'ancora chiedeva una parola di **almeno cinque lettere** nel tratto
    ///   ritrattato, e «il 15» non ne ha nessuna. È la guardia che protegge
    ///   «non è male, anzi è ottimo» (dove «male» ne ha quattro), quindi non si
    ///   allarga: si affianca col **paio di numeri allineati**, che è un segnale
    ///   stretto e proprio del suo uso vero (date, ore, quantità).
    @Test func rAggRisolveLeCorrezioniDiData() {
        // L'attacco a vuoto se ne va INTERO insieme alla correzione risolta.
        // La maiuscola arriva dopo, da `capitalizeSentences`.
        #expect(SpeechRepairs.rAgg("Allora diciamo che il 15, anzi no il 17, parte il corso di nuoto.")
            == "il 17, parte il corso di nuoto.")
        #expect(SpeechRepairs.rAgg("ci vediamo alle 8 anzi no alle 9 davanti al bar")
            == "ci vediamo alle 9 davanti al bar")
        #expect(SpeechRepairs.rAgg("ne servono 12 anzi 20 per finire")
            == "ne servono 20 per finire")
    }

    /// I poli negativi del paio di numeri: due cifre vicine a un marcatore NON
    /// bastano se non c'è la ripetizione dell'attacco.
    @Test func ilPaioDiNumeriNonSfondaIPoli() {
        #expect(SpeechRepairs.rAgg("non è male, anzi è ottimo direi")
            == "non è male, anzi è ottimo direi")
        #expect(SpeechRepairs.rAgg("erano in 3, anzi era pieno di gente")
            == "erano in 3, anzi era pieno di gente")
    }
}

/// **Le parole che sono anche parole.**
///
/// Il 2026-08-18 due dettature vere sono uscite mutilate: «Allora diciamo che
/// il 15…» → «Allora che il 15…», e «…perché? cioè noi abbiamo messo…» →
/// «…perché? Noi abbiamo messo…». Nessuna delle due è colpa delle regole di
/// riparazione: la lista dei filler di `RuleBasedFormatter` cancellava
/// «diciamo» e «cioè» con una sostituzione cieca, senza guardare il contorno.
///
/// È **esattamente** la classe di difetto che questo file aveva già imparato e
/// riparato per «punto» e «virgola», col commento che lo diceva: *una guardia
/// che copre un membro di una classe è una guardia che qualcuno deve
/// ricordarsi di copiare*. Nessuno l'aveva copiata qui.
///
/// Il censimento sul suo archivio vero (174 righe) aveva già misurato la
/// risposta: «ok» 9, «allora» 8, «tipo» 3, «diciamo» 2, «cioè» 1, **tenute il
/// 100% delle volte**. Restano solo i filler che in italiano non sono mai
/// parole.
struct FillerListTests {

    /// Il percorso VERO, non un pezzo estratto: `format` è quello che gira su
    /// ogni dettatura quando il modo è a regole.
    private func ripulisci(_ s: String, _ lang: Language) async -> String {
        await RuleBasedFormatter().format(
            s, context: FormattingContext(language: lang, frontmostBundleID: nil))
    }

    /// **L'invariante strutturale, ed è il cancello che conta.**
    ///
    /// «La frase non deve restare sgrammaticata» non si verifica a macchina:
    /// servirebbe un correttore vero, cioè i secondi che abbiamo appena tolto.
    /// Quindi non si controlla il risultato, **si vincola l'operazione**: si
    /// tolgono solo unità intere, mai un pezzo preso da dentro qualcosa. Se non
    /// rimuovi mai il mezzo di niente, «Allora che» non può nascere — e nemmeno
    /// i suoi fratelli, che sono quelli che un divieto sul sintomo non vede.
    ///
    /// I casi qui sotto vengono tutti dal suo parlato vero del 2026-08-18.
    @Test func nessunFrammentoNasceDaUnaRimozioneParziale() {
        // L'attacco intero, o niente.
        #expect(SpeechRepairs.rAgg("Allora diciamo che oltre a questo la cartella resta grande")
            == "oltre a questo la cartella resta grande")
        // «tipo» dentro «quel tipo di servizio» faceva il suo mestiere: intatto.
        #expect(SpeechRepairs.rAgg("quel tipo di attrezzo o pensi ad altro")
            == "quel tipo di attrezzo o pensi ad altro")
        #expect(SpeechRepairs.rAgg("per il mio tipo di scrivania può bastare")
            == "per il mio tipo di scrivania può bastare")
        // «diciamo» come OGGETTO del verbo, non come attacco: intatto.
        #expect(SpeechRepairs.rAgg("è giusto che abbia scritto diciamo, però avrebbe dovuto scrivere altro")
            == "è giusto che abbia scritto diciamo, però avrebbe dovuto scrivere altro")
    }

    @Test func leParoleLessicaliItalianeSopravvivono() async {
        // «diciamo» quando FA un mestiere nella frase resta; l'attacco a vuoto
        // «allora diciamo che» invece se ne va intero, ed è quello che voleva.
        #expect(await ripulisci("È giusto che abbia scritto diciamo, però manca altro.", .italian)
            .contains("scritto diciamo"))
        #expect(!(await ripulisci("Allora diciamo che il 15 parte il corso di nuoto.", .italian))
            .lowercased().contains("allora che"))
        #expect(await ripulisci("Non ha aperto, cioè noi avevamo scelto un modo.", .italian)
            .contains("cioè noi"))
        #expect(await ripulisci("Che tipo di file è questo?", .italian).contains("tipo di file"))
        #expect(await ripulisci("Praticamente non funziona più niente.", .italian)
            .lowercased().contains("praticamente"))
        #expect(await ripulisci("Insomma alla fine ha retto.", .italian).lowercased().contains("insomma"))
    }

    @Test func iFillerVeriSpariscono() async {
        let it = await ripulisci("Ehm, il file non si apre.", .italian)
        let en = await ripulisci("Um, the file will not open.", .english)
        let fr = await ripulisci("Euh, le fichier ne s'ouvre pas.", .french)
        #expect(!it.lowercased().contains("ehm"))
        #expect(!en.lowercased().contains("um,"))
        #expect(!fr.lowercased().contains("euh"))
    }

    /// La stessa classe nelle altre due lingue: `like` in inglese e `quoi` in
    /// francese sono parole comuni, e cancellarle a vista rovina una frase
    /// normale a chiunque non sia lui.
    @Test func laStessaClasseNelleAltreLingue() async {
        #expect(await ripulisci("I like this kind of file, you know.", .english)
            .lowercased().contains("like this"))
        #expect(await ripulisci("Je ne sais pas quoi faire du coup.", .french)
            .lowercased().contains("quoi faire"))
    }
}
