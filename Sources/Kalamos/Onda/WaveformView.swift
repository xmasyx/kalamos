import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// PROVENIENZA — incorporato da OndaKit
// (`05-Tools/OndaKit/Sources/OndaKit/WaveformView.swift`). Copia e non
// dipendenza per lo stesso motivo scritto in `WaveModel.swift`: il repo è
// pubblico e un pacchetto locale romperebbe chi clona. Una modifica al disegno
// si fa prima in OndaKit e poi si riporta qui.
// ─────────────────────────────────────────────────────────────────────────────

// L'onda animata (WaveformView) e il disegno a tempo esplicito (WaveCanvas):
// la stessa vista che anima si fotografa a un istante scelto, perché il
// movimento si verifica a fotogrammi e un fotogramma vuole un `t` iniettabile.
public struct WaveformView: View {
    public var livello: Double
    /// Lo scarto sillabico, −1…1. **Non tocca l'altezza**: entra nella fase,
    /// cioè nella velocità con cui le creste viaggiano. Due tempi separati —
    /// l'altezza segue l'intensità di parlato, lenta; questo segue le sillabe.
    public var dettaglio: Double
    public var tinta: Color
    public var attiva: Bool
    public var profilo: @Sendable (Double) -> Double

    public init(livello: Double, dettaglio: Double = 0, tinta: Color, attiva: Bool = true,
                profilo: @escaping @Sendable (Double) -> Double = WaveCanvas.profiloPieno) {
        self.livello = livello
        self.dettaglio = dettaglio
        self.tinta = tinta
        self.attiva = attiva
        self.profilo = profilo
    }

    public var body: some View {
        TimelineView(.animation(paused: !attiva)) { timeline in
            WaveCanvas(
                livello: livello,
                dettaglio: dettaglio,
                tinta: tinta,
                t: timeline.date.timeIntervalSinceReferenceDate,
                profilo: profilo
            )
        }
        .allowsHitTesting(false)
    }
}

public struct WaveCanvas: View {
    public var livello: Double
    /// Lo scarto sillabico, −1…1: vedi `WaveformView.dettaglio`. Zero per
    /// difetto, e a zero questo disegno è quello di prima, pixel per pixel.
    public var dettaglio: Double = 0
    public var tinta: Color
    public var t: Double

    /// **Quanta della propria altezza il contenitore concede all'onda a ogni
    /// ascissa**, per `u` da −1 a 1, come frazione da 0 a 1.
    ///
    /// Esiste perché l'onda ha smesso di vivere solo dentro rettangoli. In una
    /// capsula il soffitto cala sulle due calotte, e un'onda disegnata a
    /// tutt'altezza fin sul bordo si fa amputare le creste dal ritaglio — che si
    /// legge come un errore di disegno, non come una forma. La strada opposta,
    /// cioè restringere il riquadro dell'onda perché ci stia comunque, tiene il
    /// filo lontano dai due estremi, ed è esattamente ciò che il principale non
    /// vuole vedere («da un estremo all'altro, non in mezzo e basta»).
    ///
    /// Con il profilo l'onda arriva ai bordi e si assottiglia lì, dentro la
    /// forma, invece di essere tagliata da essa: il contenitore dichiara la sua
    /// geometria una volta e il disegno la rispetta per costruzione. Il difetto
    /// che questo rende IMPOSSIBILE è quello che prima si poteva solo tenere
    /// d'occhio con una prova.
    public var profilo: @Sendable (Double) -> Double

    /// Il rettangolo pieno: nessun restringimento.
    public nonisolated static let profiloPieno: @Sendable (Double) -> Double = { _ in 1 }

    /// Pieno in mezzo, spento sulle ultime `coda` di ciascun capo.
    ///
    /// Serve dove il contenitore è un rettangolo e quindi non impone niente: senza
    /// profilo i nastri arrivano a tutta altezza fino al bordo e lì vengono
    /// TAGLIATI di netto, e una cresta amputata si legge come un errore di
    /// disegno. Con la coda i nastri si spengono dentro il filo, che invece
    /// continua fino in fondo — che è la figura giusta: il filo connesso ai due
    /// lati, le creste che si placano verso le estremità.
    ///
    /// Non è il vecchio margine con un altro nome, ed è la differenza che conta:
    /// il margine restringeva la TELA, quindi accorciava anche il filo e lasciava
    /// il vuoto che lui ha fotografato. Questo lascia la tela intera e abbassa
    /// solo ciò che sale e scende.
    ///
    /// La curva è uno `smoothstep`: arriva a zero con pendenza nulla, quindi il
    /// punto in cui la coda comincia non si vede. Con una rampa lineare si
    /// vedrebbe un ginocchio.
    public nonisolated static func profiloSfumato(coda: Double = 0.12) -> @Sendable (Double) -> Double {
        let coda = min(0.5, max(0.0, coda))
        return { u in
            guard coda > 0 else { return 1 }
            let dentro = (1 - abs(u)) / coda        // 0 al bordo, 1 dove finisce la coda
            guard dentro < 1 else { return 1 }
            let s = max(0, dentro)
            return s * s * (3 - 2 * s)
        }
    }

    /// Quanta della mezza altezza del riquadro l'onda usa davvero.
    ///
    /// Era un `0.92` scritto in mezzo al calcolo, e da lì nessuno poteva
    /// leggerlo: chi costruisce un profilo deve tenerne conto, altrimenti il
    /// margine che crede di lasciare è più stretto dell'8% e la garanzia salta
    /// in silenzio. Adesso è un nome, e chi lo usa lo importa invece di
    /// ricopiarlo (OperationalLessons, 2026-08-05).
    public nonisolated static let riempimento: Double = 0.92

    public init(livello: Double, dettaglio: Double = 0, tinta: Color, t: Double,
                profilo: @escaping @Sendable (Double) -> Double = WaveCanvas.profiloPieno) {
        self.livello = livello
        self.dettaglio = dettaglio
        self.tinta = tinta
        self.t = t
        self.profilo = profilo
    }

    public var body: some View {
        Canvas { ctx, size in
            disegna(in: &ctx, size: size, t: t)
        }
    }

    private func disegna(in ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let mezzaAltezza = size.height / 2
        let passi = max(48, Int(size.width / 3))
        ctx.blendMode = .plusLighter

        for nastro in NastroOnda.nastri {
            var dorso: [CGPoint] = []
            var ventre: [CGPoint] = []
            dorso.reserveCapacity(passi + 1)
            ventre.reserveCapacity(passi + 1)
            for i in 0...passi {
                let x = Double(i) / Double(passi)
                let xn = x * 2 - 1
                let (d, v) = WaveModel.ordinate(x: xn, t: t, livello: livello,
                                                dettaglio: dettaglio, nastro: nastro)
                let scala = mezzaAltezza * Self.riempimento * profilo(xn)
                let px = x * size.width
                dorso.append(CGPoint(x: px, y: mezzaAltezza - d * scala))
                ventre.append(CGPoint(x: px, y: mezzaAltezza - v * scala))
            }
            var lente = Path()
            lente.move(to: dorso[0])
            for p in dorso.dropFirst() { lente.addLine(to: p) }
            for p in ventre.reversed() { lente.addLine(to: p) }
            lente.closeSubpath()

            let colore = miscela(tinta, bianco: nastro.bianco).opacity(nastro.opacita)
            // Il raggio dell'alone, e resta un NUMERO SCRITTO QUI: un guardiano
            // in `WaveIslandTests` legge questo file e pretende che il margine
            // del contenitore lo copra, quindi dietro un nome non lo troverebbe
            // più e il guardiano tacerebbe invece di fallire. Sceso da 6 a 4 il
            // 2026-08-16, quando l'isoletta è diventata una pillola alta 40
            // punti: su 20 punti di mezza altezza un alone da 6 si mangiava
            // quasi un terzo dello spazio dell'onda.
            var alone = ctx
            alone.addFilter(.blur(radius: 4))
            alone.fill(lente, with: .color(colore))
            ctx.fill(lente, with: .color(colore))
        }

        // Il filo, da un estremo all'altro.
        //
        // Sta a metà altezza, cioè sull'asse, e su quell'asse qualunque
        // contenitore — capsula compresa — è largo quanto sé stesso: il filo
        // tocca i due bordi senza chiedere niente al profilo, che governa solo
        // ciò che sale e scende.
        var base = Path()
        base.move(to: CGPoint(x: 0, y: mezzaAltezza))
        base.addLine(to: CGPoint(x: size.width, y: mezzaAltezza))
        ctx.stroke(base, with: .color(miscela(tinta, bianco: 0.7).opacity(0.35)), lineWidth: 1)
    }

    private func miscela(_ colore: Color, bianco: Double) -> Color {
        let ns = NSColor(colore).usingColorSpace(.sRGB) ?? .white
        let w = CGFloat(bianco)
        return Color(
            red: Double(ns.redComponent * (1 - w) + w),
            green: Double(ns.greenComponent * (1 - w) + w),
            blue: Double(ns.blueComponent * (1 - w) + w)
        )
    }
}
