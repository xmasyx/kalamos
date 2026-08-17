import Foundation
import Testing
@testable import Kalamos

/// Il volume del riascolto oltre l'originale.
///
/// Sua richiesta, 2026-08-17: «spesso le mie registrazioni si sentono male».
/// Tutto quello di cui la matematica può essere sbagliata sta in `Guadagno`, che
/// è puro: un test che dovesse aprire un dispositivo audio per controllare che
/// ×2 fa +6 dB starebbe misurando la macchina.
@Suite("Guadagno — alzare il volume senza distorcere")
struct GuadagnoTests {

    /// Un seno di ampiezza `a`, un secondo a 16 kHz.
    private func seno(_ a: Float) -> [Float] {
        (0 ..< 16_000).map { a * Float(sin(2 * .pi * 1_000 * Double($0) / 16_000)) }
    }

    /// **I due poli che il brief ha chiesto: un file piano sale, un file forte non
    /// satura.**
    @Test("Un file piano sale davvero, un file già pieno non viene toccato")
    func iDuePoli() {
        // Piano: il picco tipico del suo archivio è −20,6 dBFS.
        let piano = seno(0.09)
        let spazioPiano = Guadagno.spazio(picco: Guadagno.picco(piano))
        #expect(spazioPiano > 15, "un file piano deve avere spinta da dare: \(spazioPiano) dB")
        let spinto = Guadagno.applica(piano, dB: spazioPiano)
        let picco = Guadagno.picco(spinto)
        #expect(picco > Guadagno.picco(piano) * 5, "non è salito abbastanza: \(picco)")
        #expect(picco <= 1.0, "ha sfondato lo zero: \(picco)")

        // Forte: già a fondo scala, non c'è niente da dare e non si finge di darlo.
        let forte = seno(1.0)
        #expect(Guadagno.spazio(picco: Guadagno.picco(forte)) == 0)
        #expect(Guadagno.applica(forte, dB: 0) == forte, "a zero il suono nudo deve restare identico")
    }

    /// **Il vincolo del brief: il picco in uscita non supera mai 0 dBFS.**
    ///
    /// Spazzata su tutte le quote e su una popolazione di picchi che copre il suo
    /// archivio, dal più piano al clippato. Un solo esempio avrebbe potuto essere
    /// quello fortunato.
    @Test("Il picco in uscita non supera mai lo zero, a nessuna quota")
    func maiSopraLoZero() {
        for ampiezza in [Float](stride(from: 0.02, through: 1.0, by: 0.02)) {
            let s = seno(ampiezza)
            let spazio = Guadagno.spazio(picco: Guadagno.picco(s))
            for q in Guadagno.quote {
                let out = Guadagno.applica(s, dB: Guadagno.dB(perQuota: q, spazio: spazio))
                #expect(Guadagno.picco(out) <= 1.0,
                        "ampiezza \(ampiezza) quota \(q)%: picco \(Guadagno.picco(out))")
            }
        }
    }

    /// **Le quattro pastiglie sono quattro gradini UGUALI all'orecchio.**
    ///
    /// È la richiesta esplicita del brief: «non quattro numeri lineari sul guadagno
    /// lineare che all'ascolto danno tre gradini uguali e uno enorme». Passi uguali
    /// in dB sono passi uguali all'orecchio, e il polo negativo è la scala lineare
    /// sull'ampiezza, che deve risultare SBILANCIATA.
    @Test("I gradini sono uguali in dB, non nell'ampiezza")
    func iGradiniSonoUguali() {
        let spazio: Float = 20
        let dB = Guadagno.quote.map { Guadagno.dB(perQuota: $0, spazio: spazio) }
        let passi = zip(dB.dropFirst(), dB).map { $0 - $1 }
        #expect(passi.allSatisfy { abs($0 - passi[0]) < 0.001 }, "gradini in dB diversi: \(passi)")

        // Il polo: le stesse percentuali sul guadagno LINEARE danno gradini in dB
        // molto diversi fra loro — un salto grosso e poi tre quasi uguali.
        let massimo = Guadagno.lineare(dB: spazio)
        let lineari = Guadagno.quote.map { 1 + (massimo - 1) * Float($0) / 100 }
            .map { 20 * log10($0) }
        let passiLineari = zip(lineari.dropFirst(), lineari).map { $0 - $1 }
        #expect(passiLineari.max()! > passiLineari.min()! * 2,
                "la scala lineare non risulta sbilanciata: il confronto non misura niente")
    }

    /// Il limitatore: identico sotto il ginocchio, limitato sopra, e mai oltre uno.
    ///
    /// Serve un test suo perché con la scala legata allo spazio **il limitatore non
    /// entra mai in funzione** — il che è il disegno giusto, ma vuol dire che lo
    /// 0,000% di distorsione misurato sull'audio vero non dice niente su di lui.
    /// Questa è la rete sotto, e va provata a parte.
    @Test("Il limitatore non tocca niente sotto il ginocchio e non sfonda mai sopra")
    func ilLimitatore() {
        for x in [Float](stride(from: -Guadagno.ginocchio, through: Guadagno.ginocchio, by: 0.05)) {
            #expect(Guadagno.limita(x) == x, "ha toccato \(x), che sta sotto il ginocchio")
        }
        for x in [Float]([1, 2, 5, 20, 100, -1, -2, -5, -20, -100]) {
            #expect(abs(Guadagno.limita(x)) < 1.0, "\(x) è uscito a \(Guadagno.limita(x))")
            #expect(abs(Guadagno.limita(x)) > Guadagno.ginocchio, "\(x) è stato schiacciato sotto il ginocchio")
        }
        // Continuo al ginocchio: uno spigolo lì si sente come asprezza molto prima
        // di comparire in una misura di distorsione.
        let sotto = Guadagno.limita(Guadagno.ginocchio - 0.0001)
        let sopra = Guadagno.limita(Guadagno.ginocchio + 0.0001)
        #expect(abs(sopra - sotto) < 0.001, "salto al ginocchio: \(sotto) → \(sopra)")
    }

    /// Le due viste dello stesso valore: la pastiglia si accende sul suo dB, e fra
    /// due pastiglie non se ne accende nessuna.
    @MainActor
    @Test("Pastiglie e slider sono due viste di un valore solo")
    func dueVisteUnValore() {
        let spazio: Float = 16
        for q in Guadagno.quote {
            #expect(Guadagno.quota(perDB: Guadagno.dB(perQuota: q, spazio: spazio), spazio: spazio) == q)
        }
        // In mezzo: nessuna accesa. È un'informazione, non un buco — una pastiglia
        // accesa su un valore che non è il suo mentirebbe mentre lui regola.
        #expect(Guadagno.quota(perDB: 6, spazio: spazio) == nil)
        #expect(Guadagno.etichetta(0) != Guadagno.etichetta(6),
                "il suono nudo dev'essere riconoscibile dall'etichetta")
    }
}
