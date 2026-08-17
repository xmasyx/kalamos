import AVFoundation
import CoreGraphics
import Foundation

/// **Il pompaggio: l'onda che si gonfia e si sgonfia a ogni sillaba.**
///
/// Il difetto visto sul campo il 2026-08-16, con le sue parole: «si muove troppo
/// troppo troppo, vibra tanto ed è fastidioso a vedersi... non è come dovrebbe
/// essere un audio». Nel suo filmato due fotogrammi distanti mezzo secondo,
/// **entrambi durante il parlato**, mostrano uno un rigonfiamento pieno e l'altro
/// quasi una linea piatta.
///
/// **Nessuna fotografia lo prende, e nemmeno la misura del filmato che c'era.**
/// `MisuraMoto.misura` segue l'INGOMBRO dell'isola, che è il guscio: una pillola
/// opaca di dimensione fissa. Un'onda che collassa a una riga e un'onda che
/// riempie la pillola hanno lo stesso ingombro al pixel. Il pompaggio vive
/// dentro, quindi la misura deve saper distinguere la luce dell'onda dal guscio
/// che la contiene, fotogramma per fotogramma.
///
/// Da qui i tre pezzi di questo file, e stanno insieme perché nessuno dei tre
/// serve senza gli altri due:
///
/// · `ProfiloParlato` — un parlato finto e SCRITTO, che il filmato riproduce
///   uguale ogni volta. Un microfono darebbe un filmato diverso a ogni ripresa,
///   e un livello costante non può mostrare un difetto che esiste solo mentre il
///   volume si muove.
/// · `luceDOnda` — la banda occupata dall'onda dentro il guscio, dai pixel.
/// · `RefertoPompaggio` — i quattro criteri, con i numeri accanto.
enum MisuraPompaggio {

    // MARK: - Il parlato scritto

    /// Il profilo di livello con cui si gira il filmato: RMS grezzo, a passi di
    /// 150 ms, come lo riceverebbe dal microfono.
    ///
    /// **È in RMS e non in altezza già normalizzata**, ed è la scelta che rende
    /// la sonda una sonda: entra dalla stessa porta da cui entra la voce, quindi
    /// attraversa `WaveIsland.normalize` e i due inviluppi veri. Un profilo
    /// scritto in altezze salterebbe la mappa, cioè metà di ciò che è stato
    /// cambiato, e misurerebbe una catena che nell'app non esiste.
    enum ProfiloParlato {
        /// Quanto dura una raffica. Le sillabe di un parlato normale stanno fra
        /// 120 e 250 ms, e 150 è la parte stretta di quella forbice: se il difetto
        /// si vede, si vede qui.
        static let passo: Double = 0.15

        /// **Le raffiche, in RMS.** Alte = sillaba, basse = lo stacco fra due
        /// sillabe, zero = lo stacco fra due parole.
        ///
        /// I picchi stanno fra 0,041 e 0,058, che è il parlato a microfono vicino;
        /// gli stacchi di sillaba fra 0,005 e 0,009, cioè un rapporto di circa
        /// dieci a uno. **Il rapporto è la cosa che conta**: è lui a produrre il
        /// pompaggio con la taratura vecchia, dove ogni stacco si mangia una
        /// frazione fissa dell'altezza.
        ///
        /// **Gli stacchi di sillaba stanno TUTTI sopra `AudioRecorder.speechFloor`
        /// (0,004), e non è un dettaglio.** Alla prima stesura due di essi erano
        /// 0,003 e 0,004, cioè sotto la soglia di silenzio dell'app: la mappa li
        /// azzerava, si appiccicavano allo stacco di parola accanto e il banco
        /// finiva per pretendere che l'onda tenesse attraverso 600 ms di silenzio
        /// VERO. Un profilo che contraddice il proprio commento chiede la cosa
        /// sbagliata e la chiede in silenzio: fra due sillabe di una parola c'è
        /// suono, ed è quello che questi numeri devono dire.
        ///
        /// I due tratti di tre zeri sono gli stacchi fra parole: 450 ms di
        /// silenzio vero, che è il caso duro per una tenuta e la ragione della
        /// misura di `Taratura.viva.tenuta`. Senza di essi il banco proverebbe
        /// solo il caso facile.
        static let raffiche: [Double] = [
            0.050, 0.006, 0.045, 0.005, 0.055, 0.008, 0.041, 0.006,
            0.000, 0.000, 0.000,
            0.052, 0.007, 0.047, 0.005, 0.058, 0.009, 0.043, 0.005,
            0.000, 0.000, 0.000,
            0.049, 0.006, 0.054, 0.005, 0.046,
        ]

        /// Silenzio prima che cominci a parlare. Serve a due criteri: è il muto
        /// con cui si confronta il parlato, ed è la rincorsa dell'attacco.
        static let mutoIniziale: Double = 1.6
        /// Silenzio dopo. Più lungo, perché il rilascio deve avere il tempo di
        /// finire dentro il filmato invece che dopo.
        static let mutoFinale: Double = 2.4
        static var parlato: Double { Double(raffiche.count) * passo }
        static var durata: Double { mutoIniziale + parlato + mutoFinale }

        /// L'RMS al campione `n`, alla cadenza di campionamento dell'app.
        static func rms(campione n: Int) -> Double {
            let t = Double(n) / WaveIsland.samplesPerSecond
            guard t >= mutoIniziale else { return 0 }
            let dentro = t - mutoIniziale
            guard dentro < parlato else { return 0 }
            return raffiche[min(raffiche.count - 1, Int(dentro / passo))]
        }

        // MARK: Le finestre in cui si misura, in secondi dall'arrivo dell'isola
        //
        // **Il tempo zero è il primo fotogramma in cui l'isola compare, non il
        // primo fotogramma del filmato.** `screencapture` non promette di partire
        // nell'istante in cui glielo si chiede, e legare le finestre all'istante
        // del comando vorrebbe dire misurare il parlato con un ritardo ignoto —
        // il tipo di errore che sposta ogni numero di poco e nessun cancello
        // vede. Il filmato si sincronizza da sé, come fa già `MisuraMoto.tratto`.

        /// Quanto si lascia all'entrata dell'isola prima di credere ai numeri:
        /// mentre la pillola si apre, la sua altezza non è quella dell'onda.
        /// Comodamente più della transizione d'entrata
        /// (`WaveIsland.durataTransizione`, 0,24 s dal 17/08 — era una molla di
        /// 0,40). Il margine è rimasto largo di proposito: questa finestra non
        /// misura l'entrata, la SALTA, e stringerla al nuovo valore comprerebbe
        /// tre decimi di parlato in più al prezzo di far dipendere il banco dal
        /// numero che l'animazione può cambiare domani.
        static let assestamento: Double = 0.6
        /// La rampa d'attacco, dichiarata: il criterio della tenuta guarda il
        /// parlato ASSESTATO, e misurare la salita dentro la tenuta darebbe un
        /// minimo che è la partenza, non un collasso.
        static let attaccoDichiarato: Double = 0.45
        /// La coda di rilascio, dichiarata: tenuta più rilascio valgono circa
        /// 1,35 s, e il silenzio si giudica quando è arrivato, non mentre arriva.
        static let codaDichiarata: Double = 1.5

        /// **Il margine per lo scarto fra il campione zero e il primo fotogramma
        /// misurabile.** Il profilo comincia a suonare nell'istante in cui il
        /// pannello viene ordinato a schermo, ma l'isola diventa *misurabile*
        /// qualche fotogramma dopo, mentre l'entrata la sta ancora aprendo: il
        /// tempo zero trovato sui pixel è quindi sistematicamente in ritardo di
        /// circa un decimo di secondo. Misurato, non temuto — al primo giro il
        /// criterio dell'attacco è uscito zero proprio per questo. Ogni finestra
        /// si tiene alla larga di tanto dai propri bordi.
        static let scartoDiSincronia: Double = 0.25

        static var finestraMuta: ClosedRange<Double> { assestamento...(mutoIniziale - scartoDiSincronia) }
        static var finestraParlata: ClosedRange<Double> {
            (mutoIniziale + attaccoDichiarato)...(mutoIniziale + parlato - scartoDiSincronia)
        }
        static var finestraCoda: ClosedRange<Double> {
            (mutoIniziale + parlato + codaDichiarata)...durata
        }
    }

    // MARK: - La luce dell'onda, dai pixel

    struct LuceDOnda {
        /// Estensione verticale della luce d'onda, in pixel: il numero che pompa.
        let banda: Int
        /// Per ogni colonna dell'area analizzata, quanti pixel di luce contiene.
        /// Serve al viaggio: una figura che si ripete spostata è una cresta che
        /// cammina.
        let colonne: [Int]
        let carta: (Int, Int, Int)
        let guscio: (Int, Int, Int)
    }

    /// Separa carta, guscio e onda, e misura la banda occupata dall'onda.
    ///
    /// **Il pezzo senza cui tutto il resto è aria è l'EROSIONE.** Il bordo di una
    /// pillola arrotondata è antialiasato: una corona di pixel larga uno o due
    /// che non è né carta né guscio, e che una misura ingenua conta come onda —
    /// dando una banda costante, pari all'altezza dell'intero guscio, in ogni
    /// fotogramma. Sarebbe un numero stabilissimo e completamente falso, cioè la
    /// specie peggiore di verde. Erodendo la maschera del non-carta di `erosione`
    /// pixel la corona esce, e ne esce anche sulle due calotte, dove un margine
    /// rettangolare non basterebbe.
    ///
    /// Tre colori come in `MisuraMoto.filoAiBordi`, e per la stessa ragione:
    /// cercare «ciò che non è carta» troverebbe il guscio e direbbe sempre pieno.
    ///
    /// La tolleranza di default è **importata** da `MisuraMoto.tolleranzaFilmato`
    /// e non ricopiata: quel numero è largo perché la carta di un filmato esce
    /// dal codificatore a riquadri leggermente diversi fra loro, e il giorno che
    /// cambia deve cambiare anche qui (OperationalLessons, 2026-08-05).
    /// Che cosa c'è in un fotogramma. Tre casi e non due, perché «non ho misurato
    /// niente» e «questo non è nemmeno il mio soggetto» chiedono due riparazioni
    /// diverse, e una sola risposta nulla le confonderebbe.
    enum Esame {
        /// Non è la carta della sonda: lo schermo di qualcun altro.
        case estranea
        /// La carta della sonda, senza isola: normale prima dell'entrata e dopo
        /// l'uscita.
        case carta
        case isola(LuceDOnda)

        var luce: LuceDOnda? { if case .isola(let l) = self { return l } else { return nil } }
    }

    static func luceDOnda(di image: CGImage,
                          tolleranza: Int = MisuraMoto.tolleranzaFilmato,
                          erosione: Int = 3) -> Esame {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return .estranea }
        guard let box = MisuraMoto.riquadro(di: image, tolleranza: tolleranza) else { return .carta }
        // **Un fotogramma che non è la carta della sonda si butta**, e serve
        // davvero: `screencapture` comincia a registrare prima che la finestra di
        // carta sia composta, quindi i primi fotogrammi sono lo schermo di chi
        // sviluppa — nel primo giro, il suo terminale. Lì dentro c'è di tutto, la
        // separazione in tre colori trova «luce d'onda» ovunque, e la
        // sincronizzazione del referto crede che l'isola sia arrivata al secondo
        // zero: da lì ogni finestra scivola di un secondo e ogni numero esce
        // sbagliato restando plausibile.
        //
        // Il segno che distingue i due casi è netto e non chiede di conoscere la
        // geometria dell'isola: su carta l'ingombro è l'isoletta, che è una
        // striscia bassa; su uno schermo qualunque l'ingombro è tutto il
        // fotogramma. Mezza altezza sta comodamente in mezzo — l'isola ne occupa
        // circa un quinto.
        guard box.height * 2 < CGFloat(h) else { return .estranea }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .estranea }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func colore(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func distanza(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }

        // L'area di lavoro è l'ingombro CRESCIUTO di `erosione`: la finestra di
        // erosione deve poter vedere la carta che sta FUORI dall'isola, altrimenti
        // sulla prima colonna del guscio non troverebbe carta da nessuna parte e
        // dichiarerebbe interno proprio il bordo che esiste per togliere.
        // `maxX`/`maxY` di un `CGRect` sono l'estremo escluso, come in
        // `filoAiBordi`: da lì il meno uno.
        let ax = max(0, Int(box.minX) - erosione), bx = min(w - 1, Int(box.maxX) - 1 + erosione)
        let ay = max(0, Int(box.minY) - erosione), by = min(h - 1, Int(box.maxY) - 1 + erosione)
        let ww = bx - ax + 1, hh = by - ay + 1
        guard ww > 2 * erosione + 1, hh > 2 * erosione + 1 else { return .estranea }
        let carta = colore(0, 0)

        // Immagine integrale del «è carta»: il conteggio della carta in una
        // finestra quadrata si legge in quattro accessi invece che in (2r+1)². Su
        // qualche centinaio di fotogrammi la differenza fra le due forme è fra
        // secondi e minuti, e una sonda che nessuno ha voglia di far girare non
        // gira.
        let passo = ww + 1
        var somma = [Int](repeating: 0, count: passo * (hh + 1))
        for j in 0..<hh {
            var riga = 0
            for i in 0..<ww {
                riga += distanza(colore(ax + i, ay + j), carta) <= tolleranza ? 1 : 0
                somma[(j + 1) * passo + i + 1] = somma[j * passo + i + 1] + riga
            }
        }
        func interno(_ i: Int, _ j: Int) -> Bool {
            guard i >= erosione, j >= erosione, i + erosione < ww, j + erosione < hh else { return false }
            let a = i - erosione, b = i + erosione, c = j - erosione, d = j + erosione
            let cartaDentro = somma[(d + 1) * passo + b + 1] - somma[c * passo + b + 1]
                - somma[(d + 1) * passo + a] + somma[c * passo + a]
            return cartaDentro == 0
        }

        // Il guscio è il colore più frequente fra i pixel interni. Contato sugli
        // interni e non sull'ingombro intero perché gli angoli dell'ingombro di
        // una capsula sono carta, e un modo calcolato su quelli misurerebbe la
        // carta invece del guscio.
        var conteggio: [Int: Int] = [:]
        for j in 0..<hh {
            for i in 0..<ww where interno(i, j) {
                let c = colore(ax + i, ay + j)
                conteggio[(c.0 >> 3) << 10 | (c.1 >> 3) << 5 | (c.2 >> 3), default: 0] += 1
            }
        }
        guard let modo = conteggio.max(by: { $0.value < $1.value })?.key else { return .carta }
        let guscio = ((modo >> 10 & 31) << 3, (modo >> 5 & 31) << 3, (modo & 31) << 3)

        var colonne = [Int](repeating: 0, count: ww)
        var minY = hh, maxY = -1
        for j in 0..<hh {
            for i in 0..<ww where interno(i, j) {
                guard distanza(colore(ax + i, ay + j), guscio) > tolleranza else { continue }
                colonne[i] += 1
                if j < minY { minY = j }
                if j > maxY { maxY = j }
            }
        }
        return .isola(LuceDOnda(banda: maxY >= minY ? maxY - minY + 1 : 0,
                                colonne: colonne, carta: carta, guscio: guscio))
    }

    /// **Di quanti pixel la figura si è spostata**, fra i profili di due
    /// fotogrammi consecutivi. Positivo = verso destra.
    ///
    /// Si minimizza lo scarto assoluto MEDIO invece di massimizzare il prodotto
    /// scalare: il prodotto premia lo spostamento zero, perché è quello con la
    /// sovrapposizione più larga, e una misura del viaggio che tende a rispondere
    /// «fermo» è la misura sbagliata per giudicare se qualcosa viaggia. Media per
    /// colonna, così la sovrapposizione più corta agli estremi non conta due
    /// volte.
    ///
    /// **La posizione della singola cresta più alta non servirebbe**, e vale la
    /// pena scriverlo perché è la misura che verrebbe in mente per prima: i
    /// nastri sono cinque, a frequenze diverse, e il massimo globale salta da una
    /// cresta all'altra anche mentre l'intero disegno scorre regolare. Ciò che si
    /// sposta con continuità è la FIGURA.
    static func scorrimento(_ a: [Int], _ b: [Int], massimo: Int = 24) -> Int? {
        guard a.count == b.count, a.count > 2 * massimo + 2 else { return nil }
        guard a.contains(where: { $0 > 0 }), b.contains(where: { $0 > 0 }) else { return nil }
        var migliore = (scarto: Double.greatestFiniteMagnitude, spostamento: 0)
        for L in -massimo...massimo {
            let da = max(0, -L), fino = min(a.count - 1, a.count - 1 - L)
            guard fino > da else { continue }
            var totale = 0
            for i in da...fino { totale += abs(a[i] - b[i + L]) }
            let scarto = Double(totale) / Double(fino - da + 1)
            if scarto < migliore.scarto { migliore = (scarto, L) }
        }
        return migliore.spostamento
    }

    // MARK: - Il filmato, misurato

    struct FotogrammaOnda {
        /// Secondi dall'inizio del filmato.
        let secondi: Double
        let banda: Int
        let colonne: [Int]
        /// I due colori su cui la separazione si è basata. **Vanno portati fin
        /// nel referto**: se un giorno la maschera si rompe — carta e guscio che
        /// escono uguali, o un guscio che è in realtà la carta — ogni numero qui
        /// sopra resta plausibile e diventa falso, e questa è l'unica riga in cui
        /// il guasto si vede.
        let carta: (Int, Int, Int)
        let guscio: (Int, Int, Int)
        /// Non era la carta della sonda. Contato e riportato, mai taciuto: se
        /// fossero molti, il filmato riprende lo schermo di qualcun altro e
        /// nessuno degli altri numeri vale niente.
        let estranea: Bool
        var haIsola: Bool { !colonne.isEmpty }
    }

    static func misura(filmato url: URL, passo: Double = 1.0 / 30) async throws -> [FotogrammaOnda] {
        let asset = AVURLAsset(url: url)
        let durata = try await asset.load(.duration).seconds
        guard durata.isFinite, durata > 0 else { return [] }

        let generatore = AVAssetImageGenerator(asset: asset)
        generatore.appliesPreferredTrackTransform = true
        generatore.requestedTimeToleranceBefore = .zero
        generatore.requestedTimeToleranceAfter = .zero

        var righe: [FotogrammaOnda] = []
        var t = 0.0
        while t < durata {
            let tempo = CMTime(seconds: t, preferredTimescale: 600)
            guard let immagine = try? await generatore.image(at: tempo).image else {
                t += passo
                continue
            }
            let esame = luceDOnda(di: immagine)
            let luce = esame.luce
            righe.append(FotogrammaOnda(secondi: t,
                                        banda: luce?.banda ?? 0,
                                        colonne: luce?.colonne ?? [],
                                        carta: luce?.carta ?? (0, 0, 0),
                                        guscio: luce?.guscio ?? (0, 0, 0),
                                        estranea: { if case .estranea = esame { return true } else { return false } }()))
            t += passo
        }
        return righe
    }

    // MARK: - Il referto, coi quattro criteri

    /// Le soglie, in un posto solo: la sonda le stampa, le prove le importano.
    enum Soglia {
        /// Dentro il parlato la banda non collassa: il minimo sta almeno a questa
        /// frazione del massimo. Col suo filmato del 16/08 crolla quasi a zero.
        static let tenuta: Double = 0.60
        /// Il muto sta sotto un quarto del parlato — cioè il rapporto di 4×
        /// misurato quel giorno, tenuto.
        static let quiete: Double = 0.25
        /// L'attacco dura più di tre fotogrammi: sotto è uno scalino.
        static let fotogrammiDiAttacco = 3
        /// Quota di coppie consecutive in cui la figura va avanti.
        static let quotaInAvanti: Double = 0.80
    }

    struct RefertoPompaggio {
        let fotogrammi: Int
        let estranei: Int
        let arrivoIsola: Double
        let bandaMuta: Double
        let bandaParlata: Double
        let bandaCoda: Double
        let minimoParlato: Int
        let massimoParlato: Int
        let fotogrammiDiAttacco: Int
        let scorrimentoMediano: Int
        let quotaInAvanti: Double
        let carta: (Int, Int, Int)
        let guscio: (Int, Int, Int)

        var tenuta: Double { massimoParlato > 0 ? Double(minimoParlato) / Double(massimoParlato) : 0 }
        var quiete: Double { bandaParlata > 0 ? bandaMuta / bandaParlata : 1 }

        var criterio1: Bool { tenuta >= Soglia.tenuta }
        var criterio2: Bool { quiete <= Soglia.quiete }
        var criterio3: Bool { fotogrammiDiAttacco > Soglia.fotogrammiDiAttacco }
        var criterio4: Bool { scorrimentoMediano > 0 && quotaInAvanti >= Soglia.quotaInAvanti }
        var passa: Bool { criterio1 && criterio2 && criterio3 && criterio4 }

        var testo: String {
            func riga(_ ok: Bool, _ nome: String, _ dettaglio: String) -> String {
                let steso = nome.count < 34 ? nome + String(repeating: " ", count: 34 - nome.count) : nome
                return "  \(ok ? "✓" : "✗") \(steso) \(dettaglio)"
            }
            return """
            fotogrammi \(fotogrammi) · scartati \(estranei) (non è la carta della sonda) \
            · isola dal secondo \(String(format: "%.2f", arrivoIsola))
            carta rgb(\(carta.0),\(carta.1),\(carta.2)) · guscio rgb(\(guscio.0),\(guscio.1),\(guscio.2))
            banda: muta \(String(format: "%.1f", bandaMuta)) px · parlata \(String(format: "%.1f", bandaParlata)) px \
            (da \(minimoParlato) a \(massimoParlato)) · coda \(String(format: "%.1f", bandaCoda)) px

            \(riga(criterio1, "1 · non collassa nel parlato",
                   String(format: "min/max %.2f (serve ≥ %.2f)", tenuta, Soglia.tenuta)))
            \(riga(criterio2, "2 · in silenzio è una linea",
                   String(format: "muto/parlato %.2f (serve ≤ %.2f)", quiete, Soglia.quiete)))
            \(riga(criterio3, "3 · l'attacco è morbido",
                   "\(fotogrammiDiAttacco) fotogrammi (serve > \(Soglia.fotogrammiDiAttacco))"))
            \(riga(criterio4, "4 · le creste viaggiano",
                   String(format: "%+d px per fotogramma, avanti nel %.0f%% delle coppie (serve ≥ %.0f%%)",
                          scorrimentoMediano, quotaInAvanti * 100, Soglia.quotaInAvanti * 100)))
            """
        }
    }

    /// Il verdetto, dai fotogrammi e dalla scaletta scritta in `ProfiloParlato`.
    ///
    /// **Il tempo zero si trova, non si assume**: è il primo fotogramma in cui
    /// l'isola compare. Da lì in poi le finestre sono quelle dichiarate nel
    /// profilo, così una ripresa che parte con un decimo di ritardo misura
    /// esattamente le stesse cose.
    static func referto(_ righe: [FotogrammaOnda]) -> RefertoPompaggio? {
        guard let inizio = righe.firstIndex(where: { $0.haIsola && $0.banda > 0 }) else { return nil }
        let zero = righe[inizio].secondi
        let vivi = righe[inizio...]

        func dentro(_ finestra: ClosedRange<Double>) -> [FotogrammaOnda] {
            vivi.filter { finestra.contains($0.secondi - zero) }
        }
        func mediana(_ valori: [Int]) -> Double {
            guard !valori.isEmpty else { return 0 }
            let ordinati = valori.sorted()
            return Double(ordinati[ordinati.count / 2])
        }

        let muti = dentro(ProfiloParlato.finestraMuta)
        let parlati = dentro(ProfiloParlato.finestraParlata)
        let code = dentro(ProfiloParlato.finestraCoda)
        guard !muti.isEmpty, parlati.count > 4 else { return nil }

        let bandeParlate = parlati.map(\.banda)
        let bandaParlata = mediana(bandeParlate)

        // L'attacco: da quando la banda lascia il muto a quando ha raggiunto i
        // nove decimi del parlato. Il conto è dei fotogrammi che stanno in mezzo,
        // cioè di quanto dura il movimento — che è la domanda: uno scalino dura
        // un fotogramma solo.
        //
        // **Non si cerca dentro una finestra, si cerca nei dati**, e la prima
        // stesura sbagliava proprio qui: la salita cominciava due fotogrammi
        // prima del bordo della finestra, dentro non c'era nessun fotogramma
        // ancora basso, e il criterio usciva zero — cioè «scalino» — su un
        // attacco che nei numeri durava cinque fotogrammi. Una finestra stretta
        // attorno a un evento che si vuole DATARE è una misura che presuppone
        // ciò che deve trovare.
        let bandaMuta = mediana(muti.map(\.banda))
        let sogliaBassa = bandaMuta * 1.25
        let sogliaAlta = bandaParlata * 0.9
        let dopoIlMuto = Array(vivi.filter { $0.secondi - zero > ProfiloParlato.finestraMuta.lowerBound })
        // Si cerca prima l'ARRIVO e poi si torna indietro alla partenza, non il
        // contrario: l'ultimo fotogramma basso del filmato sta nel silenzio
        // finale, dopo il rilascio, e partire da lì cercherebbe una salita che
        // non arriva mai.
        var fotogrammiDiAttacco = 0
        if let arrivo = dopoIlMuto.firstIndex(where: { Double($0.banda) >= sogliaAlta }),
           let partenza = dopoIlMuto[..<arrivo].lastIndex(where: { Double($0.banda) <= sogliaBassa }) {
            fotogrammiDiAttacco = arrivo - partenza
        }

        // Il viaggio, sulle coppie consecutive del parlato.
        var spostamenti: [Int] = []
        for k in 1..<parlati.count {
            guard let s = scorrimento(parlati[k - 1].colonne, parlati[k].colonne) else { continue }
            spostamenti.append(s)
        }
        let avanti = spostamenti.filter { $0 > 0 }.count
        let quota = spostamenti.isEmpty ? 0 : Double(avanti) / Double(spostamenti.count)

        let campione = righe[inizio]
        return RefertoPompaggio(
            fotogrammi: righe.count,
            estranei: righe.filter(\.estranea).count,
            arrivoIsola: zero,
            bandaMuta: bandaMuta,
            bandaParlata: bandaParlata,
            bandaCoda: mediana(code.map(\.banda)),
            minimoParlato: bandeParlate.min() ?? 0,
            massimoParlato: bandeParlate.max() ?? 0,
            fotogrammiDiAttacco: fotogrammiDiAttacco,
            scorrimentoMediano: spostamenti.isEmpty ? 0 : spostamenti.sorted()[spostamenti.count / 2],
            quotaInAvanti: quota,
            carta: campione.carta, guscio: campione.guscio)
    }

    /// La tabella, una riga per fotogramma: si legge quando un criterio è rosso e
    /// si vuole sapere DOVE.
    static func tabella(_ righe: [FotogrammaOnda]) -> String {
        var out = "  t(s)   banda\n"
        for r in righe { out += String(format: "  %5.3f  %5d\n", r.secondi, r.banda) }
        return out
    }
}
