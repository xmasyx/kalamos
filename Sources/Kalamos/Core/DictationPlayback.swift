import AVFoundation
import Foundation

/// The arithmetic and the labels of playing a dictation back, with no player in
/// sight.
///
/// Split out from `DictationPlayer` on purpose: everything a test can be wrong
/// about lives here — where a drag lands, what the clock reads, what happens at
/// the two ends of the bar — while the part that needs a real audio device is a
/// thin shell around `AVAudioPlayer`. A test that has to open an output device to
/// check that 8.4 seconds prints as `0:08` is measuring the machine.
enum Playback {

    /// The three speeds, sua richiesta del 2026-08-16: half for the syllable you
    /// cannot make out, normal, and half again for walking through a long one.
    ///
    /// It replaced a single «Lento» toggle at 0.6. The number mattered less than
    /// the shape: a toggle tells you what pressing it does, three buttons tell
    /// you where you already are.
    static let speeds: [Float] = [0.5, 1.0, 1.5]
    static let normalRate: Float = 1.0

    /// `0,5×` in Italian, `0.5×` elsewhere: it is a number on a button, and a
    /// decimal point in the wrong shape is the sort of thing he notices.
    @MainActor
    static func speedLabel(_ rate: Float) -> String {
        let s = String(format: "%.1f", rate)
        return L.t(s.replacingOccurrences(of: ".", with: ",") + "×", s + "×",
                   s.replacingOccurrences(of: ".", with: ",") + "×")
    }

    /// Where the playhead sits, 0…1. A duration of zero is a file that carries no
    /// audio, and it reads as the beginning rather than as a division by zero.
    static func fraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return clamp(elapsed / duration)
    }

    /// Where a drag lands, in seconds. The bar is the whole width of the strip,
    /// so a finger that overshoots either end means the end, not an error.
    static func seconds(fraction: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return clamp(fraction) * duration
    }

    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// `m:ss`, always two digits on the seconds so the label stops jittering
    /// under the eye as it counts. Negative and non-finite come out as `0:00`:
    /// an unreadable file reports a duration of NaN and the clock is not the
    /// place to discover it.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `0:08 / 0:21` — where you are and how much there is.
    static func label(elapsed: Double, duration: Double) -> String {
        "\(clock(elapsed)) / \(clock(duration))"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Guadagno — alzare il volume OLTRE l'originale, senza distorcere
//
// Sua richiesta, 2026-08-17: «spesso le mie registrazioni si sentono male», e poi
// «percentuali per l'audio a volume maggiore. 25-50-75-100», e infine «per volume
// audio voglio anche uno slider per i dB + e −».
//
// **Perché il guadagno si applica ai CAMPIONI e non a un nodo di effetti.**
// `AVAudioPlayer.volume` si ferma a 1,0, quindi serviva altro comunque, e le due
// strade possibili erano una catena `AVAudioUnitEQ` + limitatore dentro il motore,
// oppure questa. Ha vinto questa per una ragione sola: il brief chiede di
// MISURARE il picco in uscita e la distorsione, e una catena di AudioUnit è
// opaca — per misurarla dovrei renderizzarla offline e il banco finirebbe per
// misurare una seconda implementazione. Qui la funzione che suona è la funzione
// che il test esegue e che la sonda misura, che è la regola di casa (2026-08-05,
// la sonda che riscrive la logica che deve misurare).
//
// Il prezzo è dichiarato: cambiare guadagno ricalcola il buffer. Su una dettatura
// di 15 s mono a 16 kHz sono 240.000 moltiplicazioni, cioè meno di un millesimo
// di secondo — meno del tempo che ci mette la pastiglia a disegnarsi.
// ─────────────────────────────────────────────────────────────────────────────

enum Guadagno {

    /// **Dove deve atterrare il picco al massimo della scala.**
    ///
    /// 0,9 e non 1,0: un decimo di margine perché il picco campionato di un file
    /// non è il picco del segnale ricostruito fra due campioni, che può stare
    /// leggermente sopra.
    static let bersaglio: Float = 0.9

    /// Il tetto assoluto, in dB. Serve solo alle registrazioni molto piane, dove
    /// portare il picco al bersaglio chiederebbe più di così: oltre questo si
    /// alzerebbe soprattutto il rumore di stanza.
    static let massimoDB: Float = 24
    /// Il passo dei bottoni `+` e `−`.
    static let passoDB: Float = 1

    /// **Quanto si può spingere QUESTO file, in dB** — ed è la correzione che ha
    /// salvato il disegno.
    ///
    /// La prima versione aveva una scala fissa 0…24 dB uguale per tutti. Misurata
    /// con `--sonda-guadagno`, dava **22–33% di distorsione armonica**, cioè
    /// esattamente la «distorsione becera» che il brief vieta: su un file già a
    /// fondo scala, ×16 non è amplificare, è fare un'onda quadra, e nessun
    /// limitatore lo ripara — non c'è dove mettere il segnale.
    ///
    /// Il guadagno utile non è una costante, è una proprietà del file. Misurato
    /// sui suoi 120: picco mediano **−20,6 dBFS**, spazio tipico **+18…+22 dB**,
    /// e **un solo file su 120** a fondo scala. Le sue registrazioni sono piane
    /// davvero, come diceva lui, e legare la scala allo spazio dà tutta la spinta
    /// che serve senza mai arrivare al limitatore.
    ///
    /// Zero è una risposta legittima: su un file già pieno non c'è spinta da dare,
    /// e la striscia lo dice non mostrando il comando invece di offrirne uno che
    /// distorce.
    static func spazio(picco: Float) -> Float {
        guard picco > 0 else { return 0 }
        return min(massimoDB, max(0, 20 * log10(bersaglio / picco)))
    }

    /// Le pastiglie, in percentuale. **Lo zero è una di loro** e non uno stato
    /// implicito: il brief chiede che «sia ovvio a colpo d'occhio come si torna al
    /// suono nudo», e una pastiglia che si preme è più ovvia di uno slider da
    /// riportare a sinistra. Tutte e cinque hanno la stessa larghezza di etichetta,
    /// che è la regola dei selettori (MacAppRules §7).
    static let quote: [Int] = [0, 25, 50, 75, 100]

    /// **La percentuale è lineare nei dB, ed è il punto della scala.**
    ///
    /// Il brief lo chiede esplicitamente: «non quattro numeri lineari sul guadagno
    /// lineare che all'ascolto danno tre gradini uguali e uno enorme». I dB sono
    /// già logaritmici nell'ampiezza, quindi passi uguali in dB sono passi uguali
    /// all'orecchio. Su una registrazione tipica sua (picco −20,6 dBFS, spazio
    /// +19,7 dB) le quattro pastiglie danno +4,9 · +9,9 · +14,8 · +19,7 dB, cioè
    /// ampiezza ×1,8 · ×3,1 · ×5,5 · ×9,7 — quattro gradini identici all'orecchio.
    /// Le stesse quattro percentuali applicate al guadagno LINEARE avrebbero dato
    /// un salto grosso e poi tre quasi indistinguibili.
    ///
    /// Il cento per cento è **lo spazio di questo file**, non un numero fisso: è
    /// «spingi questa registrazione fin dove può arrivare pulita».
    static func dB(perQuota q: Int, spazio: Float) -> Float { spazio * Float(q) / 100 }

    /// La pastiglia che corrisponde a questo guadagno, o `nil` se sta in mezzo a
    /// due. Nil è un'informazione e va disegnata come tale: tirando lo slider fra
    /// due pastiglie non deve restarne accesa una che mente sul valore vero.
    static func quota(perDB dB: Float, spazio: Float) -> Int? {
        quote.first { abs(self.dB(perQuota: $0, spazio: spazio) - dB) < 0.5 }
    }

    /// Da dB a fattore di ampiezza.
    static func lineare(dB: Float) -> Float { pow(10, dB / 20) }

    static func clamp(_ dB: Float, spazio: Float) -> Float { min(max(dB, 0), spazio) }

    /// **Il ginocchio del limitatore, ed è il bersaglio stesso.**
    ///
    /// Sotto, il campione passa ESATTAMENTE com'è: nessuna distorsione, nemmeno un
    /// millesimo. Messo al bersaglio, la conseguenza è che percorrendo la scala
    /// fino al 100% il limitatore **non entra mai in funzione**, perché il picco ci
    /// arriva esattamente sopra e non oltre.
    ///
    /// Questo è voluto e non è un limitatore inutile: la distorsione si **previene**
    /// scegliendo un guadagno che il file regge, e il limitatore resta la rete
    /// sotto — per l'arrotondamento del passo da 1 dB, e per il picco fra due
    /// campioni che il picco campionato non vede. Un limitatore che lavora di
    /// continuo è un guadagno scelto male.
    static let ginocchio: Float = bersaglio

    /// Il limitatore morbido: lineare fino al ginocchio, poi comprime verso 1 e
    /// non ci arriva mai.
    ///
    /// La curva è `tanh` riscalata sul tratto che resta, e la scelta non è
    /// estetica: raccordata così, la derivata vale 1 da entrambe le parti del
    /// ginocchio, quindi non c'è nessuno spigolo da cui nascono armoniche. Uno
    /// spigolo, anche piccolo, si sente come asprezza molto prima di comparire in
    /// un numero.
    /// Il tetto a cui il limitatore tende, e **non è 1,0**.
    ///
    /// In aritmetica esatta `tanh` non arriva mai a uno, quindi 1,0 sarebbe un
    /// asintoto irraggiungibile; in `Float` ci arriva, perché `tanh(4)` arrotonda
    /// già a 1,0. Un campione a esattamente fondo scala non è «sopra lo zero», ma
    /// è il posto da cui nasce l'extra fra due campioni che il picco campionato
    /// non vede. Un millesimo sotto costa niente e rende «mai a fondo scala» vero
    /// anche dopo l'arrotondamento.
    static let tetto: Float = 0.999

    static func limita(_ x: Float) -> Float {
        let a = abs(x)
        guard a > ginocchio else { return x }
        let resto = tetto - ginocchio
        let y = ginocchio + resto * tanh((a - ginocchio) / resto)
        return x < 0 ? -y : y
    }

    /// I campioni amplificati e limitati. A guadagno zero **non tocca niente** e
    /// restituisce l'ingresso: il suono nudo dev'essere il suono nudo, bit per
    /// bit, non «quasi».
    static func applica(_ campioni: [Float], dB: Float) -> [Float] {
        guard dB > 0 else { return campioni }
        let k = lineare(dB: dB)
        return campioni.map { limita($0 * k) }
    }

    /// Il picco campionato, che è l'ingresso di `spazio(picco:)`.
    static func picco(_ campioni: [Float]) -> Float {
        campioni.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// `originale` a zero, `+6 dB` sopra. Il nome del punto di partenza scritto per
    /// esteso è quello che rende riconoscibile il suono nudo senza spiegazioni.
    @MainActor
    static func etichetta(_ dB: Float) -> String {
        guard dB > 0.01 else { return L.t("originale", "original", "original") }
        return String(format: "+%.0f dB", dB)
    }
}

/// Plays one archived dictation back, for the panel that asks what you had said.
///
/// **The resource lives as long as the use, not as long as the object** (the
/// rule the headphone crash paid for on 2026-08-14). Nothing is open until
/// `load`, everything closes on `unload`, and the ticking timer exists only
/// while sound is actually coming out. Between one panel and the next there is
/// no audio client of this app for a device change to hit.
/// **Riscritto da `AVAudioPlayer` a `AVAudioEngine` il 2026-08-17**, e il motivo è
/// uno solo: `AVAudioPlayer.volume` è tagliato a 1,0, quindi con quello «alzare il
/// volume oltre l'originale» non si può fare, punto. Il resto del comportamento —
/// dove atterra una trascinata, cosa legge l'orologio, il riascolto di una
/// finita — non è cambiato, e i test che lo dicono sono gli stessi di prima.
@MainActor
final class DictationPlayer: NSObject, ObservableObject {

    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = Playback.normalRate { didSet { tempo.rate = rate } }

    /// Il guadagno, in dB. **Le pastiglie e lo slider sono due viste di QUESTO**,
    /// non due impostazioni: la pastiglia si accende leggendo questo valore, e lo
    /// slider lo scrive. Due stati separati che si rincorrono sono il modo in cui
    /// due comandi della stessa cosa finiscono per dire numeri diversi.
    /// **Sola lettura da fuori, e si cambia con `imposta(dB:)`.**
    ///
    /// La prima versione era una `@Published var` con un `didSet` che si
    /// riassegnava per limitarsi e scriveva `AppState` — e ha fatto **crashare il
    /// pannello con SIGSEGV**, stack esaurito dentro l'aggiornamento di SwiftUI.
    /// La causa è la forma, non il valore: un `didSet` con effetti collaterali su
    /// una proprietà osservata si innesca anche quando è il CODICE a scrivere il
    /// valore — all'apertura del file — e quello scrive uno stato osservato da
    /// altre viste mentre le viste si stanno costruendo.
    ///
    /// Separare le due strade toglie il problema alla radice invece di spezzare
    /// l'anello con una guardia: `imposta(dB:)` è la mano dell'utente e fa tutto
    /// (limita, ricorda, riprogramma), mentre l'apertura del file scrive il valore
    /// e basta.
    @Published private(set) var guadagnoDB: Float = 0

    /// Quanto questo file può essere spinto, in dB. Zero significa che non c'è
    /// spinta da dare e la striscia non disegna il comando.
    @Published private(set) var spazioDB: Float = 0

    private let motore = AVAudioEngine()
    private let nodo = AVAudioPlayerNode()
    /// Il cambio di velocità che NON alza il tono, come faceva `enableRate`.
    private let tempo = AVAudioUnitTimePitch()

    /// I campioni come stanno sul disco. Tenuti perché il guadagno si riapplica
    /// dall'originale ogni volta: partire dal buffer già amplificato
    /// accumulerebbe limitazione su limitazione, e due passaggi al 50% non fanno
    /// il 100% — fanno un suono impastato che nessuno ha chiesto.
    private var originali: [Float] = []
    private var formato: AVAudioFormat?
    private var ticker: Timer?
    /// Da dove è partita la riproduzione corrente, in secondi. Il nodo conta i
    /// fotogrammi da quando è stato avviato, non dall'inizio del file.
    private var partenza: Double = 0
    /// Manopola dei TEST: uscita muta. I test della gara suonano davvero — è
    /// il punto: esercitano il motore vero — ma il segnale di prova è un'onda
    /// che alterna segno a ogni campione a 16 kHz, cioè un tono puro a 8 kHz,
    /// e per un pomeriggio ogni corsa della suite ha fischiato dalle casse del
    /// suo Mac mentre lui dettava (2026-08-17, «ha fatto il fischio anche
    /// ora»; il tono sta pure dentro una sua registrazione, a 7,9 kHz). Il
    /// mixer a zero non cambia i tempi né i completion: cambia solo chi sente.
    nonisolated(unsafe) static var probeMuto = false

    /// **C'è un'uscita audio su cui suonare?** Sembra una domanda oziosa su un
    /// portatile e non lo è: un Mac senza dispositivo d'uscita esiste — tutti
    /// staccati, una macchina headless, l'istante di un cambio di dispositivo —
    /// e in quel caso il mixer nasce a **zero canali**. Collegargli un formato
    /// vero non solleva un errore Swift: fa scattare un'asserzione dentro
    /// AVFoundation, che **uccide il processo** e non passa da nessun `catch`.
    /// È la stessa famiglia del crash delle cuffie del 14/08, una risorsa di
    /// sistema che sparisce sotto un grafo audio, e la riparazione è la stessa
    /// forma: guardare com'è il mondo ADESSO invece di darlo per scontato.
    ///
    /// L'ha trovato il runner GitHub, che una scheda audio non ce l'ha: la
    /// suite che riproduce davvero moriva di SIGTRAP mentre la gemella di sola
    /// matematica passava (corsa 32062600856, 17/08).
    /// `nonisolated` perché non tocca niente dell'istanza — chiede al sistema
    /// com'è fatto adesso — e perché la condizione di una suite di test vive in
    /// una closure `Sendable`, che da una proprietà isolata al MainActor non
    /// potrebbe leggere.
    ///
    /// **Si chiede a CoreAudio, non ad AVAudioEngine, e il motivo è stato
    /// pagato subito:** la prima versione costruiva un motore usa e getta per
    /// leggergli il formato d'uscita, e la suite è morta di SIGSEGV sul mio
    /// stesso Mac. `AVAudioEngine` non è pensato per nascere e morire in una
    /// proprietà calcolata chiamata da un thread qualunque; la tabella dei
    /// dispositivi invece si interroga da ovunque ed è lo stesso idioma che
    /// `AudioRecorder` usa già per l'ingresso.
    ///
    /// **E non basta che un dispositivo ESISTA: deve avere canali.** Seconda
    /// correzione, pagata con una corsa intera (32072036346): sul runner
    /// CoreAudio risponde con un dispositivo d'uscita predefinito, la sonda
    /// diceva sì, e il motore si è schiantato lo stesso. Un dispositivo può
    /// essere registrato e non avere un solo canale utilizzabile. La domanda
    /// giusta è quanti canali escono, non se una riga esiste in tabella.
    nonisolated static var uscitaDisponibile: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var listSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &listSize) == noErr,
              listSize > 0 else { return false }

        let grezzo = UnsafeMutableRawPointer.allocate(
            byteCount: Int(listSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { grezzo.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &listSize, grezzo) == noErr
        else { return false }

        let lista = UnsafeMutableAudioBufferListPointer(
            grezzo.assumingMemoryBound(to: AudioBufferList.self))
        return lista.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    /// Il numero della programmazione corrente. `AVAudioPlayerNode.stop()` fa
    /// SCATTARE il completion handler del buffer che stava suonando, e ogni
    /// riprogrammazione — un cambio di volume, una trascinata — passa da uno
    /// `stop()`: quel handler arriva sul MainActor DOPO che il play nuovo è
    /// partito, e senza questo numero `finita()` lo prendeva per la fine vera.
    /// Dal campo, 2026-08-17: «alzo il volume al 50% e la barra va alla fine,
    /// resta solo il play». Il handler porta il numero di quando è nato, e se
    /// nel frattempo il numero è cambiato non parla più a nome di nessuno.
    private var generazione = 0

    var isLoaded: Bool { formato != nil && duration > 0 }

    var fraction: Double { Playback.fraction(elapsed: elapsed, duration: duration) }
    var clock: String { Playback.label(elapsed: elapsed, duration: duration) }

    /// La pastiglia accesa, o nessuna se il guadagno sta fra due.
    var quotaAccesa: Int? { Guadagno.quota(perDB: guadagnoDB, spazio: spazioDB) }

    /// Il comando del volume si disegna solo se c'è spinta da dare. Un comando
    /// presente che non fa niente si legge come un'app rotta — la stessa regola
    /// per cui la striscia non compare su una dettatura senza audio.
    var puòSpingere: Bool { spazioDB > 0 }



    /// Opens the file, or stays empty. A missing or unreadable wav is not an
    /// error anybody can act on from this panel, so it goes to the log and the
    /// strip simply is not there.
    func load(_ url: URL?) {
        guard formato == nil, let url else { return }
        // Senza uscita audio non si carica: il collegamento al mixer a zero
        // canali non fallisce, abbatte il processo. Meglio una striscia che non
        // compare che un'app che sparisce (vedi `uscitaDisponibile`).
        guard Self.uscitaDisponibile else {
            Log.write("playback: nessun dispositivo d'uscita audio, riproduzione non disponibile")
            return
        }
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { return }
            try file.read(into: buffer)
            guard let dati = buffer.floatChannelData?[0] else { return }
            originali = Array(UnsafeBufferPointer(start: dati, count: Int(buffer.frameLength)))
            formato = file.processingFormat
            duration = Double(buffer.frameLength) / file.processingFormat.sampleRate
            elapsed = 0
            // Lo spazio è del FILE, quindi si misura all'apertura; la quota
            // ricordata si traduce nei dB che questa registrazione regge.
            spazioDB = Guadagno.spazio(picco: Guadagno.picco(originali))
            // Scritto e basta: nessun effetto collaterale all'apertura, che è
            // quello che faceva crashare il pannello.
            guadagnoDB = Guadagno.clamp(Float(AppState.shared.playbackGainQuota) * spazioDB,
                                        spazio: spazioDB)

            motore.attach(nodo)
            motore.attach(tempo)
            motore.connect(nodo, to: tempo, format: file.processingFormat)
            motore.connect(tempo, to: motore.mainMixerNode, format: file.processingFormat)
            tempo.rate = rate
            if Self.probeMuto { motore.mainMixerNode.outputVolume = 0 }
            try motore.start()
        } catch {
            Log.write("playback: \(url.lastPathComponent) non si apre — \(error.localizedDescription)")
            unload()
        }
    }

    /// **Tutto chiuso, e non è pulizia: è la regola pagata con le cuffie il
    /// 2026-08-14.** Un motore audio fermo resta un client CoreAudio configurato
    /// sul dispositivo di allora, e quando quel dispositivo cambia il sistema
    /// richiama un client il cui mondo non esiste più. Fra un pannello e il
    /// successivo qui non deve restare niente che un evento di sistema possa
    /// colpire — per questo si stacca e non ci si limita a fermare.
    func unload() {
        stopTicking()
        // Anche questo `stop()` fa scattare un handler in coda: il numero
        // cambia PRIMA, così quel handler trova un mondo che non è più il suo.
        generazione += 1
        nodo.stop()
        motore.stop()
        if motore.attachedNodes.contains(nodo) { motore.detach(nodo) }
        if motore.attachedNodes.contains(tempo) { motore.detach(tempo) }
        originali = []
        formato = nil
        spazioDB = 0
        guadagnoDB = 0
        isPlaying = false
        elapsed = 0
        duration = 0
        partenza = 0
    }

    func toggle() {
        guard isLoaded else { return }
        if isPlaying {
            nodo.pause()
            isPlaying = false
            stopTicking()
        } else {
            // Pressing play on a finished dictation replays it. The alternative
            // is a button that looks armed and does nothing, which is the same
            // defect as the dead strip above.
            if elapsed >= duration - 0.05 { elapsed = 0 }
            programma(da: elapsed)
            nodo.play()
            isPlaying = true
            startTicking()
        }
    }

    /// Drag on the bar. Seeking while paused is the ordinary way to line up on a
    /// word, so it must not start the sound.
    func seek(toFraction f: Double) {
        guard isLoaded else { return }
        let t = Playback.seconds(fraction: f, duration: duration)
        elapsed = t
        guard isPlaying else { return }
        programma(da: t)
        nodo.play()
    }

    /// **La mano dell'utente sul volume.** Limita allo spazio del file, ricorda la
    /// quota, e riprogramma da dove si era — così la spinta si sente subito invece
    /// che alla prossima riproduzione, che è ciò che rende il comando utilizzabile:
    /// si alza mentre si ascolta il punto che non si capisce.
    func imposta(dB: Float) {
        let nuovo = Guadagno.clamp(dB, spazio: spazioDB)
        guard nuovo != guadagnoDB else { return }
        guadagnoDB = nuovo
        // Si ricorda la QUOTA, non i dB: i dB sono una proprietà del file, e
        // rimetterne venti su una registrazione già piena sarebbe ricordare la
        // risposta invece della domanda. La quota è «quanto spingo», e vale da un
        // file all'altro.
        AppState.shared.playbackGainQuota = spazioDB > 0 ? Double(nuovo / spazioDB) : 0
        guard isLoaded, isPlaying else { return }
        programma(da: elapsed)
        nodo.play()
    }

    /// Programma la coda del file a partire da `da`, col guadagno corrente.
    private func programma(da: Double) {
        guard let formato else { return }
        nodo.stop()
        let sr = formato.sampleRate
        let primo = min(max(0, Int(da * sr)), max(0, originali.count - 1))
        let coda = Array(originali[primo...])
        let lavorati = Guadagno.applica(coda, dB: guadagnoDB)
        guard !lavorati.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: formato,
                                            frameCapacity: AVAudioFrameCount(lavorati.count)),
              let dati = buffer.floatChannelData?[0] else { return }
        for i in 0 ..< lavorati.count { dati[i] = lavorati[i] }
        buffer.frameLength = AVAudioFrameCount(lavorati.count)
        partenza = Double(primo) / sr
        generazione += 1
        let gen = generazione
        nodo.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in self?.finita(gen) }
        }
    }

    private func finita(_ gen: Int) {
        guard gen == generazione, isPlaying else { return }
        isPlaying = false
        stopTicking()
        elapsed = duration
    }

    private func startTicking() {
        stopTicking()
        // 20 Hz: the bar is 460 points wide over 20 seconds, so a tick is a
        // couple of points and the movement reads as continuous. Faster would
        // redraw a view nobody can see move.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying,
                      let nodeTime = self.nodo.lastRenderTime,
                      let suo = self.nodo.playerTime(forNodeTime: nodeTime) else { return }
                // Il tempo del NODO, non quello dell'uscita: conta i fotogrammi
                // di sorgente consumati, quindi resta vero a qualunque velocità.
                self.elapsed = min(self.duration,
                                   self.partenza + Double(suo.sampleTime) / suo.sampleRate)
            }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
