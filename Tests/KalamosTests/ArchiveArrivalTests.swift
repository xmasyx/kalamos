import Foundation
import Testing
@testable import Kalamos

/// **La riga che arriva mentre il pannello è aperto.**
///
/// Il difetto: `store.load()` girava una volta sola all'apertura e nessuno
/// avvisava più il pannello. Dettando col pannello aperto la riga nuova non
/// compariva finché non lo si richiudeva — non un ritardo, proprio informazione
/// che non partiva.
///
/// Qui si prova la parte che si può provare senza microfono: la costruzione della
/// voce singola e le tre proprietà dell'inserimento (non rilegge, è idempotente,
/// rispetta l'ordine). Il giro completo dettatura → notifica → riga si guarda a
/// mano sul bundle, ed è dichiarato così invece di essere finto qui.
@Suite("Archivio — la riga che arriva a pannello aperto")
struct ArchiveArrivalTests {

    /// Un archivio finto in una cartella temporanea. `wav` e sidecar veri, perché
    /// `entry(for:)` legge il disco davvero.
    private func archivioFinto(_ stems: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-arrivo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for stem in stems {
            let wav = dir.appendingPathComponent("\(stem).wav")
            try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
            try "durata audio: 1.0s\n\nCONSEGNATO:\ntesto di \(stem)\n"
                .write(to: dir.appendingPathComponent("\(stem).txt"),
                       atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - La voce singola è costruita come quelle dell'elenco

    /// Il polo che conta: una voce costruita a caldo e la stessa voce riletta
    /// domani da `stems` devono coincidere. Se divergessero, una riga arrivata
    /// mentre il pannello è aperto sarebbe diversa dalla stessa riga dopo un
    /// riavvio, e nessuno se ne accorgerebbe.
    @Test func laVoceSingolaCoincideConQuellaDellElenco() throws {
        let dir = try archivioFinto(["20260818-101500"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("20260818-101500.wav")
        let daSola = DictationIndex.entry(for: wav)
        let daElenco = DictationIndex.stems(in: dir).first

        // Si confrontano per NOME, non per URL, ed è il contratto vero: lo stesso
        // file arriva come `/var/…` o `/private/var/…` a seconda di come è stato
        // costruito, e pretendere l'uguaglianza delle due stringhe proverebbe una
        // cosa che non è mai stata vera né serve che lo sia.
        #expect(daSola?.wav.lastPathComponent == daElenco?.wav.lastPathComponent)
        #expect(daSola?.started == daElenco?.started)
        // L'elenco non idrata (details nil per costruzione), la voce singola sì:
        // è la differenza voluta, ed è il motivo per cui la riga arriva completa.
        #expect(daElenco?.details == nil)
        #expect(daSola?.details?.text.contains("20260818-101500") == true)
    }

    /// **Il polo negativo:** un file che non è dei nostri non entra in lista da
    /// nessuna delle due strade. Senza questo, `entry(for:)` potrebbe accettare
    /// qualunque cosa e il primo file estraneo nella cartella comparirebbe come
    /// dettatura.
    @Test func unFileEstraneoNonDiventaUnaVoce() throws {
        let dir = try archivioFinto([])
        defer { try? FileManager.default.removeItem(at: dir) }

        let intruso = dir.appendingPathComponent("appunti.wav")
        try Data([0x00]).write(to: intruso)
        #expect(DictationIndex.entry(for: intruso) == nil)
        #expect(DictationIndex.stems(in: dir).isEmpty)

        // E nemmeno un nome giusto con l'estensione sbagliata.
        let nonWav = dir.appendingPathComponent("20260818-101500.aiff")
        try Data([0x00]).write(to: nonWav)
        #expect(DictationIndex.entry(for: nonWav) == nil)
    }

    // MARK: - Le tre proprietà dell'inserimento

    @MainActor
    @Test func laRigaNuovaEntraInCimaSenzaRileggereLaCartella() throws {
        let dir = try archivioFinto(["20260818-090000", "20260818-100000"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ArchiveStore()
        store.adotta(DictationIndex.stems(in: dir))
        #expect(store.entries.count == 2)

        let nuova = dir.appendingPathComponent("20260818-110000.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: nuova)
        try "CONSEGNATO:\nla più recente\n".write(
            to: dir.appendingPathComponent("20260818-110000.txt"),
            atomically: true, encoding: .utf8)

        store.arrived(nuova)
        #expect(store.entries.count == 3)
        #expect(store.entries.first?.wav == nuova)
        #expect(store.entries.first?.details != nil)   // arriva già idratata
    }

    /// Una registrazione più vecchia — recuperata da un backup, per dire — va al
    /// suo posto e non in testa. L'ordine è quello di `stems`, per nome.
    @MainActor
    @Test func unaRegistrazionePiuVecchiaVaAlSuoPosto() throws {
        let dir = try archivioFinto(["20260818-090000", "20260818-110000"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ArchiveStore()
        store.adotta(DictationIndex.stems(in: dir))

        let mezzo = dir.appendingPathComponent("20260818-100000.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: mezzo)
        try "CONSEGNATO:\nin mezzo\n".write(
            to: dir.appendingPathComponent("20260818-100000.txt"),
            atomically: true, encoding: .utf8)

        store.arrived(mezzo)
        #expect(store.entries.map(\.wav.lastPathComponent) == [
            "20260818-110000.wav", "20260818-100000.wav", "20260818-090000.wav",
        ])
    }

    /// **Idempotenza, ed è il caso vero:** una dettatura ridetta viene marcata
    /// quando è già in lista. Il secondo annuncio deve aggiornarla al suo posto,
    /// non inserirne una copia e non spostarla.
    @MainActor
    @Test func loStessoUrlDueVolteAggiornaSenzaDuplicare() throws {
        let dir = try archivioFinto(["20260818-090000", "20260818-100000"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ArchiveStore()
        store.adotta(DictationIndex.stems(in: dir))
        let vecchia = dir.appendingPathComponent("20260818-090000.wav")
        store.arrived(vecchia)
        let dopoIlPrimo = store.entries.map(\.wav)

        // Il sidecar cambia sotto — è quello che fa `mark` — e il secondo
        // annuncio deve portarsi dietro il cambiamento.
        try "CONSEGNATO:\ntesto\nSOSPETTA: ridetta subito dopo\n".write(
            to: dir.appendingPathComponent("20260818-090000.txt"),
            atomically: true, encoding: .utf8)
        store.arrived(vecchia)

        #expect(store.entries.count == 2)
        #expect(store.entries.map(\.wav) == dopoIlPrimo)   // nessuno si è spostato
        #expect(store.entries.last?.details?.suspect == true)
    }

    /// Un annuncio su un file **già potato** non deve produrre una riga fantasma:
    /// fra la notifica e questa lettura può esserci passata la potatura del tetto,
    /// e una riga che punta a un file sparito è peggio di una riga mancante,
    /// perché si può cliccare. Il nome qui è uno stamp VALIDO — è il file a non
    /// esserci, che è il caso vero.
    @MainActor
    @Test func unFileGiaPotatoNonDiventaUnaRigaFantasma() throws {
        let dir = try archivioFinto(["20260818-090000"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ArchiveStore()
        store.adotta(DictationIndex.stems(in: dir))
        let potata = dir.appendingPathComponent("20260818-080000.wav")
        #expect(DictationIndex.date(fromStem: "20260818-080000") != nil)  // il nome è buono
        #expect(FileManager.default.fileExists(atPath: potata.path) == false)

        store.arrived(potata)
        #expect(store.entries.count == 1)
    }
}
