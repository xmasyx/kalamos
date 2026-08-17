import Foundation
import Testing
@testable import Kalamos

/// **«Elimina vuote» piantava l'app, e la sonda è un numero.**
///
/// Segnalazione dal campo, 2026-08-18: premendo il bottone Kalamos smetteva di
/// rispondere, e non usciva nemmeno dal menu di sistema — è dovuto intervenire con
/// `kill -9`. Quel dettaglio è la diagnosi: un'app che non risponde non riceve
/// nemmeno la richiesta gentile di terminare, quindi il main thread non stava
/// tornando MAI al ciclo degli eventi.
///
/// La causa non era una riga lenta, era la forma: un ciclo che per **ogni** riga
/// da buttare ricalcolava l'elenco visibile (`visible`, O(n) con la ricerca
/// dentro), cercava la riga successiva (`dopoLEliminazione`, O(n)) e mutava
/// l'elenco pubblicato. Con B righe da eliminare su N totali si paga O(B×N) e si
/// ridisegna B volte, tutto senza respirare.
///
/// Questi test misurano quella forma contro quella nuova. **Il polo negativo è il
/// codice di prima**, riprodotto qui sotto per intero: se un giorno la riparazione
/// venisse annullata, `laFormaVecchiaEDavveroQuadratica` continuerebbe a passare e
/// `laFormaNuovaEMoltoPiuVeloce` diventerebbe rosso.
@Suite("Elimina vuote — il blocco totale, misurato")
struct BulkDiscardTests {

    /// Un archivio finto: `n` righe, di cui una ogni due è vuota.
    private func archivio(_ n: Int) -> [DictationEntry] {
        (0..<n).map { i in
            DictationEntry(
                wav: URL(fileURLWithPath: "/tmp/finto/2026\(String(format: "%04d", i)).wav"),
                started: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                details: DictationDetails(
                    duration: 1, language: "it",
                    text: i % 2 == 0 ? "" : "parole numero \(i)",
                    corrected: false, suspect: false, settledAt: nil))
        }
    }

    /// La forma di prima: un giro completo di ricalcolo per ogni riga buttata.
    /// Ricopiata apposta — è un polo negativo, e un polo negativo deve continuare
    /// a comportarsi male anche quando il codice vero è stato riparato.
    private func formaVecchia(_ entries: [DictationEntry], da buttare: [DictationEntry]) -> [DictationEntry] {
        var correnti = entries
        for e in buttare {
            let visibili = DictationIndex.visible(correnti, filter: .all, query: "")
            _ = DictationIndex.dopoLEliminazione(di: e.wav, in: visibili)
            correnti.removeAll { $0.wav == e.wav }
        }
        return correnti
    }

    private func cronometra(_ blocco: () -> Void) -> Double {
        let t = Date()
        blocco()
        return Date().timeIntervalSince(t)
    }

    // MARK: - Il difetto, misurato

    /// La forma vecchia cresce col quadrato: raddoppiando l'archivio il tempo va
    /// **molto** più che al doppio. Se un giorno questo test smettesse di vedere la
    /// crescita, vorrebbe dire che sta misurando qualcos'altro.
    @Test func laFormaVecchiaEDavveroQuadratica() {
        let piccolo = archivio(400)
        let grande = archivio(800)
        let tPiccolo = cronometra { _ = formaVecchia(piccolo, da: DictationIndex.blanks(piccolo)) }
        let tGrande = cronometra { _ = formaVecchia(grande, da: DictationIndex.blanks(grande)) }
        // Quadratico: 2× le righe → circa 4× il tempo. Si pretende almeno 2,5×,
        // che una crescita lineare non potrebbe mai produrre.
        #expect(tGrande > tPiccolo * 2.5,
                "vecchia: \(Int(tPiccolo * 1000)) ms → \(Int(tGrande * 1000)) ms")
    }

    /// **Il numero che conta.** Su 2000 righe con 1000 vuote — sotto il tetto di
    /// 100000 che questo archivio permette — la forma nuova deve stare almeno
    /// venti volte sotto la vecchia.
    @Test func laFormaNuovaEMoltoPiuVeloce() {
        let entries = archivio(2000)
        let vuote = DictationIndex.blanks(entries)
        #expect(vuote.count == 1000)

        let tVecchia = cronometra { _ = formaVecchia(entries, da: vuote) }
        let tNuova = cronometra { _ = DictationIndex.senza(vuote, in: entries) }

        #expect(tNuova * 20 < tVecchia,
                "vecchia \(Int(tVecchia * 1000)) ms · nuova \(Int(tNuova * 1000)) ms")
    }

    // MARK: - E il risultato è lo stesso

    /// La velocità non vale niente se il risultato cambia: le due forme devono
    /// lasciare esattamente le stesse righe, nello stesso ordine.
    @Test func leDueFormeLascianoLoStessoElenco() {
        let entries = archivio(200)
        let vuote = DictationIndex.blanks(entries)
        let vecchia = formaVecchia(entries, da: vuote).map(\.wav)
        let nuova = DictationIndex.senza(vuote, in: entries).map(\.wav)
        #expect(vecchia == nuova)
        #expect(nuova.count == 100)
    }

    /// Buttare un lotto vuoto non deve toccare niente, e buttare righe che non
    /// sono in elenco non deve togliere quelle che ci sono.
    @Test func iCasiLimiteNonRomponoLElenco() {
        let entries = archivio(10)
        #expect(DictationIndex.senza([], in: entries).count == 10)

        let estranea = DictationEntry(
            wav: URL(fileURLWithPath: "/tmp/finto/altrove.wav"),
            started: Date(), details: nil)
        #expect(DictationIndex.senza([estranea], in: entries).count == 10)
    }

    /// La selezione dopo un'eliminazione in blocco si calcola UNA volta, e deve
    /// atterrare su una riga che sopravvive — mai su una appena buttata.
    @Test func laSelezioneAtterraSuUnaRigaViva() {
        let entries = archivio(10)
        let vuote = DictationIndex.blanks(entries)          // gli indici pari
        let rimaste = DictationIndex.senza(vuote, in: entries)

        // Selezione su una riga che sta per sparire: deve spostarsi.
        let dopo = DictationIndex.dopoIlLotto(vuote, partendoDa: vuote[0].wav, in: entries)
        #expect(dopo != nil)
        #expect(rimaste.contains { $0.wav == dopo })
        #expect(vuote.contains { $0.wav == dopo } == false)

        // Selezione su una riga che sopravvive: non si muove.
        let viva = rimaste[3].wav
        #expect(DictationIndex.dopoIlLotto(vuote, partendoDa: viva, in: entries) == viva)
    }
}
