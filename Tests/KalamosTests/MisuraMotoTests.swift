import CoreGraphics
import Foundation
import Testing
@testable import Kalamos

/// **La sonda del moto è essa stessa un componente, quindi va sondata.**
///
/// «Un controllo mai controllato è un'asserzione travestita da verifica»
/// (OperationalLessons, 2026-07-12). Queste misure sono ciò con cui si giudicano
/// l'onda e la discesa della goccia: se sbagliassero, il referto sarebbe un
/// numero sbagliato con l'aria di essere una prova — che è peggio di nessun
/// numero.
@Suite("MisuraMoto — la sonda che misura il movimento")
struct MisuraMotoTests {

    /// Un'immagine con un rettangolo pieno dentro, di misura nota.
    private func immagine(larghezza: Int, altezza: Int,
                          rettangolo: CGRect?) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: larghezza, height: altezza,
                            bitsPerComponent: 8, bytesPerRow: larghezza * 4,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: larghezza, height: altezza))
        if let rettangolo {
            ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1))
            ctx.fill(rettangolo)
        }
        return ctx.makeImage()!
    }

    // MARK: - Il riquadro dai pixel

    /// Il polo positivo: un rettangolo noto va misurato per quello che è.
    @Test("Il riquadro trova la misura vera di ciò che è disegnato")
    func boundingBoxIsExact() throws {
        let img = immagine(larghezza: 200, altezza: 100,
                           rettangolo: CGRect(x: 40, y: 30, width: 80, height: 20))
        let box = try #require(MisuraMoto.riquadro(di: img))
        #expect(box.width == 80)
        #expect(box.height == 20)
        #expect(box.minX == 40)
    }

    /// **Il polo negativo, ed è quello che conta**: un fotogramma in cui non c'è
    /// niente deve rispondere «niente», non un riquadro di misura zero.
    ///
    /// I due casi si scrivono uguali in una tabella — `0 0` — e significano cose
    /// opposte: «l'isola non è ancora entrata» contro «l'isola è larga zero». Il
    /// filmato comincia e finisce con dei fotogrammi vuoti per costruzione, quindi
    /// senza questa distinzione la firma della discesa leggerebbe l'attesa come
    /// parte del movimento.
    @Test("Un fotogramma senza isola risponde niente, non zero")
    func anEmptyFrameIsNil() {
        #expect(MisuraMoto.riquadro(di: immagine(larghezza: 60, altezza: 40, rettangolo: nil)) == nil)
    }

    /// Lo sfondo si prende dall'angolo, non da una costante: la carta della sonda
    /// ha due facce, chiara e scura, e una soglia scritta a mano ne misurerebbe
    /// bene una sola.
    @Test("La faccia scura si misura come quella chiara")
    func theDarkBackdropIsMeasuredToo() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8,
                            bytesPerRow: 120 * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))   // carta scura
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1))    // l'onda, chiara
        ctx.fill(CGRect(x: 20, y: 10, width: 50, height: 12))
        let box = try #require(MisuraMoto.riquadro(di: ctx.makeImage()!))
        #expect(box.width == 50 && box.height == 12)
    }

    // MARK: - Il filo ai bordi

    /// Un'isola finta: carta, guscio scuro, e un filo orizzontale che va da
    /// `da` a `a` dentro il guscio.
    private func isola(guscio: CGRect, filoDa da: Int, filoA a: Int,
                       larghezza: Int = 300, altezza: Int = 120) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: larghezza, height: altezza,
                            bitsPerComponent: 8, bytesPerRow: larghezza * 4,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1))   // carta
        ctx.fill(CGRect(x: 0, y: 0, width: larghezza, height: altezza))
        ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))   // guscio
        ctx.fill(guscio)
        ctx.setFillColor(CGColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1))   // il filo
        ctx.fill(CGRect(x: CGFloat(da), y: guscio.midY - 1,
                        width: CGFloat(a - da), height: 2))
        return ctx.makeImage()!
    }

    /// Il polo positivo: un filo che copre tutta la larghezza del guscio tocca.
    @Test("Un filo lungo quanto il guscio tocca i due bordi")
    func theThreadTouchesWhenItSpansTheShell() throws {
        let guscio = CGRect(x: 50, y: 30, width: 200, height: 60)
        let filo = try #require(MisuraMoto.filoAiBordi(di: isola(guscio: guscio,
                                                                filoDa: 50, filoA: 250)))
        #expect(filo.tocca)
        #expect(filo.vuotoSinistra <= 2 && filo.vuotoDestra <= 2)
    }

    /// **Il polo negativo, ed è il difetto che lui ha fotografato il 2026-08-16:**
    /// il filo si ferma a mezz'aria e fra la sua estremità e il guscio resta un
    /// vuoto. Riprodotto qui a 22 punti per lato, che è esattamente il margine che
    /// `IslandView` teneva nel notch.
    ///
    /// Senza questo polo il numero riportato dalla sonda sarebbe soltanto un
    /// numero risultato piccolo, e non una misura che sa distinguere.
    @Test("Un filo che si ferma prima NON tocca, e il vuoto si misura")
    func theThreadThatStopsShortIsCaught() throws {
        let guscio = CGRect(x: 50, y: 30, width: 200, height: 60)
        let filo = try #require(MisuraMoto.filoAiBordi(di: isola(guscio: guscio,
                                                                filoDa: 94, filoA: 206)))
        #expect(!filo.tocca)
        #expect(filo.vuotoSinistra > 30, "vuoto misurato \(filo.vuotoSinistra)")
        #expect(filo.vuotoDestra > 30, "vuoto misurato \(filo.vuotoDestra)")
    }

    /// Un lato solo basta a bocciare: un filo attaccato a sinistra e staccato a
    /// destra è comunque il difetto.
    @Test("Basta un lato staccato perché il filo non tocchi")
    func oneLooseEndIsEnough() throws {
        let guscio = CGRect(x: 50, y: 30, width: 200, height: 60)
        let filo = try #require(MisuraMoto.filoAiBordi(di: isola(guscio: guscio,
                                                                filoDa: 50, filoA: 200)))
        #expect(filo.sinistra)
        #expect(!filo.destra)
        #expect(!filo.tocca)
    }

    /// Un guscio senza niente dentro non è un filo che tocca: è un'onda che non
    /// c'è. Il ramo muto va distinto dal successo, o un disegno spento passerebbe.
    @Test("Un guscio vuoto non conta come filo che tocca")
    func anEmptyShellDoesNotPass() throws {
        let guscio = CGRect(x: 50, y: 30, width: 200, height: 60)
        let filo = try #require(MisuraMoto.filoAiBordi(di: isola(guscio: guscio,
                                                                filoDa: 0, filoA: 0)))
        #expect(!filo.tocca)
    }

    /// **Un guscio attaccato al bordo dell'immagine**, che è il caso in cui la
    /// prima stesura andava in «Index out of range».
    ///
    /// `CGRect.maxX` è l'estremo escluso, quindi leggere lì significa leggere un
    /// pixel oltre: dentro l'immagine è il primo della riga dopo — carta, cioè un
    /// falso vuoto a destra su OGNI misura — e sull'ultima riga è fuori dal
    /// buffer. Il difetto sbagliava in silenzio quasi sempre e crollava di rado,
    /// che è la combinazione peggiore.
    /// Il guscio arriva all'ultima colonna e all'ultima riga dell'immagine, con la
    /// carta ancora presente dall'altro capo — che è la forma vera del caso, non
    /// un guscio che riempie tutto: senza carta da nessuna parte non ci sarebbero
    /// tre colori e la misura non avrebbe più senso.
    @Test("Un guscio a filo dell'immagine si misura senza uscire dal buffer")
    func aShellFlushWithTheImageEdgeIsSafe() throws {
        let filo = try #require(MisuraMoto.filoAiBordi(
            di: isola(guscio: CGRect(x: 20, y: 20, width: 280, height: 100),
                      filoDa: 20, filoA: 300)))
        #expect(filo.tocca)
        #expect(filo.vuotoDestra <= 2, "vuoto fantasma a destra: \(filo.vuotoDestra)")
    }

    // MARK: - La firma della discesa

    /// Fotogrammi finti, a 60 al secondo, da una coppia larghezza/altezza.
    private func film(_ coppie: [(Int, Int)]) -> [MisuraMoto.Fotogramma] {
        coppie.enumerated().map {
            MisuraMoto.Fotogramma(secondi: Double($0.offset) / 60,
                                  larghezza: $0.element.0, altezza: $0.element.1)
        }
    }

    /// Il polo positivo, ed è la forma vera misurata sul filmato del 2026-08-16:
    /// la larghezza tiene mentre l'altezza si allunga, poi si apre e rimbalza.
    @Test("Una goccia: larghezza ferma, altezza che cresce, poi apertura con rimbalzo")
    func aDropIsRecognised() {
        var righe: [(Int, Int)] = [(0, 0), (0, 0)]                   // prima dell'entrata
        for h in stride(from: 36, through: 256, by: 20) { righe.append((334, h)) }
        for w in stride(from: 360, through: 837, by: 60) { righe.append((w, 256)) }
        righe += [(820, 256), (805, 256), (800, 256), (799, 256), (799, 256)]
        #expect(MisuraMoto.discesaÈUnaGoccia(film(righe)))
    }

    /// **Il polo negativo, e descrive esattamente il difetto riparato**: uno zoom
    /// — larghezza e altezza che crescono insieme — non è una goccia.
    ///
    /// È il movimento che c'era prima che la larghezza ricevesse un ritardo suo.
    /// Il giorno che questo smettesse di essere rosso, il cancello avrebbe smesso
    /// di distinguere le due cose.
    @Test("Uno zoom NON è una goccia")
    func aZoomIsRejected() {
        var righe: [(Int, Int)] = [(0, 0)]
        for k in 0...20 {
            righe.append((334 + k * 24, 36 + k * 11))               // crescono insieme
        }
        righe += [(799, 256), (799, 256), (799, 256), (799, 256)]
        #expect(!MisuraMoto.discesaÈUnaGoccia(film(righe)))
    }

    /// E una larghezza che tiene senza che l'altezza faccia niente non è una
    /// goccia: è un'isola ferma. Senza questa condizione il cancello passerebbe
    /// su un'animazione che non parte.
    @Test("Una larghezza ferma senza allungamento non è una goccia")
    func aStillIslandIsRejected() {
        let righe = Array(repeating: (334, 40), count: 20) + [(700, 40), (680, 40), (680, 40)]
        #expect(!MisuraMoto.discesaÈUnaGoccia(film(righe)))
    }

    /// Il tratto misurato è quello in cui l'isola c'è, non tutto il filmato: è il
    /// difetto che questa funzione aveva alla prima stesura, quando guardava
    /// l'ultimo fotogramma — vuoto per costruzione — e dichiarava che non c'era
    /// niente da misurare.
    @Test("Il tratto salta l'attesa prima e dopo")
    func theRunSkipsTheEmptyFrames() {
        let righe = film([(0, 0), (0, 0), (100, 10), (200, 20), (300, 30), (0, 0), (0, 0)])
        let vivi = MisuraMoto.tratto(righe)
        #expect(vivi.count == 3)
        #expect(vivi.first?.larghezza == 100)
        #expect(vivi.last?.larghezza == 300)
        #expect(MisuraMoto.tratto(film([(0, 0), (0, 0)])).isEmpty)
    }

    // MARK: - La banda dalla matematica

    /// La banda cresce col livello e non torna mai indietro. Una misura che si
    /// invertisse da qualche parte farebbe passare un'onda rotta.
    @Test("La banda cresce con il livello, sempre")
    func theBandIsMonotone() {
        var precedente = -1.0
        for passo in 0...20 {
            let livello = Double(passo) / 20
            let banda = MisuraMoto.banda(livello: livello, passi: 60, istanti: 80)
            #expect(banda >= precedente - 0.001, "la banda è scesa a livello \(livello)")
            #expect(banda <= 1)
            precedente = banda
        }
    }

    /// **Il profilo del contenitore deve ridurre la banda, o non sta facendo
    /// niente.** È il polo che dice che la misura guarda davvero dentro la
    /// pillola invece di dentro un rettangolo immaginario.
    @Test("Dentro la pillola la banda è più stretta che in un rettangolo")
    func theContainerNarrowsTheBand() {
        let guscio = BubbleGeometry.size
        let riquadro = BubbleGeometry.waveSize(in: guscio)
        let dentro = MisuraMoto.banda(livello: 1,
                                      profilo: BubbleGeometry.profile(box: riquadro, in: guscio),
                                      passi: 60, istanti: 80)
        let libera = MisuraMoto.banda(livello: 1, passi: 60, istanti: 80)
        #expect(dentro <= libera)
        // E non l'ha ridotta a niente: la pillola è dritta in mezzo, quindi lì
        // l'onda usa tutta la sua altezza.
        #expect(dentro > libera * 0.8)
    }
}
