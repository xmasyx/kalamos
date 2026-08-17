import AVFoundation
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SondaTaglio — il banco del taglio di coda, sui SUOI file veri.
//
// Nasce da una regressione del 2026-08-17: `trimSilence` ha tolto 2,22 s alla
// dettatura delle 00:29:45 e con essi le parole «di diverso», che lui aveva detto.
// La prova non è un'opinione ed è già sul disco: quella dettatura ha un campo
// `VERITÀ` scritto da lui nel pannello «Le tue dettature», quindi per una volta il
// banco ha la risposta esatta invece di un giudizio.
//
// **Perché una sonda e non una lettura del codice.** Il difetto è in un NUMERO,
// non in un ramo: la soglia nasce da quattro termini in competizione — pavimento,
// frazione del picco, tetto preso in prestito, tetto sulla mediana — e quale
// comandi dipende dalla registrazione. Dal sorgente si vedono quattro candidati
// ugualmente plausibili; misurando si vede quale ha tagliato, e su quanti file.
// La colonna «termine» del referto esiste per questo.
//
// **E la risposta è stata: nessuno dei quattro.** Sul file delle 00:29:45 la
// soglia valeva 0,0051, il parlato finiva a 11,2 s e la quiete dopo stava a
// 0,001 — il taglio aveva tolto solo silenzio vero, e le parole erano ancora
// nell'audio consegnato al decoder. A perderle era il CUSCINO troppo corto
// (`trimPad`), cioè quanta quiete arriva in fondo. La sonda serve anche a questo:
// a smentire l'ipotesi con cui si è partiti.
// ─────────────────────────────────────────────────────────────────────────────

enum SondaTaglio {

    /// I campioni mono a 16 kHz di un wav, come li riceve il motore.
    ///
    /// Passa da `AVAudioFile` con un formato di uscita dichiarato invece di
    /// interpretare i byte a mano: il wav dell'archivio è Int16 e il motore lavora
    /// in Float32, e una conversione scritta qui sarebbe la sonda che riscrive la
    /// logica che deve misurare.
    static func campioni(di url: URL) throws -> [Float] {
        // Il formato di elaborazione è Float32 non interlacciato: `AVAudioFile`
        // converte da sé dall'Int16 del wav, che è esattamente la conversione che
        // fa il motore, e scriverla a mano qui sarebbe la sonda che riscrive ciò
        // che deve misurare.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let dati = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: dati, count: Int(buffer.frameLength)))
    }

    /// Il profilo d'energia, con la stessa finestra e lo stesso passo del taglio
    /// vero. **Importati da `WhisperKitTranscriber`, non ricopiati**: il giorno che
    /// cambia la finestra, cambia anche qui (2026-08-05, gli elenchi del compendio).
    static func energie(_ s: [Float]) -> [(start: Int, valore: Float)] {
        guard s.count > WhisperKitTranscriber.trimWindow else { return [] }
        var cumulata = [Double](repeating: 0, count: s.count + 1)
        for i in 0 ..< s.count { cumulata[i + 1] = cumulata[i] + Double(s[i]) * Double(s[i]) }
        var out: [(start: Int, valore: Float)] = []
        var start = 0
        while start + WhisperKitTranscriber.trimWindow <= s.count {
            let e = cumulata[start + WhisperKitTranscriber.trimWindow] - cumulata[start]
            out.append((start, Float((max(0, e) / Double(WhisperKitTranscriber.trimWindow)).squareRoot())))
            start += WhisperKitTranscriber.trimHop
        }
        return out
    }

    struct Referto {
        let nome: String
        let durata: Double
        let durataDopo: Double
        let picco: Float
        let soglia: Float
        /// Quale dei tre termini della soglia ha davvero comandato. È il dato che
        /// una lettura del sorgente non può dare.
        let termine: String
        /// L'energia MEDIANA delle finestre che stanno sopra il pavimento del
        /// parlato: il riferimento robusto contro cui si legge se la soglia sia
        /// finita sopra il parlato normale invece che sotto.
        let medianaParlato: Float

        var tagliato: Double { durata - durataDopo }

        static func riga(_ r: Referto) -> String {
            String(format: "%-22@ %6.2fs → %6.2fs  taglio %6.2fs  picco %.4f  soglia %.4f (%@)  mediana %.4f  %@",
                   r.nome as NSString, r.durata, r.durataDopo, r.tagliato,
                   r.picco, r.soglia, r.termine as NSString, r.medianaParlato,
                   r.tagliato >= Double(WhisperKitTranscriber.trimSospetto) ? "⚠︎ SOSPETTO" : "")
        }
    }

    static func misura(_ url: URL) throws -> Referto? {
        let s = try campioni(di: url)
        guard !s.isEmpty else { return nil }
        let sr = 16_000.0
        let e = energie(s)
        let picco = e.map(\.valore).max() ?? 0
        let mediana = WhisperKitTranscriber.trimMediana(e.map(\.valore))
        let soglia = WhisperKitTranscriber.trimSoglia(picco, mediana: mediana)

        // Quale termine ha vinto, nominato invece che dedotto da chi legge.
        let relativa = picco * WhisperKitTranscriber.trimFraction
        let tettoMediana = mediana * WhisperKitTranscriber.trimQuotaMediana
        let termine: String
        if soglia <= AudioRecorder.speechFloor { termine = "pavimento speechFloor" }
        else if mediana > 0, tettoMediana < min(relativa, AudioSplit.silenceRMS) { termine = "tetto mediana" }
        else if relativa >= AudioSplit.silenceRMS { termine = "tetto silenceRMS" }
        else { termine = "relativa al picco" }

        let dopo = WhisperKitTranscriber.trimSilence(s)
        return Referto(nome: url.deletingPathExtension().lastPathComponent,
                       durata: Double(s.count) / sr,
                       durataDopo: Double(dopo.count) / sr,
                       picco: picco, soglia: soglia, termine: termine,
                       medianaParlato: mediana)
    }
}
