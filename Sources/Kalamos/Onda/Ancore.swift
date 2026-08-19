import AppKit

/// **Dove può stare l'isoletta, e come una posizione grezza diventa un NOME.**
///
/// Aritmetica pura, fuori da `IslandPanel` e senza attore, perché è l'unica
/// forma in cui i due poli si possono provare senza finestre e senza lo schermo
/// vero: una posizione che deve agganciarsi e una che non deve.
///
/// Il motivo per cui esiste non è la comodità, è la sopravvivenza. Delle
/// coordinate crude salvate su un monitor esterno, o su una risoluzione diversa,
/// rimettono la pillola fuori dallo schermo il giorno dopo; un nome no, perché
/// viene ricalcolato dalla geometria dello schermo che c'è adesso.
enum Ancore {
    /// Quanto sta sopra il bordo inferiore dell'**area visibile**, in punti.
    ///
    /// **Misurato sulla sua posizione vera il 19/08, non scelto a occhio, e il
    /// numero che gira nelle note è sbagliato di 74.** `defaults read
    /// com.kalamos.app` dà `waveCenter = "754 114"`; lo schermo è 1512 × 982 e
    /// il suo `visibleFrame` parte da y 74, cioè 74 punti di Dock. I 114 sono
    /// quindi contati dal bordo dello SCHERMO, e rispetto all'area visibile la
    /// pillola sta a **40**. Prendere il 114 e riferirlo al `visibleFrame`
    /// avrebbe alzato l'isola di 74 punti rispetto a dove ce l'ha davvero.
    ///
    /// **Fisso in punti e non in percentuale** (sua domanda del 18/08 sui
    /// monitor esterni): 40 punti restano la stessa distanza percepita su un 14",
    /// un 16" e un 5K, perché un punto è fisicamente più grande su un monitor
    /// meno denso; una percentuale dell'altezza la manderebbe nel terzo
    /// inferiore. Riferito all'area visibile e non allo schermo, così il Dock non
    /// ci finisce sotto quando cambia altezza o si nasconde.
    static let scostamentoBasso: CGFloat = 40

    /// Quanto vicino deve finire il trascinamento perché l'ancora se lo prenda.
    ///
    /// 60 punti è poco più di una pillola e mezza in altezza: abbastanza da
    /// perdonare la mano, troppo poco perché un punto scelto apposta a metà
    /// schermo venga risucchiato da qualcosa che non hai chiesto.
    static let raggioAggancio: CGFloat = 60

    /// Il centro dell'ancora «in basso al centro».
    static func centroBasso(visibile: NSRect) -> NSPoint {
        NSPoint(x: visibile.midX, y: visibile.minY + scostamentoBasso)
    }

    /// Il centro dell'ancora «nel notch»: il guscio a filo del bordo FISICO
    /// dello schermo, non dell'area visibile, perché il nero deve arrivare
    /// all'hardware invece di galleggiarci sotto.
    static func centroNotch(schermo: NSRect, altezzaGuscio: CGFloat) -> NSPoint {
        NSPoint(x: schermo.midX, y: schermo.maxY - altezzaGuscio / 2)
    }

    /// Il nome dell'ancora che si prende questo punto, oppure `nil` se il punto
    /// non è vicino a nessuna.
    ///
    /// `nil` è un'informazione e va trattata come tale: dice «lasciata in un
    /// posto suo», che è precisamente il modo `libera`.
    static func aggancio(centro: NSPoint,
                         schermo: NSRect,
                         visibile: NSRect,
                         altezzaGuscioNotch: CGFloat) -> WavePosition? {
        let candidate: [(WavePosition, NSPoint)] = [
            (.notch, centroNotch(schermo: schermo, altezzaGuscio: altezzaGuscioNotch)),
            (.bassoCentro, centroBasso(visibile: visibile)),
        ]
        let vicine = candidate
            .map { ($0.0, hypot(centro.x - $0.1.x, centro.y - $0.1.y)) }
            .filter { $0.1 <= raggioAggancio }
        return vicine.min(by: { $0.1 < $1.1 })?.0
    }

    /// **Che cosa SCRIVE un rilascio**, e niente più.
    ///
    /// Il contratto vive qui, pura aritmetica, e non dentro il pannello, per una
    /// ragione che non è di stile: `AppState` è un singolo con `init` privato che
    /// scrive in `UserDefaults.standard`, quindi una prova che passasse di lì
    /// riconfigurerebbe la sua Kalamos vera per provare una regola. Separando il
    /// «cosa si scrive» dal «lo scrivo», i due poli di ogni riga si possono
    /// mostrare senza toccare niente di suo.
    enum Esito: Equatable {
        /// Agganciata: si salva il NOME, e sarà l'impostazione a ridisegnare
        /// posizione e taglia.
        case nome(WavePosition)
        /// Modo `libera`: gli unici numeri che si salvano in tutto il sistema.
        case coordinate(NSPoint)
        /// Lasciata lontano da ogni magnete: diventa `libera` e ci resta, perché
        /// «di base è ancorata in basso al centro oppure nel notch, ma è sempre
        /// movibile» (sua correzione del 19/08 dopo la prima consegna).
        case lontano(NSPoint)
    }

    /// Le tre righe del contratto, in ordine, e non ce n'è una quarta.
    static func rilascio(centro: NSPoint,
                         impostazione: WavePosition,
                         schermo: NSRect,
                         visibile: NSRect,
                         altezzaGuscioNotch: CGFloat) -> Esito {
        if let ancora = aggancio(centro: centro, schermo: schermo, visibile: visibile,
                                 altezzaGuscioNotch: altezzaGuscioNotch) {
            return .nome(ancora)
        }
        let dentro = dentroVisibile(centro, visibile: visibile, guscio: BubbleGeometry.size)
        return impostazione.salvaCoordinate ? .coordinate(dentro) : .lontano(dentro)
    }

    /// Riporta un centro dentro l'area visibile, invece di rifiutarlo.
    ///
    /// **Rifiutare non basta, ed è la differenza fra un modo che sopravvive e uno
    /// che si rompe da solo.** Un punto salvato contro un monitor staccato non è
    /// un dato corrotto: è un dato giusto per un mondo che non c'è più. Buttarlo
    /// riporta l'isola al default e cancella la scelta; riportarlo dentro la
    /// conserva il più possibile. Il guscio entra nel conto perché quello che
    /// deve restare visibile è la pillola, non il suo centro.
    static func dentroVisibile(_ centro: NSPoint, visibile: NSRect, guscio: CGSize) -> NSPoint {
        let mx = guscio.width / 2, my = guscio.height / 2
        // Uno schermo più piccolo del guscio non esiste, ma se esistesse il
        // `min`/`max` incrociato darebbe un intervallo vuoto: si tiene il centro
        // dell'area visibile, che è l'unica risposta sensata.
        guard visibile.width >= guscio.width, visibile.height >= guscio.height else {
            return NSPoint(x: visibile.midX, y: visibile.midY)
        }
        return NSPoint(x: min(max(centro.x, visibile.minX + mx), visibile.maxX - mx),
                       y: min(max(centro.y, visibile.minY + my), visibile.maxY - my))
    }

    /// Che cosa diventa un `wavePosition` scritto prima del 19/08.
    ///
    /// Fino a ieri i modi erano due e il trascinamento scriveva `bubble` di sua
    /// iniziativa: nei suoi defaults c'è `bubble` senza che l'abbia mai scelto.
    /// La migrazione non indovina, guarda **dove** stava: se il centro salvato
    /// cade nel raggio dell'ancora bassa quella è la sua posizione e prende il
    /// nome, altrimenti è una posizione sua e diventa `libera`. Sul suo Mac il
    /// centro salvato è `754 114`, l'ancora è a `756 114`: due punti, quindi
    /// diventa `bassoCentro` senza che si sposti niente.
    static func migra(vecchioValore: String,
                      centroSalvato: NSPoint?,
                      visibile: NSRect) -> WavePosition? {
        guard vecchioValore == "bubble" else { return nil }
        guard let c = centroSalvato else { return .bassoCentro }
        let a = centroBasso(visibile: visibile)
        return hypot(c.x - a.x, c.y - a.y) <= raggioAggancio ? .bassoCentro : .libera
    }
}
