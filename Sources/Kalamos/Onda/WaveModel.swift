import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PROVENIENZA — questo file è incorporato da OndaKit, il componente onda
// dell'autore (`05-Tools/OndaKit/Sources/OndaKit/WaveModel.swift`).
//
// È una COPIA e non una dipendenza, di proposito: il repo di Kalamos è pubblico
// e la CI costruisce il rilascio con lo stesso script, quindi un
// `.package(path: "../OndaKit")` romperebbe chiunque cloni — il pacchetto non
// esiste sul suo disco.
//
// Il prezzo di una copia è che divergerà in silenzio, e si paga così: **una
// modifica alla matematica dell'onda si fa prima in OndaKit e poi si riporta
// qui**, non il contrario. Se un giorno OndaKit diventa pubblico, questa
// cartella torna a essere una dipendenza e i due file spariscono.
// ─────────────────────────────────────────────────────────────────────────────

// Il modello dell'onda, matematica pura: testabile senza finestre.
//
// La grammatica è quella dei nastri traslucidi simmetrici: inviluppo a campana,
// luce che si accumula dove si sovrappongono. Due proprietà sono state scelte
// guardando l'onda muoversi, non leggendo il codice: le creste devono
// VIAGGIARE lungo la linea invece di oscillare sul posto, e il ventre dell'onda
// deve rispondere alla voce con un ritmo suo.
public struct NastroOnda: Sendable {
    public let frequenza: Double       // onde intere sulla larghezza
    public let velocita: Double        // rad/s: POSITIVA = la cresta viaggia
    public let fase: Double
    public let ampiezza: Double
    public let sfasaturaVentre: Double // il ventre non è lo specchio esatto
    public let bianco: Double          // quota di bianco sulla tinta (0…1)
    public let opacita: Double
    public let sensibilita: Double     // quanto la voce lo gonfia (0…1)

    public static let nastri: [NastroOnda] = [
        NastroOnda(frequenza: 1.2, velocita: 3.4, fase: 0.0, ampiezza: 1.00, sfasaturaVentre: 2.4, bianco: 0.00, opacita: 0.34, sensibilita: 1.00),
        NastroOnda(frequenza: 1.7, velocita: 4.6, fase: 1.9, ampiezza: 0.85, sfasaturaVentre: 1.7, bianco: 0.15, opacita: 0.30, sensibilita: 0.85),
        NastroOnda(frequenza: 2.3, velocita: 5.9, fase: 4.1, ampiezza: 0.62, sfasaturaVentre: 2.9, bianco: 0.35, opacita: 0.28, sensibilita: 0.70),
        NastroOnda(frequenza: 2.9, velocita: 7.3, fase: 2.7, ampiezza: 0.44, sfasaturaVentre: 2.1, bianco: 0.55, opacita: 0.26, sensibilita: 0.55),
        NastroOnda(frequenza: 3.6, velocita: 8.8, fase: 5.5, ampiezza: 0.30, sfasaturaVentre: 3.3, bianco: 0.75, opacita: 0.24, sensibilita: 0.45),
    ]

    public init(frequenza: Double, velocita: Double, fase: Double, ampiezza: Double, sfasaturaVentre: Double, bianco: Double, opacita: Double, sensibilita: Double) {
        self.frequenza = frequenza
        self.velocita = velocita
        self.fase = fase
        self.ampiezza = ampiezza
        self.sfasaturaVentre = sfasaturaVentre
        self.bianco = bianco
        self.opacita = opacita
        self.sensibilita = sensibilita
    }
}

public enum WaveModel {
    /// Quanto inviluppo resta agli ESTREMI della linea.
    ///
    /// Con lo zero di prima l'onda moriva ai bordi e viveva solo in mezzo, che
    /// è esattamente il difetto visto sul campo il 16/08: «il filo dell'onda
    /// deve essere da un estremo all'altro, non in mezzo e basta». Il fondo non
    /// è un ritocco estetico, è ciò che rende il filo continuo: sotto la
    /// campana c'è sempre un nastro, sottile, fino al bordo.
    public static let bordoVivo: Double = 0.42

    /// Inviluppo a campana con il CENTRO che deriva lentamente: l'energia si
    /// sposta lungo la linea invece di pulsare ferma.
    ///
    /// La deriva è la METÀ di quella di prima (0.28 → 0.14). Era troppa: con la
    /// campana stretta che c'era, quasi tutta l'altezza stava dove stava il
    /// centro, e il centro scorreva — quindi l'occhio leggeva uno scorrimento
    /// orizzontale invece di una risposta alla voce. L'esponente sceso da 1.6 a
    /// 0.9 allarga la campana per la stessa ragione.
    public static func campana(_ x: Double, t: Double) -> Double {
        let centro = 0.14 * sin(t * 0.9) + 0.06 * sin(t * 1.7)
        let d = (x - centro) / max(0.001, 1.0 - abs(centro) * 0.4)
        let d2 = min(1.0, d * d)
        return bordoVivo + (1.0 - bordoVivo) * pow(1.0 - d2, 0.9)
    }

    /// Ampiezza globale dal livello: in silenzio respira appena, la voce la
    /// gonfia.
    ///
    /// **L'esponente è SALITO, non sceso, e il verso conta.** Un esponente più
    /// basso comprime la scala e appiattisce la differenza fra piano e forte;
    /// il rapporto fra due livelli è `(l₂/l₁)ᵖ`, quindi per far salire e
    /// scendere l'onda in modo visibile p va verso l'alto. Da 0.7 a 0.85 il
    /// salto fra un livello 0,1 e un livello 0,7 passa da 3,9× a 5,2×.
    public static func ampiezzaGlobale(livello: Double, t: Double) -> Double {
        let respiro = 0.03 + 0.015 * sin(t * 1.3)
        let voce = pow(min(1.0, max(0.0, livello)), 0.85)
        return respiro + (1.0 - respiro) * voce
    }

    /// **Quanto il dettaglio sillabico spinge le creste**, in radianti di fase.
    ///
    /// Il dettaglio delle sillabe è uscito dall'ALTEZZA — è quello che si vedeva
    /// come un'onda che pompa su e giù a ogni sillaba — e qui è dove è
    /// rientrato: non come un inviluppo che sbatte, ma come le creste che
    /// accelerano un poco sull'attacco di ogni sillaba. Il movimento percepito
    /// resta orizzontale, che è la forma giusta per un audio.
    ///
    /// **Il numero è piccolo perché conta la sua DERIVATA, non il suo valore.**
    /// Uno scostamento di fase costante di 0,1 rad sposta la cresta di
    /// 0,1/(π·1,2) ≈ 0,027 unità di ascissa su due, cioè l'1,3% della larghezza:
    /// da fermo non si vede. Ma il dettaglio si muove al più di 0,35 per
    /// campione a 30 Hz, cioè 10,5 al secondo, quindi la VELOCITÀ della cresta
    /// varia di 0,1·10,5/(π·1,2) ≈ 0,28 unità al secondo contro le 0,90 di base:
    /// una spinta che si vede, e che non arriva mai a invertire il verso del
    /// viaggio, perché 0,90 − 0,28 resta positivo. Il nastro più lento è quello
    /// col margine più stretto, quindi è lui a fissare il tetto di questo numero.
    public static let spintaDettaglio: Double = 0.10

    /// Le due ordinate (dorso, ventre) di un nastro in x ∈ [-1, 1],
    /// normalizzate -1…1 rispetto a metà altezza.
    ///
    /// `dettaglio` è lo scarto sillabico, da −1 a 1: quanto il volume istantaneo
    /// sta sopra o sotto l'intensità di parlato lenta che governa l'altezza. Vale
    /// zero per difetto, e con lo zero questa funzione è esattamente quella di
    /// prima — è la ragione per cui ogni sonda e ogni prova che non lo passa
    /// misura ancora ciò che misurava.
    public static func ordinate(x: Double, t: Double, livello: Double,
                                dettaglio: Double = 0, nastro: NastroOnda) -> (dorso: Double, ventre: Double) {
        // Ogni nastro sente la voce con la SUA sensibilità: i sottili si
        // muovono anche sul sussurro, il principale esplode solo sul parlato.
        let personale = min(1.0, livello * (0.6 + nastro.sensibilita * 0.8))
        let a = ampiezzaGlobale(livello: personale, t: t) * nastro.ampiezza * campana(x, t: t)
        // Il segno MENO fa viaggiare la cresta da sinistra a destra.
        let spinta = max(-1.0, min(1.0, dettaglio)) * spintaDettaglio
        let argomento = x * .pi * nastro.frequenza - t * nastro.velocita + nastro.fase + spinta
        let dorso = a * sin(argomento)
        let ventre = -a * sin(argomento + nastro.sfasaturaVentre)
        return (max(dorso, ventre), min(dorso, ventre))
    }
}
