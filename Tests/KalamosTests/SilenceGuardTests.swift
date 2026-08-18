import Foundation
import Testing
@testable import Kalamos

#if canImport(WhisperKit)
/// Silence must never reach Whisper (asked 2026-07-31).
///
/// Whisper was trained on captioned video and, given nothing, produces the
/// caption boilerplate it saw most: "thank you", "grazie", "sottotitoli e
/// revisione a cura di…". Stripping those phrases afterwards is pattern-matching
/// and only covers the ones you listed. The audio itself is the honest test.
@Suite struct SilenceGuardTests {
    private static let rate: Float = 16_000

    private func tone(seconds: Float, amplitude: Float) -> [Float] {
        let n = Int(seconds * Self.rate)
        return (0 ..< n).map { i in amplitude * sin(Float(i) * 0.05) }
    }

    @Test func digitalSilenceIsSilent() {
        #expect(WhisperKitTranscriber.isSilent([Float](repeating: 0, count: 32_000)))
    }

    @Test func emptyIsSilent() {
        #expect(WhisperKitTranscriber.isSilent([]))
    }

    /// Room tone with the mic open and nobody speaking.
    @Test func roomToneIsSilent() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 3, amplitude: 0.002)))
    }

    /// The failure that would matter: swallowing something actually said. A
    /// quiet, close-mic sentence must go through.
    @Test func quietSpeechIsNotSilent() {
        #expect(!WhisperKitTranscriber.isSilent(tone(seconds: 2, amplitude: 0.02)))
    }

    @Test func normalSpeechIsNotSilent() {
        #expect(!WhisperKitTranscriber.isSilent(tone(seconds: 4, amplitude: 0.2)))
    }

    /// A double-tap that caught the key click: loud, and far too short to be a word.
    @Test func aClickIsSilent() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 0.08, amplitude: 0.4)))
    }
}

/// The trim cuts the tail and never the head (2026-08-16).
///
/// The head used to be cut too, and it was losing a whole sentence out of long
/// dictations: both Whisper engines read the audio in 30-second windows, so
/// moving the start moves every later sentence against those seams by however
/// long the speaker waited before speaking — a different amount every time. The
/// measurement is in `WhisperKitTranscriber.trimSilence`; these are the two poles
/// that stop it coming back by accident.
@Suite struct TrimSilenceTests {
    private static let rate = 16_000

    private func tone(seconds: Float, amplitude: Float) -> [Float] {
        let n = Int(seconds * Float(Self.rate))
        return (0 ..< n).map { i in amplitude * sin(Float(i) * 0.05) }
    }

    /// The negative pole: silence at the start survives, so speech keeps the
    /// offset it was recorded at.
    @Test func leadingSilenceIsKept() {
        let lead = [Float](repeating: 0, count: Self.rate * 2)   // 2 s of nothing
        let speech = tone(seconds: 1, amplitude: 0.3)
        let out = WhisperKitTranscriber.trimSilence(lead + speech)
        #expect(out.count >= lead.count + speech.count)
        // The speech still starts two seconds in, which is the whole point.
        let firstLoud = out.firstIndex { abs($0) >= 0.008 } ?? -1
        #expect(firstLoud >= lead.count - 1)
    }

    /// The positive pole: the tail still goes, because that is where Whisper
    /// invents captions. A small pad is kept on purpose.
    ///
    /// The bound is the window PLUS the pad, and the widening on 2026-08-16 is
    /// not a test being made easier: the measure became a 100 ms window of energy
    /// instead of a single sample, and a window cannot resolve where speech ends
    /// more finely than its own length. Claiming 0.1 s of precision from a 0.1 s
    /// window would be claiming a resolution the instrument does not have.
    @Test func trailingSilenceIsRemoved() {
        let speech = tone(seconds: 1, amplitude: 0.3)
        let tail = [Float](repeating: 0, count: Self.rate * 5)
        let out = WhisperKitTranscriber.trimSilence(speech + tail)
        #expect(out.count < speech.count + tail.count)
        #expect(out.count <= speech.count
                    + WhisperKitTranscriber.trimWindow + WhisperKitTranscriber.trimPad)
        #expect(out.count >= speech.count)
    }

    /// Audio with nothing in it is handed over untouched — the silence gate
    /// decides that case, not the trim.
    @Test func allSilenceIsLeftAlone() {
        let quiet = [Float](repeating: 0, count: Self.rate * 3)
        #expect(WhisperKitTranscriber.trimSilence(quiet).count == quiet.count)
        #expect(WhisperKitTranscriber.trimSilence([]).isEmpty)
    }

    // MARK: - Il rumore di stanza, che è ciò che una registrazione VERA ha in coda

    /// **Il polo nuovo del 2026-08-16, e quello che il codice di prima non
    /// passava.**
    ///
    /// Il taglio giudicava sul singolo campione, e il rumore di fondo di un
    /// microfono vero ha picchi istantanei sopra qualunque soglia a campione:
    /// la scansione all'indietro si fermava sull'ultimo campione del file, ogni
    /// volta. Prendeva quindi solo il silenzio DIGITALE, che da un microfono
    /// non arriva mai, mentre ogni dettatura vera finisce in rumore di stanza e
    /// quel rumore andava tutto al decoder.
    ///
    /// La riga sui picchi non è decorazione: è la proprietà del materiale che
    /// faceva fallire il criterio vecchio, scritta qui perché la prova dica
    /// anche PERCHÉ è una prova.
    @Test func codaDiRumoreVieneTolta() {
        let speech = tone(seconds: 1, amplitude: 0.3)
        // Fruscio, non silenzio — e CALIBRATO sulla banda di rumore vera (17/08):
        // l'ampiezza storica 0,012 dava RMS 0,0085, che sta DENTRO la banda dove
        // il motore ha provato che vivono parole («dall'LLM» a 0,006-0,016, cinque
        // code parlate su otto sospette). Un test che chiama «rumore da tagliare»
        // quella banda pretende il difetto che il cantiere D ha chiuso. Il rumore
        // di stanza dei suoi file REALI sta sotto: le tre code provate quiete dal
        // motore tagliavano con soglie 0,0040-0,0050.
        let room = tone(seconds: 3, amplitude: 0.007)   // RMS ≈ 0,005, sotto trimTetto
        let input = speech + room

        // Il criterio a campione qui non taglierebbe niente: nella coda ci sono
        // campioni sopra la soglia viva, mentre l'RMS di finestra le sta sotto.
        // È la stessa proprietà che faceva fallire il criterio vecchio.
        #expect(room.contains { abs($0) >= WhisperKitTranscriber.trimTetto })

        let out = WhisperKitTranscriber.trimSilence(input)
        #expect(out.count < input.count, "il fruscio in coda è arrivato intero al decoder")
        #expect(out.count <= speech.count
                    + WhisperKitTranscriber.trimWindow + WhisperKitTranscriber.trimPad)
        #expect(out.count >= speech.count)
    }

    /// Il polo opposto, ed è quello che tiene onesta la soglia: **una coda
    /// parlata piano non è rumore**.
    ///
    /// È il rischio che il taglio nuovo introduce e che il taglio vecchio non
    /// aveva, perché una misura più severa può mangiare l'ultima sillaba. Ciò
    /// che la protegge è il TETTO della soglia (`trimTetto`, dal 17/08 sera), non
    /// la frazione: su una registrazione forte la frazione da sola darebbe 0,032 e
    /// questa coda a 0,035 passerebbe per un pelo. Il giorno che qualcuno alza
    /// il tetto, questa diventa rossa prima della consegna invece che sul Mac
    /// del principale.
    @Test func unaCodaParlataPianoSopravvive() {
        let forte = tone(seconds: 1, amplitude: 0.3)
        let pausa = [Float](repeating: 0, count: Self.rate / 4)
        let piano = tone(seconds: 0.4, amplitude: 0.05)   // l'ultima parola, smorzata
        let out = WhisperKitTranscriber.trimSilence(forte + pausa + piano)
        #expect(out.count >= forte.count + pausa.count + piano.count,
                "l'ultima parola detta piano è stata tagliata via")
    }

    /// **Il polo che diventa rosso se qualcuno rimette il pavimento assoluto.**
    ///
    /// Numeri presi dal caso vero `20260818-022802` (18/08, 02:28), non inventati:
    /// registrazione detta piano, picco RMS **0,0148**, e la coda parlata fra
    /// **0,0025 e 0,0031**, cioè tutta sotto `AudioRecorder.speechFloor` (0,004).
    /// Finché il pavimento era un termine della soglia, la soglia usciva 0,0040 su
    /// quel file e l'ultima parola spariva: consegnava «come l'hai fatto» invece di
    /// «come l'hai fatta adesso». Tolto il pavimento, la soglia scende a
    /// picco × 0,15 = 0,0022 e la parola resta.
    ///
    /// Un seno di ampiezza A ha RMS A/√2, quindi le ampiezze qui sotto sono i
    /// valori misurati moltiplicati per √2.
    @Test func unaRegistrazioneDettaPianoTieneLaSuaUltimaParola() {
        let forte = tone(seconds: 1.0, amplitude: 0.0209)    // RMS ≈ 0,0148, il picco vero
        let pausa = [Float](repeating: 0, count: Self.rate / 4)
        let piano = tone(seconds: 0.4, amplitude: 0.0040)    // RMS ≈ 0,0028, sotto speechFloor
        let quiete = [Float](repeating: 0, count: Self.rate / 2)
        let parlato = forte.count + pausa.count + piano.count
        let out = WhisperKitTranscriber.trimSilence(forte + pausa + piano + quiete)
        #expect(out.count >= parlato,
                "ultima parola tagliata: tenuti \(out.count) campioni su \(parlato) di parlato")
        #expect(out.count < forte.count + pausa.count + piano.count + quiete.count,
                "la quiete finale non è stata tolta: il taglio non ha fatto niente")
    }

    /// La forma del difetto vero, in laboratorio: 4 secondi di registrazione, il
    /// parlato finisce a 3,6 s, il resto è fruscio.
    ///
    /// **Riscritto il 2026-08-17, e il numero di prima era sbagliato.** Diceva che
    /// il taglio deve cadere «sotto 3,78 s», preso da un banco del 16/08 che
    /// misurava troncamenti a tempi assoluti. Rimisurato sul file vero
    /// (`20260816-145026.wav`) attraverso il percorso VERO dell'app, un processo
    /// per passata, tre passate per casella:
    ///
    /// | troncato a | «vedo di là» |
    /// |------------|--------------|
    /// | 3,74 s     | 3/3          |
    /// | 3,79 s     | 3/3          |
    /// | 3,84 s     | 3/3          |
    /// | 3,90 s     | 3/3          |
    /// | 3,96 s     | 3/3          |
    /// | 3,99 s (intero) | **0/3** |
    ///
    /// Non c'è nessun dirupo a 3,78: c'è un dirupo fra 3,96 e 3,99, cioè **fra
    /// "tagliato un po'" e "non tagliato affatto"**. La regola che quel file
    /// impone è quindi molto più debole di quanto si credesse — basta che il
    /// taglio tolga qualcosa — e la sua utilità è tutta qui: era il vincolo che
    /// giustificava un cuscino da 0,05 s, e quel cuscino ha poi mangiato «di
    /// diverso» a una dettatura sua.
    @Test func ilTaglioTogliePerDavveroLaCodaDiRumore() {
        let parlato = tone(seconds: 3.6, amplitude: 0.22)
        let fruscio = tone(seconds: 0.39, amplitude: 0.012)
        let intero = parlato + fruscio
        let out = WhisperKitTranscriber.trimSilence(intero)
        let secondi = Float(out.count) / Float(Self.rate)
        #expect(secondi > 3.6, "tagliato dentro il parlato: \(secondi)s")
        // Il vincolo vero, misurato: qualcosa dev'essere tolto. Un taglio che
        // consegna il file intero è il caso 0/3 della tabella.
        #expect(out.count < intero.count,
                "il taglio non ha tolto niente: è il caso che perde le parole, \(secondi)s")
    }

    // MARK: - Il cuscino, che è il numero che ha mangiato le sue parole

    /// **La regola del brief come proprietà — e il limite che NON è coperto,
    /// dichiarato con il suo numero invece che taciuto.**
    ///
    /// «Mai togliere una finestra che contiene parlato»: l'ultima parola si prova
    /// a molte ampiezze invece che a una, perché il difetto del 17/08 viveva in
    /// una fascia stretta e un esempio solo l'avrebbe scavalcato.
    ///
    /// **Il confine non è scritto a mano, è DERIVATO dalla soglia**, così il
    /// giorno che il tetto cambia questa prova cambia con lui invece di restare
    /// indietro. Sopra il confine il taglio non deve mai toccare l'ultima parola.
    ///
    /// **Sotto il confine resta un caso scoperto, ed è diventato una BANDA
    /// stretta** (17/08 sera, cantiere D). Il tetto preso in prestito
    /// (`AudioSplit.silenceRMS`, 0,02) è stato sostituito da `trimTetto` (0,006),
    /// scelto con lo sweep sul motore vero: la banda mangiabile era 0,004-0,020,
    /// ora è 0,004-0,006. Dentro quella banda residua una soglia in RMS non può
    /// distinguere parlato debolissimo da rumore di stanza — il rimedio vero
    /// sarebbe di contenuto, non di soglia — e i tre casi che ci restano dentro
    /// (5 parole su 034221, 3 su 154025, 3 su 160434) sono dichiarati nel referto
    /// del banco, non nascosti da questo verde.
    @Test func unaFinestraDiParlatoNonVieneMaiTolta() {
        let forte = tone(seconds: 1.5, amplitude: 0.30)
        let pausa = [Float](repeating: 0, count: Self.rate / 2)
        // Il picco è quello del tratto forte; la soglia che ne esce decide il
        // confine. Un seno di ampiezza A ha RMS A/√2, da cui l'ampiezza minima.
        let soglia = WhisperKitTranscriber.trimSoglia(0.30 / Float(2).squareRoot(),
                                                      mediana: 0.30 / Float(2).squareRoot())
        let confine = soglia * Float(2).squareRoot()
        for passo in 0...8 {
            let ampiezza = confine * 1.1 + Float(passo) * 0.010
            let ultima = tone(seconds: 0.3, amplitude: ampiezza)
            let intero = forte + pausa + ultima
            let out = WhisperKitTranscriber.trimSilence(intero + tone(seconds: 2, amplitude: 0.002))
            #expect(out.count >= intero.count,
                    "ampiezza \(ampiezza): l'ultima parola è stata tagliata (\(out.count) < \(intero.count))")
        }
        // Il polo negativo, ed è quello che tiene onesto il confine: DENTRO la
        // banda residua (RMS fra il pavimento e trimTetto) il taglio mangia
        // davvero, ed è il caso dichiarato nel paragrafo qui sopra. L'ampiezza è
        // DERIVATA dai due estremi della banda, così se un giorno la banda si
        // chiude (un rimedio di contenuto) questa riga diventa verde e va tolta
        // insieme al paragrafo, non lasciata a mentire.
        let rmsResiduo = (AudioRecorder.speechFloor + WhisperKitTranscriber.trimTetto) / 2
        let troppoPiano = tone(seconds: 0.3, amplitude: rmsResiduo * Float(2).squareRoot())
        let interoPiano = forte + pausa + troppoPiano
        let outPiano = WhisperKitTranscriber.trimSilence(interoPiano + tone(seconds: 2, amplitude: 0.002))
        #expect(outPiano.count < interoPiano.count,
                "la banda residua non si riproduce più: o è stata chiusa (togli questo polo) o il confine dichiarato non è quello vero")
    }

    /// **Il cuscino sta dentro l'altopiano misurato sui suoi file.**
    ///
    /// Sotto 0,10 s WhisperKit non chiude la frase e le ultime parole non escono
    /// mai — misurato il 17/08 con il motore vero, tre passate per casella:
    /// «di diverso» (`20260817-002945`) esce 0/3 a cuscino 0,05 e 3/3 da 0,10 in
    /// su. Sopra 0,20 s si comincia a consegnare quiete che non serve, e su una
    /// registrazione corta il taglio finisce per non togliere più niente — che è
    /// il caso 0/3 del test qui sopra.
    ///
    /// Il numero non è derivabile: è un comportamento del decoder che non
    /// controlliamo. Quindi la prova non lo ricalcola, lo **inchioda**, e i due
    /// poli sono i due valori che sono stati visti fallire.
    @Test func ilCuscinoStaNellAltopianoMisurato() {
        let secondi = Double(WhisperKitTranscriber.trimPad) / 16_000
        #expect(secondi >= 0.10,
                "cuscino \(secondi)s: sotto il minimo misurato, le ultime parole non escono")
        #expect(secondi <= 0.20,
                "cuscino \(secondi)s: oltre l'altopiano misurato")
        // I due poli, nominati: il valore che ha mangiato «di diverso» il 17/08 e
        // che deve restare fuori, e il fatto che 0,15 sia il centro della banda —
        // cioè scelto per stare lontano da entrambi i bordi, non per caso.
        #expect(secondi != 0.05, "è tornato il cuscino che ha perso le sue parole")
        #expect(abs(secondi - 0.15) < 0.001,
                "cuscino \(secondi)s: non è più il centro della banda misurata")
    }

    /// L'interruttore della sonda è spento in produzione.
    ///
    /// `probeTrimOff` esiste per rispondere a «è il taglio o è il decodificatore?»
    /// senza modificare il sorgente, ed è esattamente il genere di manopola che
    /// resta accesa per sbaglio dopo una sessione di diagnosi.
    @Test func leManopoleDellaSondaSonoSpente() {
        #expect(WhisperKitTranscriber.probeTrimOff == false)
        #expect(WhisperKitTranscriber.probeTrimPad == nil)
        #expect(WhisperKitTranscriber.cuscino == WhisperKitTranscriber.trimPad)
    }
}
#endif
