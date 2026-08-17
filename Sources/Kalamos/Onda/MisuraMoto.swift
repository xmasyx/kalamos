import AVFoundation
import CoreGraphics
import Foundation

/// **Misurare il movimento invece di dichiararlo.**
///
/// Due difetti visti sul campo il 2026-08-16 sono difetti di MOTO, e nessuno dei
/// due si vede in una fotografia: l'onda che «si muove poco quando parlo», e la
/// goccia che scendendo dal notch non sembra una goccia. Una fotografia li
/// racconta entrambi come «c'è un'onda dentro un guscio», che è vero e inutile.
///
/// Da qui due misure, e stanno insieme perché rispondono alla stessa domanda —
/// quanto si muove questa cosa — su due materiali diversi:
///
/// · `banda(livello:profilo:)` misura la MATEMATICA dell'app, non una sua copia:
///   chiama `WaveModel.ordinate` e il profilo del contenitore vero. Serve al
///   banco che pretende che l'onda raddoppi fra un livello basso e uno alto.
/// · `riquadro(di:)` misura i PIXEL di un fotogramma. Serve al filmato, dove la
///   domanda è quanto è larga e alta l'isola istante per istante — cioè la
///   colonna con cui si giudica la discesa della goccia.
///
/// La seconda è la più forte delle due e va detto perché: misura il prodotto
/// finito, quindi coglie anche gli errori che stanno FRA la matematica e lo
/// schermo — un ritaglio, una scala, una finestra troppo piccola. La prima è
/// deterministica e gira nei test senza aprire finestre. Nessuna delle due
/// riscrive la logica che deve giudicare (OperationalLessons, 2026-08-05).
enum MisuraMoto {

    // MARK: - La banda, dalla matematica dell'app

    /// **Quanta altezza del riquadro l'onda occupa davvero**, da 0 a 1, al
    /// livello dato.
    ///
    /// È il massimo, su tutte le ascisse e su un giro completo di fasi, dello
    /// scostamento dall'asse — moltiplicato per due, perché la banda è la somma
    /// del sopra e del sotto. Un istante solo non direbbe niente: l'inviluppo
    /// deriva, quindi la parte alta dell'onda visita ogni ascissa a turno e il
    /// fotogramma sbagliato la coglie dove non c'è.
    ///
    /// `profilo` è quello del contenitore vero (`BubbleGeometry.profile`), non
    /// uno inventato qui: la banda dentro una pillola è più stretta di quella
    /// dentro una banda rettangolare, e misurarla senza il contenitore darebbe un
    /// numero che nessuno vede sullo schermo.
    static func banda(livello: Double,
                      profilo: (Double) -> Double = { _ in 1 },
                      passi: Int = 200,
                      istanti: Int = 240,
                      passoTempo: Double = 0.05) -> Double {
        var estremo = 0.0
        for i in 0...passi {
            let u = Double(i) / Double(passi) * 2 - 1
            let concesso = profilo(u)
            guard concesso > 0 else { continue }
            for k in 0..<istanti {
                let t = Double(k) * passoTempo
                for nastro in NastroOnda.nastri {
                    let (dorso, ventre) = WaveModel.ordinate(x: u, t: t,
                                                             livello: livello, nastro: nastro)
                    estremo = max(estremo, max(abs(dorso), abs(ventre)) * concesso)
                }
            }
        }
        // `riempimento` è la quota di mezza altezza che il disegno usa: senza di
        // essa questo numero sarebbe la banda di un'onda disegnata da qualcun
        // altro. Importato, mai ricopiato.
        return min(1, estremo * WaveCanvas.riempimento)
    }

    // MARK: - Il riquadro, dai pixel di un fotogramma

    /// Il rettangolo che contiene tutto ciò che NON è lo sfondo, in pixel.
    ///
    /// Lo sfondo si prende dall'angolo in alto a sinistra invece di essere
    /// dichiarato: la carta sotto l'isola la sceglie `cornicePerIsola`, e un
    /// secondo posto dove scriverne il colore è un secondo posto da aggiornare.
    ///
    /// **Due alternative sono state provate e tolte il 2026-08-16, e vanno scritte
    /// perché altrimenti qualcuno le riprova.** Prendere il colore dall'ULTIMO
    /// fotogramma del filmato presuppone che alla fine l'isola se ne sia andata:
    /// su un filmato uscito di 3,8 s invece dei 5 previsti l'ultimo fotogramma
    /// conteneva ancora il guscio, «sfondo» è diventato il nero dell'isola, e la
    /// sonda ha misurato la carta credendola l'isola in tutti i fotogrammi.
    /// Prendere il colore PIÙ FREQUENTE dell'immagine presuppone che la carta sia
    /// più grande del soggetto: vero per la cornice di questa sonda, falso appena
    /// il soggetto riempie l'inquadratura, e allora si rovescia tutto senza dire
    /// niente. L'angolo presuppone soltanto che l'angolo sia carta, che è quello
    /// che la cornice garantisce per costruzione — 160 punti di margine attorno
    /// all'isola — ed è l'unica delle tre che sbaglia solo quando la cornice
    /// stessa non c'è.
    ///
    /// `nil` quando l'immagine è tutta uguale a sé stessa — che è la risposta
    /// giusta per un fotogramma in cui l'isola non c'è, e va distinta da un
    /// riquadro di larghezza zero.
    static func riquadro(di image: CGImage, tolleranza: Int = 24) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let sfondo = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let d = abs(Int(pixels[i]) - sfondo.0)
                    + abs(Int(pixels[i + 1]) - sfondo.1)
                    + abs(Int(pixels[i + 2]) - sfondo.2)
                guard d > tolleranza else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }



    // MARK: - Il filo, e se tocca davvero i bordi

    /// Che cosa si è visto sulla riga del filo.
    struct Filo {
        let riga: Int
        let sinistra: Bool
        let destra: Bool
        /// Quante colonne, partendo da ciascun bordo, non hanno luce d'onda.
        let vuotoSinistra: Int
        let vuotoDestra: Int
        var tocca: Bool { sinistra && destra }
    }

    /// **Il filo arriva ai due bordi del guscio, o si ferma a mezz'aria?**
    ///
    /// Nasce da una fotografia sua del 2026-08-16: «le estremità dovrebbero essere
    /// connesse ai bordi», con un vuoto visibile fra la fine del filo e il guscio
    /// da tutti e due i lati. È un difetto che nessuna prova sul modello può
    /// prendere — la matematica dell'onda era già giusta, sbagliata era la
    /// LARGHEZZA DELLA TELA — e che un riquadro di ingombro non vede, perché il
    /// guscio arriva ai bordi anche quando il filo dentro non ci arriva.
    ///
    /// Si misura sul pixel, come ha chiesto: si trova la riga del filo, e su
    /// quella riga si guarda la prima e l'ultima colonna dentro il guscio. Se lì
    /// c'è solo guscio, il filo non tocca.
    ///
    /// **Tre colori e non due**, ed è la parte che fa funzionare la misura su
    /// tutt'e due le forme: la carta sotto (l'angolo dell'immagine), il guscio (il
    /// colore più frequente dentro l'ingombro) e l'onda (tutto il resto). Cercare
    /// «ciò che non è carta» troverebbe il guscio e direbbe sempre di sì.
    static func filoAiBordi(di image: CGImage, tolleranza: Int = 20) -> Filo? {
        let w = image.width, h = image.height
        guard w > 2, h > 2, let box = riquadro(di: image, tolleranza: tolleranza) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func colore(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func distanza(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }

        // `maxX`/`maxY` di un `CGRect` sono l'estremo ESCLUSO — `riquadro` lo
        // costruisce con `larghezza = maxX - minX + 1` — quindi l'ultima colonna
        // valida è una prima. Senza il meno uno questa funzione leggeva un pixel
        // oltre la fine della riga: dentro l'immagine è il primo pixel della riga
        // successiva, cioè carta, e faceva risultare **un vuoto a destra che non
        // c'era**; sull'ultima riga esce dal buffer e va in «Index out of range».
        // Un errore che sbaglia in silenzio quasi sempre e crolla di rado è il
        // peggiore dei due modi.
        let x0 = Int(box.minX), x1 = Int(box.maxX) - 1
        let y0 = Int(box.minY), y1 = Int(box.maxY) - 1
        guard x1 > x0, y1 > y0 else { return nil }
        let carta = colore(0, 0)

        // Il guscio è il colore che dentro l'ingombro si ripete di più. Preso così
        // e non da un punto scelto a mano, perché in una capsula gli angoli
        // dell'ingombro sono carta e non guscio: un campione «in alto a sinistra»
        // misurerebbe la forma sbagliata proprio sulla forma nuova.
        var conteggio: [Int: Int] = [:]
        for y in y0...y1 {
            for x in x0...x1 {
                let c = colore(x, y)
                let chiave = (c.0 >> 3) << 10 | (c.1 >> 3) << 5 | (c.2 >> 3)
                conteggio[chiave, default: 0] += 1
            }
        }
        guard let modo = conteggio.max(by: { $0.value < $1.value })?.key else { return nil }
        let guscio = ((modo >> 10 & 31) << 3, (modo >> 5 & 31) << 3, (modo & 31) << 3)

        /// Luce d'onda: né carta né guscio.
        func onda(_ x: Int, _ y: Int) -> Bool {
            let c = colore(x, y)
            return distanza(c, guscio) > tolleranza && distanza(c, carta) > tolleranza
        }

        // La riga del filo è quella con più luce: il filo attraversa tutto, i
        // nastri no. Cercarla invece di calcolarla dalla geometria è voluto — la
        // banda del notch e la pillola tengono il filo a due altezze diverse, e
        // una misura che le sapesse a memoria sarebbe da aggiornare a ogni
        // ritocco del disegno.
        var migliore = (riga: y0, luce: -1)
        for y in y0...y1 {
            var luce = 0
            for x in x0...x1 where onda(x, y) { luce += 1 }
            if luce > migliore.luce { migliore = (y, luce) }
        }
        let riga = migliore.riga
        guard migliore.luce > 0 else {
            return Filo(riga: riga, sinistra: false, destra: false,
                        vuotoSinistra: x1 - x0, vuotoDestra: x1 - x0)
        }

        // Quanto è largo il vuoto a ciascun capo, sulla riga del filo. Riportare
        // la misura e non solo il sì/no: un vuoto di un pixel è antialiasing, uno
        // di quaranta è il margine che il disegno si porta dietro.
        var vuotoS = 0
        while x0 + vuotoS <= x1 && !onda(x0 + vuotoS, riga) { vuotoS += 1 }
        var vuotoD = 0
        while x1 - vuotoD >= x0 && !onda(x1 - vuotoD, riga) { vuotoD += 1 }

        // Due pixel di tolleranza per capo, e non zero: il bordo di una forma
        // arrotondata è antialiasato, quindi la colonna esattissima è una miscela
        // fra guscio e carta in cui nessuna luce può vincere. Oltre i due pixel
        // non è più antialiasing, è margine.
        let ammesso = 2
        return Filo(riga: riga,
                    sinistra: vuotoS <= ammesso, destra: vuotoD <= ammesso,
                    vuotoSinistra: vuotoS, vuotoDestra: vuotoD)
    }

    // MARK: - Il filmato, fotogramma per fotogramma

    /// Una riga di misura del filmato.
    struct Fotogramma {
        let secondi: Double
        let larghezza: Int
        let altezza: Int
    }

    /// Percorre un filmato e misura l'isola in ogni fotogramma.
    ///
    /// I fotogrammi si chiedono a passo fisso invece di leggere il flusso: un
    /// filmato di `screencapture` non promette una cadenza, e una colonna dei
    /// tempi ricavata dal conteggio dei fotogrammi sarebbe una colonna inventata.
    /// Le tolleranze a zero servono a questo: il fotogramma consegnato deve
    /// essere quello dell'istante chiesto, non il più vicino.
    /// La tolleranza per un FOTOGRAMMA, che è più larga di quella per una
    /// fotografia, e il motivo è la compressione.
    ///
    /// Un PNG è esatto; un filmato no. La carta di questa sonda esce dal codificatore
    /// divisa in riquadri che differiscono fra loro di pochi valori, e a occhio
    /// resta carta uniforme — ma con la tolleranza stretta della fotografia metà
    /// inquadratura risultava «non sfondo», quindi l'isola sembrava larga quanto
    /// tutto il filmato e la discesa veniva misurata su una cucitura di
    /// compressione. Riprodotto guardando il fotogramma: una linea verticale a
    /// x≈750, invisibile finché non si va a cercarla.
    ///
    /// Novanta è largo per il rumore e strettissimo per il soggetto: fra il guscio
    /// nero e la carta ci sono circa settecento, cioè otto volte tanto.
    static let tolleranzaFilmato = 90

    static func misura(filmato url: URL, passo: Double = 1.0 / 60,
                       tolleranza: Int = tolleranzaFilmato) async throws -> [Fotogramma] {
        let asset = AVURLAsset(url: url)
        let durata = try await asset.load(.duration).seconds
        guard durata.isFinite, durata > 0 else { return [] }

        let generatore = AVAssetImageGenerator(asset: asset)
        generatore.appliesPreferredTrackTransform = true
        generatore.requestedTimeToleranceBefore = .zero
        generatore.requestedTimeToleranceAfter = .zero

        var righe: [Fotogramma] = []
        var t = 0.0
        while t < durata {
            let tempo = CMTime(seconds: t, preferredTimescale: 600)
            guard let immagine = try? await generatore.image(at: tempo).image else {
                t += passo
                continue
            }
            let box = riquadro(di: immagine, tolleranza: tolleranza)
            righe.append(Fotogramma(secondi: t,
                                    larghezza: Int(box?.width ?? 0),
                                    altezza: Int(box?.height ?? 0)))
            t += passo
        }
        return righe
    }

    /// La tabella che si legge, con la colonna `largh` che giudica la discesa.
    ///
    /// Le colonne sono tre e non una: la larghezza da sola non dice se il
    /// fotogramma sta scendendo o salendo, e l'altezza accanto lo dice senza
    /// bisogno di aprire il filmato.
    static func tabella(_ righe: [Fotogramma]) -> String {
        var out = "  t(s)   largh   alt\n"
        for r in righe {
            out += String(format: "  %5.3f  %5d  %4d\n", r.secondi, r.larghezza, r.altezza)
        }
        return out
    }

    /// **Il tratto in cui l'isola c'è**, cioè il primo blocco continuo di
    /// fotogrammi che contengono qualcosa.
    ///
    /// Un filmato comincia prima dell'entrata e finisce dopo l'uscita, quindi si
    /// apre e si chiude con fotogrammi di sola carta. Misurare la discesa
    /// sull'intero filmato significa misurare soprattutto l'attesa — ed è il
    /// difetto che questa funzione aveva alla prima stesura: guardava l'ULTIMO
    /// fotogramma, che è vuoto per costruzione, e dichiarava che non c'era niente
    /// da misurare su un filmato perfettamente buono.
    static func tratto(_ righe: [Fotogramma]) -> ArraySlice<Fotogramma> {
        guard let inizio = righe.firstIndex(where: { $0.larghezza > 0 }) else { return [] }
        let fine = righe[inizio...].firstIndex(where: { $0.larghezza == 0 }) ?? righe.endIndex
        return righe[inizio ..< fine]
    }

    /// **La discesa è una goccia?** — il giudizio, come predicato invece che come
    /// prosa.
    ///
    /// Tre condizioni, e sono le tre cose che distinguono una goccia da uno zoom:
    /// la larghezza resta ferma per un tratto che si vede (almeno sei fotogrammi,
    /// cioè un decimo di secondo), in quel tratto si muove pochissimo (meno del
    /// 5%) mentre l'altezza cresce parecchio, e alla fine la larghezza passa oltre
    /// la sua misura a regime prima di tornarci.
    ///
    /// Sta qui e non nello script perché è un giudizio, e un giudizio scritto in
    /// `awk` dentro una sonda non ha prove che lo tengano onesto.
    static func discesaÈUnaGoccia(_ righe: [Fotogramma]) -> Bool {
        let vivi = tratto(righe)
        guard vivi.count > 6, let prima = vivi.first, prima.larghezza > 0 else { return false }
        let partenza = prima.larghezza
        let apertura = vivi.firstIndex { $0.larghezza > partenza * 105 / 100 } ?? vivi.endIndex
        let tenuta = vivi[vivi.startIndex ..< apertura]
        guard tenuta.count >= 6 else { return false }

        let escursione = (tenuta.map(\.larghezza).max() ?? 0) - (tenuta.map(\.larghezza).min() ?? 0)
        guard escursione * 20 <= partenza else { return false }          // sotto il 5%

        let altezze = tenuta.map(\.altezza)
        let crescita = (altezze.max() ?? 0) - (altezze.min() ?? 0)
        guard crescita > partenza / 4 else { return false }              // si allunga davvero

        let picco = vivi.map(\.larghezza).max() ?? 0
        let coda = vivi.suffix(max(1, vivi.count / 3)).map(\.larghezza).sorted()
        let regime = coda[coda.count / 2]
        return picco > regime                                            // e rimbalza
    }

    /// Il verdetto sulla discesa, in una riga.
    ///
    /// La firma attesa della goccia: la larghezza sta quasi ferma, vicino a quella
    /// del notch, mentre l'altezza si allunga; poi la larghezza si apre in fretta
    /// e passa oltre la sua misura prima di assestarsi. Il momento in cui «si
    /// apre» non è deciso a priori — si prende il primo fotogramma in cui la
    /// larghezza supera del 5% quella di partenza — così la misura non presuppone
    /// il ritardo che dovrebbe verificare.
    ///
    /// Riportare i numeri invece del sì/no è voluto: un giudizio che non porta con
    /// sé la misura non si può contestare.
    static func firmaDellaDiscesa(_ righe: [Fotogramma]) -> String {
        let vivi = tratto(righe)
        guard vivi.count > 6, let prima = vivi.first else {
            return "discesa: nessun fotogramma misurabile"
        }
        let partenza = prima.larghezza
        let apertura = vivi.firstIndex { $0.larghezza > partenza * 105 / 100 } ?? vivi.endIndex
        let tenuta = vivi[vivi.startIndex ..< apertura]
        let picco = vivi.map(\.larghezza).max() ?? 0
        // A regime: l'ultimo terzo del tratto, quando tutto si è assestato.
        let coda = vivi.suffix(max(1, vivi.count / 3)).map(\.larghezza)
        let regime = coda.sorted()[coda.count / 2]
        let secondiDiTenuta = Double(tenuta.count) * (vivi.count > 1
            ? (vivi[vivi.index(after: vivi.startIndex)].secondi - prima.secondi) : 0)
        let escursione = (tenuta.map(\.larghezza).max() ?? partenza)
            - (tenuta.map(\.larghezza).min() ?? partenza)
        let altezze = tenuta.map(\.altezza)
        let crescita = (altezze.max() ?? 0) - (altezze.min() ?? 0)
        return String(
            format: """
            discesa: la larghezza tiene %d fotogrammi (%.2fs) a %d px con escursione %d, \
            mentre l'altezza cresce di %d px; poi si apre fino a %d contro %d a regime \
            (overshoot %+.1f%%)
            """,
            tenuta.count, secondiDiTenuta, partenza, escursione, crescita,
            picco, regime,
            regime > 0 ? (Double(picco - regime) / Double(regime)) * 100 : 0)
    }
}
