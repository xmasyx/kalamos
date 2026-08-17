import Foundation
import Testing
import AVFoundation
@testable import Kalamos

/// The playhead arithmetic, on the numbers of the dictation that made this panel
/// grow a player: `20260815-151553.wav`, 20.6 seconds, with the word nobody could
/// read sitting between 8.52 and 9.19.
///
/// These are pure functions on purpose — see the note on `Playback`. Nothing here
/// opens an audio device, so nothing here can pass because the machine it ran on
/// happened to have speakers.
@Suite("Playback — dove cade il cursore, e che ora segna")
struct DictationPlaybackTests {

    static let duration = 20.6      // the real file
    static let wordStart = 8.52     // the syllable he could not place

    // MARK: the bar reads the sound

    @Test("Il cursore sta dove sta il suono")
    func fractionTracksElapsed() {
        #expect(Playback.fraction(elapsed: 0, duration: Self.duration) == 0)
        #expect(Playback.fraction(elapsed: Self.duration, duration: Self.duration) == 1)
        let f = Playback.fraction(elapsed: Self.wordStart, duration: Self.duration)
        #expect(abs(f - 0.4135) < 0.001)
    }

    /// The negative pole of the one above: a fraction that is not clamped puts the
    /// knob outside the bar, and a duration of zero divides by it.
    @Test("Fuori dai due estremi il cursore resta dentro la barra")
    func fractionIsClamped() {
        #expect(Playback.fraction(elapsed: -5, duration: Self.duration) == 0)
        #expect(Playback.fraction(elapsed: 999, duration: Self.duration) == 1)
        #expect(Playback.fraction(elapsed: 3, duration: 0) == 0)
        #expect(Playback.clamp(-0.4) == 0)
        #expect(Playback.clamp(1.4) == 1)
    }

    // MARK: the drag lands where the finger is

    @Test("Trascinando a metà barra si atterra a metà nastro")
    func seekMapsBackToSeconds() {
        #expect(Playback.seconds(fraction: 0.5, duration: Self.duration) == Self.duration / 2)
        #expect(Playback.seconds(fraction: 0, duration: Self.duration) == 0)
        #expect(Playback.seconds(fraction: 1, duration: Self.duration) == Self.duration)
    }

    /// A drag is `minimumDistance: 0` over the whole strip, so the finger goes
    /// past both ends every time somebody scrubs to the start. Past the end means
    /// the end.
    @Test("Trascinando oltre i bordi si atterra sui bordi, non fuori")
    func seekIsClamped() {
        #expect(Playback.seconds(fraction: -0.3, duration: Self.duration) == 0)
        #expect(Playback.seconds(fraction: 2.0, duration: Self.duration) == Self.duration)
        #expect(Playback.seconds(fraction: 0.5, duration: 0) == 0)
    }

    /// Drag then read: the two directions have to agree, or the knob jumps away
    /// from the finger that placed it.
    @Test("Andata e ritorno tornano allo stesso punto")
    func roundTrip() {
        for f in [0.0, 0.137, 0.4135, 0.5, 0.99, 1.0] {
            let seconds = Playback.seconds(fraction: f, duration: Self.duration)
            let back = Playback.fraction(elapsed: seconds, duration: Self.duration)
            #expect(abs(back - f) < 1e-9)
        }
    }

    // MARK: the clock

    @Test("L'orologio segna m:ss, con i secondi sempre a due cifre")
    func clockFormat() {
        #expect(Playback.clock(8.52) == "0:08")
        #expect(Playback.clock(20.6) == "0:20")
        #expect(Playback.clock(61) == "1:01")
        #expect(Playback.clock(600) == "10:00")
        #expect(Playback.label(elapsed: 8.52, duration: 20.6) == "0:08 / 0:20")
    }

    /// A file that will not open reports a NaN duration. The clock is not where
    /// that gets discovered, and `String(format:)` on a NaN prints garbage.
    @Test("Una durata impossibile segna 0:00 invece di un numero inventato")
    func clockSurvivesNonsense() {
        #expect(Playback.clock(.nan) == "0:00")
        #expect(Playback.clock(.infinity) == "0:00")
        #expect(Playback.clock(-3) == "0:00")
        #expect(Playback.clock(0) == "0:00")
    }

    // MARK: the speed that made the word readable

    @Test("Le tre velocità sono 0,5 · 1 · 1,5")
    func speeds() {
        #expect(Playback.speeds == [0.5, 1.0, 1.5])
        #expect(Playback.normalRate == 1.0)
    }
}

// MARK: - La gara fra il buffer vecchio e il nuovo (campo, 2026-08-17)

/// Il difetto riferito da lui: «quando aumento il volume con il 50% la barra va
/// alla fine e resta solo il play». La catena: `imposta(dB:)` riprogramma il
/// nodo, `programma` chiama `nodo.stop()`, e `AVAudioPlayerNode.stop()` FA
/// SCATTARE il completion handler del buffer che stava suonando; quel handler
/// arriva sul MainActor dopo che il play nuovo è già partito, `finita()` vede
/// `isPlaying == true` e chiude tutto: barra in fondo, pausa sparita.
///
/// Il test suona un file vero e alza il volume a metà ascolto: se la
/// riproduzione muore, è il difetto. Scritto PRIMA della riparazione e visto
/// rosso; il polo che deve restare vivo è la fine naturale, sotto.
/// **Questi due test pretendono una scheda audio, ed è dichiarato invece che
/// implicito.** Suonano un file vero perché è il punto: la gara vive dentro il
/// motore, e un finto motore non la riproduce. Su una macchina senza
/// dispositivo d'uscita — il runner GitHub, un Mac con tutto staccato — non c'è
/// niente da esercitare, e il codice di produzione adesso si rifiuta di
/// caricare (vedi `DictationPlayer.uscitaDisponibile`). La condizione è la
/// STESSA proprietà che usa la produzione: se un domani quella cambia, questi
/// test la seguono invece di divergere. Il caso «nessuna uscita» non resta
/// scoperto: lo tiene `laMancanzaDiUscitaNonCarica()` qui sotto, che gira su
/// qualunque macchina.
@Suite("Playback — il volume alzato durante l'ascolto non ferma niente",
       .enabled(if: DictationPlayer.uscitaDisponibile,
                "serve un dispositivo d'uscita audio: qui non ce n'è uno"))
@MainActor struct PlaybackGainRaceTests {

    /// Un wav mono a 16 kHz con margine di spinta (picco 0,1 → spazioDB > 0).
    private func wavConSpazio(secondi: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gara-guadagno-\(UUID().uuidString).wav")
        let formato = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                    channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: formato.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(secondi * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: n)!
        let dati = buffer.floatChannelData![0]
        for i in 0 ..< Int(n) { dati[i] = (i % 2 == 0 ? 0.1 : -0.1) }
        buffer.frameLength = n
        try file.write(from: buffer)
        return url
    }

    @Test("Alzare il volume a metà ascolto non porta la barra alla fine")
    func gainChangeMidPlaybackKeepsPlaying() async throws {
        DictationPlayer.probeMuto = true   // il segnale di prova è un tono a 8 kHz: MAI dalle casse
        let url = try wavConSpazio(secondi: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = DictationPlayer()
        player.load(url)
        try #require(player.isLoaded)
        try #require(player.puòSpingere)

        player.toggle()                                   // play
        try await Task.sleep(nanoseconds: 300_000_000)
        try #require(player.isPlaying)

        player.imposta(dB: player.spazioDB / 2)           // la mano sul +50%
        // Il tempo perché il completion del buffer VECCHIO atterri sul MainActor.
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(player.isPlaying, "la riproduzione deve continuare dopo la spinta")
        #expect(player.elapsed < player.duration - 0.5,
                "la barra non deve saltare alla fine (\(player.elapsed)/\(player.duration))")
        player.unload()
    }

    /// Il polo opposto, che tiene onesto il primo: la fine VERA deve ancora
    /// chiudere la riproduzione. Se questo diventasse rosso, la riparazione
    /// avrebbe reso sordo il finale, che è il difetto gemello.
    @Test("La fine naturale chiude ancora la riproduzione")
    func naturalEndStillEnds() async throws {
        DictationPlayer.probeMuto = true
        let url = try wavConSpazio(secondi: 0.6)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = DictationPlayer()
        player.load(url)
        try #require(player.isLoaded)
        player.toggle()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!player.isPlaying, "a nastro finito il play deve essersi chiuso")
        #expect(player.elapsed >= player.duration - 0.05)
        player.unload()
    }
}

/// **Il caso che il runner ha scoperto, e che gira su qualunque macchina.**
/// Senza dispositivo d'uscita il collegamento al mixer a zero canali non
/// fallisce: fa scattare un'asserzione dentro AVFoundation e abbatte il
/// processo, fuori dalla portata di ogni `catch`. La riparazione è la guardia
/// in `load`, e questo test la tiene in tutti e due i sensi — dove l'uscita
/// c'è il file si apre, dove non c'è si resta scarichi e vivi. Sul suo Mac
/// prova il primo ramo, sul runner il secondo, e da nessuna parte è muto.
@Suite("Playback — senza scheda audio non si schianta")
@MainActor struct PlaybackNoOutputTests {

    /// Il wav si scrive in una funzione SUA, e non è stile: `AVAudioFile` in
    /// scrittura svuota il buffer quando muore, quindi finché l'oggetto resta
    /// vivo nella stessa funzione il file sul disco è ancora vuoto e il player
    /// non lo apre. Preso al primo giro da questo stesso test.
    private func wavDiUnSecondo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("senza-uscita-\(UUID().uuidString).wav")
        let formato = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                    channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: formato.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = (i % 2 == 0) ? 0.1 : -0.1 }
        try file.write(from: buffer)
        return url
    }

    @Test func laMancanzaDiUscitaNonCarica() throws {
        // Stampata PRIMA di aprire il file: se una macchina nuova riuscisse
        // ancora ad abbattere il processo qui sotto, il registro della corsa
        // direbbe comunque che cosa aveva risposto la sonda. Una diagnosi che
        // arriva solo quando il test sopravvive manca proprio quando serve.
        print("sonda uscita audio: \(DictationPlayer.uscitaDisponibile)")
        let url = try wavDiUnSecondo()
        defer { try? FileManager.default.removeItem(at: url) }

        let player = DictationPlayer()
        player.load(url)                     // non deve MAI abbattere il processo
        #expect(player.isLoaded == DictationPlayer.uscitaDisponibile,
                "si carica se e solo se c'è un'uscita audio")
        player.unload()
    }
}
