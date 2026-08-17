import Foundation
import Testing
@testable import Kalamos

/// The list of dictations: what it reads out of a sidecar, and what it shows.
///
/// The rows arrive before their contents do, so every question here has a third
/// answer besides yes and no — *not read yet* — and getting that one wrong is
/// how a list ends up lying about an archive while it loads.
@Suite("DictationIndex — l'archivio come elenco")
struct DictationIndexTests {

    static let header = """
    durata audio: 20.6s · microfono aperto: 20.7s
    lingua: it
    """

    // MARK: reading the sidecar

    @Test("Dal nome del file esce il momento della registrazione")
    func stemToDate() {
        let d = DictationIndex.date(fromStem: "20260815-151553")
        #expect(d != nil)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        #expect(c.year == 2026 && c.month == 8 && c.day == 15)
        #expect(c.hour == 15 && c.minute == 15 && c.second == 53)
    }

    /// The negative pole: the folder holds `.txt` files, `.DS_Store`, and one day
    /// something a person dropped in. Anything that is not one of ours must not
    /// become a row dated 1 January 2001.
    @Test("Un nome che non è una data non diventa una riga")
    func junkNamesAreRejected() {
        #expect(DictationIndex.date(fromStem: "corpus") == nil)
        #expect(DictationIndex.date(fromStem: ".DS_Store") == nil)
        #expect(DictationIndex.date(fromStem: "20260815") == nil)
        #expect(DictationIndex.date(fromStem: "") == nil)
    }

    @Test("Durata e lingua si leggono dall'intestazione")
    func headerParsing() {
        #expect(DictationIndex.duration(inHeader: Self.header) == 20.6)
        #expect(DictationIndex.language(inHeader: Self.header) == "it")
    }

    /// The oldest sidecars predate both fields, and a recording whose write was
    /// cut short has a truncated one. Neither is an error worth showing.
    @Test("Un'intestazione che non li ha non inventa numeri")
    func headerMissingFields() {
        #expect(DictationIndex.duration(inHeader: "") == nil)
        #expect(DictationIndex.language(inHeader: "") == nil)
        #expect(DictationIndex.duration(inHeader: "durata audio: ") == nil)
        #expect(DictationIndex.language(inHeader: "lingua italiana: sì") == nil)
    }

    @Test("La durata si scrive in secondi interi, e sparisce se non c'è")
    func lengthLabel() {
        #expect(DictationIndex.lengthLabel(20.6) == "21 s")
        #expect(DictationIndex.lengthLabel(2.8) == "3 s")
        #expect(DictationIndex.lengthLabel(nil) == "")
        #expect(DictationIndex.lengthLabel(0) == "")
    }

    // MARK: what the list shows

    static func entry(_ stem: String, text: String? = nil,
                      corrected: Bool = false, suspect: Bool = false) -> DictationEntry {
        let url = URL(fileURLWithPath: "/tmp/\(stem).wav")
        let date = DictationIndex.date(fromStem: stem) ?? Date()
        guard let text else { return DictationEntry(wav: url, started: date, details: nil) }
        return DictationEntry(wav: url, started: date,
                              details: DictationDetails(duration: 12, language: "it", text: text,
                                                        corrected: corrected, suspect: suspect))
    }

    static let corpus = [
        entry("20260815-151553", text: "per lifeos da vedere i gestionali che avevamo sviluppato"),
        entry("20260815-151312", text: "e in che modo la coda di lavoro entrerebbe all'interno", corrected: true),
        entry("20260815-151106", text: "installiamo anche questa", suspect: true),
        entry("20260814-130048"),   // still loading
    ]

    @Test("Il filtro «da correggere» tiene anche le righe non ancora lette")
    func todoKeepsUnread() {
        let todo = DictationIndex.visible(Self.corpus, filter: .todo, query: "")
        #expect(todo.count == 3)
        #expect(todo.contains { !$0.isHydrated })
    }

    /// The other pole of the same decision: "already fixed" is a claim, and a row
    /// nobody has read cannot make it.
    @Test("Il filtro «corrette» NON tiene le righe non ancora lette")
    func doneExcludesUnread() {
        let done = DictationIndex.visible(Self.corpus, filter: .done, query: "")
        #expect(done.count == 1)
        #expect(done.first?.details?.corrected == true)
    }

    @Test("Tutte vuol dire tutte, comprese quelle che stanno ancora caricando")
    func allKeepsEverything() {
        #expect(DictationIndex.visible(Self.corpus, filter: .all, query: "").count == 4)
    }

    @Test("La ricerca guarda il testo, senza distinguere maiuscole")
    func searchMatchesText() {
        #expect(DictationIndex.visible(Self.corpus, filter: .all, query: "gestionali").count == 1)
        #expect(DictationIndex.visible(Self.corpus, filter: .all, query: "CODA DI LAVORO").count == 1)
        #expect(DictationIndex.visible(Self.corpus, filter: .all, query: "  ").count == 4)
    }

    /// A row whose text has not arrived cannot match, and must not be shown as if
    /// it had: the answer would change under his eyes as the archive finishes
    /// loading, which reads as a search that does not work.
    @Test("Una riga non ancora letta non risponde a una ricerca")
    func searchSkipsUnread() {
        let hits = DictationIndex.visible(Self.corpus, filter: .all, query: "e")
        #expect(hits.allSatisfy { $0.isHydrated })
        #expect(DictationIndex.visible(Self.corpus, filter: .all, query: "zzzz").isEmpty)
    }

    @Test("Filtro e ricerca lavorano insieme, non uno al posto dell'altro")
    func filterAndSearchCompose() {
        let hits = DictationIndex.visible(Self.corpus, filter: .done, query: "coda di lavoro")
        #expect(hits.count == 1)
        #expect(DictationIndex.visible(Self.corpus, filter: .done, query: "gestionali").isEmpty)
    }

    // MARK: le sistemate si archiviano da sole

    static func settled(_ stem: String, ago: TimeInterval, now: Date) -> DictationEntry {
        let url = URL(fileURLWithPath: "/tmp/\(stem).wav")
        return DictationEntry(wav: url,
                              started: DictationIndex.date(fromStem: stem) ?? now,
                              details: DictationDetails(duration: 10, language: "it",
                                                        text: "frase sistemata",
                                                        corrected: true, suspect: false,
                                                        settledAt: now.addingTimeInterval(-ago)))
    }

    /// Sistemata ieri l'altro → esce da «Tutte»; sistemata un'ora fa → resta.
    /// In entrambi i casi «Sistemate» le tiene, e la ricerca le trova: un
    /// cassetto da cui una riga sparisce del tutto non è un cassetto, è un buco.
    @Test("Una sistemata vecchia lascia «Tutte» ma non il cassetto né la ricerca")
    func settledRowsGetFiled() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let rows = [Self.settled("20260810-090000", ago: 200_000, now: now),
                    Self.settled("20260815-090000", ago: 3600, now: now)]

        let tutte = DictationIndex.visible(rows, filter: .all, query: "", now: now)
        #expect(tutte.count == 1)
        #expect(tutte.first?.details?.settledAt == now.addingTimeInterval(-3600))

        #expect(DictationIndex.visible(rows, filter: .done, query: "", now: now).count == 2)
        #expect(DictationIndex.visible(rows, filter: .all, query: "sistemata", now: now).count == 2)
    }

    @Test("La data di sistemazione si legge dall'ULTIMA intestazione VERITÀ")
    func settledDateParsesLastHeading() throws {
        let sidecar = """
        GREZZO:
        ciao

        VERITÀ (2026-08-12 10:00):
        prima versione

        VERITÀ (2026-08-15 22:52, CONFERMATA):
        seconda versione
        """
        let d = try #require(DictationIndex.settledDate(inSidecar: sidecar))
        let c = Calendar.current.dateComponents([.day, .hour, .minute], from: d)
        #expect(c.day == 15 && c.hour == 22 && c.minute == 52)
        #expect(DictationIndex.settledDate(inSidecar: "GREZZO:\nciao") == nil)
    }

    // MARK: - Le vuote, che adesso si possono buttare

    private static func riga(_ stem: String, testo: String?) -> DictationEntry {
        DictationEntry(
            wav: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            started: DictationIndex.date(fromStem: stem) ?? Date(),
            details: testo.map {
                DictationDetails(duration: 4, language: "it", text: $0,
                                 corrected: false, suspect: false, settledAt: nil)
            })
    }

    /// I due poli chiesti il 2026-08-16: **una vuota si riconosce, una con testo
    /// no.** Il bottone «Elimina» sulla riga scelta e la scopa «Elimina vuote (N)»
    /// leggono questa funzione, quindi qui si decide che cosa sparisce.
    @Test("Una dettatura senza parole è vuota, una con parole no")
    func blankIsOnlyTheOneWithNoWords() {
        #expect(DictationIndex.isBlank(Self.riga("20260816-145026", testo: "")))
        #expect(DictationIndex.isBlank(Self.riga("20260816-145027", testo: "   \n ")))
        #expect(!DictationIndex.isBlank(Self.riga("20260816-145028", testo: "una frase intera")))
        // Uno spazio non è niente; una parola sola sì.
        #expect(!DictationIndex.isBlank(Self.riga("20260816-145029", testo: "sì")))
    }

    /// **Il polo che vale più di tutti: una riga NON ANCORA LETTA dal disco non è
    /// vuota.**
    ///
    /// L'elenco si riempie a blocchi dopo che la finestra è già aperta, quindi per
    /// qualche istante ogni riga ha `details == nil`. Se quello contasse come
    /// vuoto, il bottone direbbe «Elimina vuote (138)» su un archivio intatto e un
    /// click lo cancellerebbe tutto. È l'unico modo in cui questa funzione può
    /// fare un danno irreversibile, ed è per questo che ha una prova sua.
    @Test("Una riga ancora da leggere non è vuota")
    func notYetReadIsNotBlank() {
        let sospesa = Self.riga("20260816-145030", testo: nil)
        #expect(sospesa.details == nil)
        #expect(!DictationIndex.isBlank(sospesa))
        #expect(DictationIndex.blanks([sospesa]).isEmpty)
    }

    /// La scopa raccoglie tutte e sole le vuote fra quelle che ha davanti.
    @Test("La scopa conta le vuote dell'elenco, non quelle del disco")
    func blanksAreCountedOnWhatIsListed() {
        let righe = [Self.riga("20260816-150000", testo: "prima"),
                     Self.riga("20260816-150001", testo: ""),
                     Self.riga("20260816-150002", testo: nil),
                     Self.riga("20260816-150003", testo: "")]
        let vuote = DictationIndex.blanks(righe)
        #expect(vuote.count == 2)
        #expect(vuote.allSatisfy { $0.details?.text.isEmpty == true })
    }

    // MARK: - Dove atterra la selezione quando una riga è finita

    /// Righe finte con nomi ordinati, per provare l'avanzamento senza toccare il
    /// disco: qui interessa la POSIZIONE nell'elenco, non cosa c'è nei file.
    private func righe(_ nomi: [String]) -> [DictationEntry] {
        nomi.map { DictationEntry(wav: URL(fileURLWithPath: "/tmp/\($0).wav"),
                                  started: Date(timeIntervalSince1970: 0), details: nil) }
    }

    /// **Sua richiesta, 2026-08-17**: «quando confermo deve passare alla nota
    /// successiva da verificare, allo stesso modo di quando elimino».
    ///
    /// I due poli sono quelli che il brief ha chiesto: in mezzo all'elenco la
    /// selezione avanza di una riga; sull'ultima non si sposta, e soprattutto non
    /// torna al principio — che è il difetto che l'eliminazione aveva.
    @Test("Confermata una riga, la selezione passa alla successiva")
    func laSelezioneAvanzaDiUnaRiga() {
        let r = righe(["a", "b", "c"])
        #expect(DictationIndex.prossima(dopo: r[0].wav, in: r) == r[1].wav)
        #expect(DictationIndex.prossima(dopo: r[1].wav, in: r) == r[2].wav)
    }

    @Test("Sull'ultima riga la selezione non si sposta")
    func sullUltimaNonSiSposta() {
        let r = righe(["a", "b", "c"])
        #expect(DictationIndex.prossima(dopo: r[2].wav, in: r) == nil,
                "sull'ultima deve dire «nessuna successiva», non riportare in cima")
        // Il polo che conta davvero: nil NON deve essere la prima riga. È il
        // difetto che `discard` aveva, e un test che guardasse solo «non è la
        // seconda» lo avrebbe lasciato passare.
        #expect(DictationIndex.prossima(dopo: r[2].wav, in: r) != r[0].wav)
        // Una riga che non è in elenco non produce un salto: succede se si chiede
        // dopo che l'elenco si è aggiornato, ed è il caso in cui si resta fermi.
        #expect(DictationIndex.prossima(dopo: righe(["z"])[0].wav, in: r) == nil)
    }

    /// «Successiva» vuol dire successiva fra le righe VISIBILI, cioè rispettando
    /// filtro e ricerca — non la successiva nell'archivio intero.
    @Test("La successiva è quella visibile, non quella dell'archivio")
    func laSuccessivaRispettaIlFiltro() {
        let tutte = righe(["a", "b", "c", "d"])
        let visibili = [tutte[0], tutte[2]]      // b e d nascoste dal filtro
        #expect(DictationIndex.prossima(dopo: tutte[0].wav, in: visibili) == tutte[2].wav,
                "ha saltato a una riga che lui non ha sullo schermo")
        // Il polo: sull'elenco intero la risposta sarebbe un'altra, quindi il test
        // sta misurando davvero il filtro e non una coincidenza.
        #expect(DictationIndex.prossima(dopo: tutte[0].wav, in: tutte) == tutte[1].wav)
    }

    /// L'eliminazione ha un vincolo in più: restare dov'è è impossibile, il file
    /// non c'è più. Quindi sull'ultima torna indietro di una invece di saltare in
    /// cima all'elenco, che è quello che faceva fino al 2026-08-17.
    @Test("Eliminata l'ultima riga, si torna a quella prima e non in cima")
    func lEliminazioneTornaIndietroNonInCima() {
        let r = righe(["a", "b", "c"])
        #expect(DictationIndex.dopoLEliminazione(di: r[0].wav, in: r) == r[1].wav)
        #expect(DictationIndex.dopoLEliminazione(di: r[2].wav, in: r) == r[1].wav,
                "sull'ultima è saltata al principio invece che alla precedente")
        // Elenco di una riga sola: non resta niente da selezionare.
        let sola = righe(["solo"])
        #expect(DictationIndex.dopoLEliminazione(di: sola[0].wav, in: sola) == nil)
    }


    // MARK: - Il cestino sulla riga

    /// **Sua richiesta, 2026-08-17: il cestino sulla riga, solo sulle vuote.**
    ///
    /// I due poli sono quelli del brief — la riga vuota lo mostra, quella con
    /// testo no — più il terzo che vale più di entrambi: **una riga non ancora
    /// letta dal disco NON è vuota**, quindi finché non si sa non si offre di
    /// cancellare. È la stessa guardia di `notYetReadIsNotBlank`, e qui protegge
    /// un gesto distruttivo invece di un'etichetta.
    @Test("Il cestino sta solo sulle righe vuote, e mai su una non ancora letta")
    func ilCestinoSoloSulleVuote() {
        let url = URL(fileURLWithPath: "/tmp/x.wav")
        func riga(_ d: DictationDetails?) -> DictationEntry {
            DictationEntry(wav: url, started: Date(timeIntervalSince1970: 0), details: d)
        }
        let vuota = riga(DictationDetails(duration: 4, language: "it", text: "", corrected: false, suspect: false, settledAt: nil))
        let piena = riga(DictationDetails(duration: 4, language: "it", text: "qualcosa che ha detto", corrected: false, suspect: false, settledAt: nil))
        let nonLetta = riga(nil)

        #expect(DictationIndex.isBlank(vuota), "la riga senza parole non risulta vuota")
        #expect(!DictationIndex.isBlank(piena), "una riga con testo non è vuota")
        #expect(!DictationIndex.isBlank(nonLetta),
                "una riga non ancora letta risulta vuota: il cestino comparirebbe su una registrazione che potrebbe avere parole")

        // E gli spazi non sono parole: una trascrizione di soli spazi è vuota.
        #expect(DictationIndex.isBlank(riga(DictationDetails(duration: 4, language: "it", text: "   \n  ", corrected: false, suspect: false, settledAt: nil))))
    }

}
