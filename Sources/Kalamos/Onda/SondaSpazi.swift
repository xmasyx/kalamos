import AppKit
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// SondaSpazi — «il notch resta fermo quando cambio pagina?»
//
// Sue parole, 2026-08-17: «il notch in realtà non è che resti veramente fermo, da
// bordo a bordo, quando cambio pagina». Il giorno prima erano stati aggiunti i tre
// flag di `IslandPanel.comportamentoPersistente` e `SondaPannello` li rilegge dalla
// finestra viva, verde. **Quindi i flag erano necessari e non sufficienti**, e una
// sonda che li ricontrolla non può aggiungere niente: risponde alla domanda «sono
// dichiarati?» mentre la domanda è «la finestra si è mossa?».
//
// Questa risponde alla seconda, e la risposta arriva da due misure indipendenti
// che si controllano a vicenda:
//
//   · l'ANAGRAFE — `NSWindow.frame` (cosa crede AppKit) accanto ai `kCGWindowBounds`
//     letti dal WindowServer (cosa crede il compositore). Divergono esattamente nel
//     caso interessante: se AppKit dice fermo e il WindowServer dice fermo ma i
//     pixel si muovono, allora a muoversi è il LIVELLO su cui la finestra è
//     appoggiata, non la finestra;
//   · i PIXEL — il riquadro dell'isola, fotogramma per fotogramma, dal filmato.
//
// **Il limite, misurato e non temuto (vedi `--sonda-spazi --diagnosi`).** Il
// passaggio fra due scrivanie normali si comanda con ctrl-freccia, e il
// WindowServer IGNORA i tasti sintetici per quella scorciatoia: postando
// ctrl-destra da `CGEvent` non arriva nessun `activeSpaceDidChange`, mentre lo
// stesso ascoltatore ne registra tre quando la transizione è vera. Il polo
// positivo che lo dimostra è `toggleFullScreen`, che è API pubblica, produce una
// transizione di spazio VERA e non chiede l'Accessibilità: è la transizione che
// questa sonda usa, ed è anche il caso che `fullScreenAuxiliary` esiste per
// coprire. Lo scorrimento con le dita fra due scrivanie resta suo.
// ─────────────────────────────────────────────────────────────────────────────

enum SondaSpazi {

    /// Quanti cambi di spazio sono stati annunciati finora.
    ///
    /// Stato del tipo e non variabile locale della sonda: la chiusura della
    /// notifica e quella dell'orologio sono due contesti concorrenti per il
    /// compilatore, e un `var` catturato da entrambe è un avviso di concorrenza
    /// legittimo. Isolata al main actor, che è dove entrambe girano davvero.
    @MainActor static var cambiOsservati = 0

    /// Una riga del registro: dove stava la finestra, secondo chi.
    struct Istante {
        let secondi: Double
        /// Cosa crede AppKit.
        let cornice: CGRect
        /// Cosa crede il WindowServer. `nil` quando la finestra non è nella lista,
        /// che durante una transizione è un dato e non un buco.
        let compositore: CGRect?
        let sullaScrivaniaAttiva: Bool
        /// Quanti cambi di spazio sono già stati annunciati a questo istante.
        let cambi: Int
    }

    /// I `kCGWindowBounds` di una finestra, dal WindowServer.
    ///
    /// **Non `.optionOnScreenOnly`**: quella lista contiene solo le finestre della
    /// scrivania corrente, quindi durante una transizione un'assenza vorrebbe dire
    /// due cose diverse — «è scivolata via» e «sto guardando l'altra scrivania» — e
    /// una sonda che confonde due cause è la sonda che manda a cercare il guasto
    /// dalla parte sbagliata. Con `.optionAll` l'assenza significa una cosa sola.
    static func compositore(numero: CGWindowID) -> CGRect? {
        guard let lista = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for voce in lista where (voce[kCGWindowNumber as String] as? CGWindowID) == numero {
            guard let b = voce[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Il referto: quanto si è mossa la finestra, secondo ciascuna delle due fonti.
    struct Referto {
        let istanti: [Istante]
        let cambiDiSpazio: Int
        let livello: Int
        /// Da quale secondo si comincia a credere ai numeri.
        ///
        /// **Senza questo la sonda misura sé stessa**, ed è successo al primo giro:
        /// un `IslandPanel` nasce a `NSRect(origin: .zero, …)` e viene messo al suo
        /// posto qualche giro di run loop dopo, quindi prendendo il PRIMO campione
        /// come riferimento lo spostamento risultava di 532 px — che è la
        /// collocazione iniziale, non la transizione. Il difetto vero stava sotto,
        /// ed era trenta volte più piccolo. È il caso da manuale dell'ingresso
        /// ricostruito male che produce un risultato plausibile e sbagliato
        /// (OperationalLessons, 2026-08-16).
        let assestamento: Double

        var assestati: [Istante] { istanti.filter { $0.secondi >= assestamento } }

        /// Il riferimento: la posizione MEDIANA dopo l'assestamento e prima che
        /// cominci a succedere qualcosa. Mediana e non media, perché è proprio
        /// l'escursione transitoria a essere il segnale e una media se la mangia.
        var riferimento: (x: CGFloat, y: CGFloat)? {
            let visti = assestati.compactMap(\.compositore)
            guard !visti.isEmpty else { return nil }
            let xs = visti.map(\.minX).sorted(), ys = visti.map(\.minY).sorted()
            return (xs[xs.count / 2], ys[ys.count / 2])
        }

        /// Lo spostamento massimo dell'angolo, secondo AppKit.
        var scartoAppKit: CGFloat {
            let visti = assestati.map(\.cornice)
            guard let primo = visti.first else { return 0 }
            return visti.map { max(abs($0.minX - primo.minX), abs($0.minY - primo.minY)) }.max() ?? 0
        }

        /// Lo stesso, secondo il WindowServer, e SOLO sugli istanti in cui la
        /// finestra era nella lista: mescolare i `nil` con gli zeri direbbe «ferma»
        /// per una finestra sparita, che è il falso verde peggiore qui dentro.
        var scartoCompositore: CGFloat {
            guard let rif = riferimento else { return 0 }
            return assestati.compactMap(\.compositore)
                .map { max(abs($0.minX - rif.x), abs($0.minY - rif.y)) }.max() ?? 0
        }

        /// Quando è avvenuto lo spostamento più grande — serve a distinguere «si è
        /// mossa durante la transizione» da «si è mossa in un momento qualunque».
        var quandoIlPeggio: Double {
            guard let rif = riferimento else { return 0 }
            return assestati
                .max(by: { a, b in
                    let da = a.compositore.map { max(abs($0.minX - rif.x), abs($0.minY - rif.y)) } ?? 0
                    let db = b.compositore.map { max(abs($0.minX - rif.x), abs($0.minY - rif.y)) } ?? 0
                    return da < db
                })?.secondi ?? 0
        }

        /// Gli istanti in cui il WindowServer non conosceva la finestra. Diverso da
        /// zero è di per sé il difetto: una finestra che sparisce dalla lista
        /// durante la transizione non è una finestra che «resta ferma».
        var istantiSenzaFinestra: Int { assestati.filter { $0.compositore == nil }.count }

        /// Gli istanti in cui la finestra non era sulla scrivania attiva. Con
        /// `canJoinAllSpaces` devono essere zero: è la definizione del flag.
        var istantiFuoriScrivania: Int { assestati.filter { !$0.sullaScrivaniaAttiva }.count }

        /// Quanti istanti la finestra ha passato spostata di più di un pixel: la
        /// DURATA del difetto, che è il numero che dice se lui può vederlo. Uno
        /// scarto grande per due fotogrammi e uno piccolo per mezzo secondo sono
        /// due cose diverse, e un massimo da solo le confonde.
        var istantiSpostati: Int {
            guard let rif = riferimento else { return 0 }
            return assestati.filter {
                guard let c = $0.compositore else { return false }
                return abs(c.minX - rif.x) > 1 || abs(c.minY - rif.y) > 1
            }.count
        }

        var testo: String {
            func riga(_ ok: Bool, _ nome: String, _ dettaglio: String) -> String {
                let steso = nome.count < 40 ? nome + String(repeating: " ", count: 40 - nome.count) : nome
                return "  \(ok ? "✓" : "✗") \(steso) \(dettaglio)"
            }
            let n = assestati.count
            return """
            istanti \(istanti.count) (assestati \(n), da \(String(format: "%.1f", assestamento)) s) \
            · cambi di spazio \(cambiDiSpazio) · livello \(livello)
            riferimento WindowServer: \(riferimento.map { String(format: "x %.0f y %.0f", $0.x, $0.y) } ?? "—")

            \(riga(cambiDiSpazio > 0, "la transizione è avvenuta davvero",
                   "\(cambiDiSpazio) cambi (senza questo, tutto il resto è aria)"))
            \(riga(scartoAppKit < 1, "AppKit non ha mosso la finestra",
                   String(format: "scarto massimo %.1f pt", scartoAppKit)))
            \(riga(scartoCompositore < 1, "il WindowServer non l'ha mossa",
                   String(format: "scarto massimo %.1f px, al secondo %.2f", scartoCompositore, quandoIlPeggio)))
            \(riga(istantiSpostati == 0, "e non l'ha mossa nemmeno per un attimo",
                   String(format: "%d istanti su %d (%.2f s)", istantiSpostati, n,
                          Double(istantiSpostati) / 60)))
            \(riga(istantiSenzaFinestra == 0, "non è mai sparita dalla lista",
                   "\(istantiSenzaFinestra) istanti su \(n)"))
            \(riga(istantiFuoriScrivania == 0, "sempre sulla scrivania attiva",
                   "\(istantiFuoriScrivania) istanti su \(n)"))
            """
        }

        /// **Il verde qui NON vuol dire che lui la vedrà ferma**, e va detto dove si
        /// legge il risultato invece che in un commento nel sorgente. Queste cinque
        /// righe misurano la GEOMETRIA della finestra: se il compositore trasla
        /// l'intero livello su cui la finestra è appoggiata, la finestra non si
        /// muove rispetto al livello e tutte e cinque restano verdi mentre i pixel
        /// scorrono. Quella domanda la risponde il filmato, e in ultima istanza il
        /// suo dito.
        var passa: Bool {
            cambiDiSpazio > 0 && scartoAppKit < 1 && scartoCompositore < 1
                && istantiSpostati == 0 && istantiSenzaFinestra == 0 && istantiFuoriScrivania == 0
        }
    }
}
