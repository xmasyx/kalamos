import AppKit

/// **L'isola sopravvive al cambio di schermata?**
///
/// Nasce dal secondo difetto visto sul campo il 2026-08-16, con le sue parole:
/// «quando passo da una schermata all'altra, il notch resti persistente con
/// l'onda che va, e non che compaia e scompaia... soprattutto con lo schermo
/// intero dà problemi».
///
/// **Che cosa questa sonda può provare, e che cosa no — va detto prima, perché è
/// la parte onesta.** Lo scorrimento fra due scrivanie è un gesto del sistema che
/// nessuno script fa partire senza le sue mani, e un filmato di uno spazio che
/// non cambia proverebbe soltanto che l'isola sta ferma quando niente si muove.
/// Quello che invece è sondabile, e che è la CAUSA di ciò che ha visto, sono i
/// permessi della finestra: `collectionBehavior` e il livello. Se quelli sono
/// giusti la persistenza è una proprietà del sistema, non del nostro codice; se
/// sono sbagliati, nessuna quantità di codice nostro la ottiene. Questa sonda
/// chiude la metà che si può chiudere, e il referto dichiara che la conferma
/// finale dello swipe è del suo campo.
///
/// **Si rilegge dalla FINESTRA VIVA e non dalla costante.** Una costante giusta e
/// un `init` che si scorda di applicarla sono indistinguibili leggendo il
/// sorgente, e sono esattamente il guasto che lascia l'isola a sparire.
enum SondaPannello {

    struct Esito {
        let comportamento: NSWindow.CollectionBehavior
        let livello: NSWindow.Level
        let nascondeQuandoInattiva: Bool

        var mancanti: [String] {
            var out: [String] = []
            if !comportamento.contains(.canJoinAllSpaces) { out.append("canJoinAllSpaces") }
            if !comportamento.contains(.fullScreenAuxiliary) { out.append("fullScreenAuxiliary") }
            if !comportamento.contains(.stationary) { out.append("stationary") }
            return out
        }
        /// Il livello dev'essere almeno quello della barra di stato: sotto, l'isola
        /// finisce dietro il contenuto di un'app a tutto schermo.
        var livelloBastante: Bool { livello.rawValue >= NSWindow.Level.statusBar.rawValue }
        var passa: Bool { mancanti.isEmpty && livelloBastante && !nascondeQuandoInattiva }

        var descrizione: String {
            let nomi = [
                (NSWindow.CollectionBehavior.canJoinAllSpaces, "canJoinAllSpaces"),
                (.fullScreenAuxiliary, "fullScreenAuxiliary"),
                (.stationary, "stationary"),
            ].filter { comportamento.contains($0.0) }.map(\.1)
            return """
            comportamento: [\(nomi.joined(separator: ", "))] (grezzo \(comportamento.rawValue))
            livello: \(livello.rawValue) (statusBar è \(NSWindow.Level.statusBar.rawValue))
            hidesOnDeactivate: \(nascondeQuandoInattiva)
            """
        }
    }

    /// `@MainActor` perché legge proprietà di una finestra, che sul main actor
    /// vivono: senza, il compilatore lo dice con tre avvisi e il codice resterebbe
    /// giusto per caso finché qualcuno non la chiama da un altro contesto.
    @MainActor
    static func esamina(_ finestra: NSWindow) -> Esito {
        Esito(comportamento: finestra.collectionBehavior,
              livello: finestra.level,
              nascondeQuandoInattiva: finestra.hidesOnDeactivate)
    }
}
