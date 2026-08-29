import Foundation
import Testing
@testable import Kalamos

/// Il vecchio scarico osservava soltanto la fine dei file: sul peso da
/// 1.118.241.216 byte la barra restava immobile, una caduta perdeva tutto e il
/// controllo finale chiamava «corruzione» anche una rete interrotta. La suite
/// inchioda i due poli di ogni rimedio: forme italiane e inglesi, crescita e
/// rifiuto, interno e termine della frazione, parziale respinto e installato.
@Suite struct PunctuationDownloadTests {
    @Test func formatoByteRispettaLeQuattroSoglie() {
        #expect(ByteFormat.stringa(842, virgola: true) == "842 B")
        #expect(ByteFormat.stringa(1_000, virgola: true) == "1 KB")
        #expect(ByteFormat.stringa(441_499, virgola: true) == "441 KB")
        #expect(ByteFormat.stringa(441_500, virgola: true) == "442 KB")
        #expect(ByteFormat.stringa(1_000_000, virgola: true) == "1 MB")
        #expect(ByteFormat.stringa(340_499_999, virgola: true) == "340 MB")
        #expect(ByteFormat.stringa(340_500_000, virgola: true) == "341 MB")
        #expect(ByteFormat.stringa(1_000_000_000, virgola: true) == "1,0 GB")
        #expect(ByteFormat.stringa(PunctuationModel.totaleDownload, virgola: true) == "1,1 GB")
    }

    @Test func gigabyteUsaVirgolaOPuntoSenzaMescolarli() {
        let italiano = ByteFormat.stringa(PunctuationModel.totaleDownload, virgola: true)
        let inglese = ByteFormat.stringa(PunctuationModel.totaleDownload, virgola: false)
        #expect(italiano == "1,1 GB")
        #expect(inglese == "1.1 GB")
        #expect(!inglese.contains(","))
    }

    @Test func progressoAccettaSoloUnaCrescitaReale() {
        let monotono = MonotonicProgress()
        let primo = monotono.emetti(frazione: 0.2, scaricati: 20, totale: 100)
        #expect(primo?.frazione == 0.2)
        #expect(monotono.emetti(frazione: 0.2, scaricati: 20, totale: 100) == nil)
        #expect(monotono.emetti(frazione: 0.1, scaricati: 10, totale: 100) == nil)
        #expect(monotono.emetti(frazione: 0.15, scaricati: 15, totale: 100) == nil)

        let successivo = monotono.emetti(frazione: 0.3, scaricati: 30, totale: 100)
        #expect(successivo?.frazione == 0.3)
        #expect(successivo?.scaricati == 30)
    }

    @Test func ilFileDominanteMuoveLaFrazioneDentroIConfiniGlobali() {
        let totale = PunctuationModel.totaleDownload
        let primaDelPeso = 441 + 2_669 + 265_564
        let peso = 1_118_241_216
        let prima = PunctuationModel.avanzamento(
            completati: primaDelPeso, delFile: 0, totale: totale)
        let duranteUno = PunctuationModel.avanzamento(
            completati: primaDelPeso, delFile: 1, totale: totale)
        let duranteMeta = PunctuationModel.avanzamento(
            completati: primaDelPeso, delFile: peso / 2, totale: totale)
        let duranteUltimo = PunctuationModel.avanzamento(
            completati: primaDelPeso, delFile: peso - 1, totale: totale)
        let dopo = PunctuationModel.avanzamento(
            completati: primaDelPeso, delFile: peso, totale: totale)

        #expect(prima.frazione < duranteUno.frazione)
        #expect(duranteUno.frazione < duranteMeta.frazione)
        #expect(duranteMeta.frazione < duranteUltimo.frazione)
        #expect(duranteUltimo.frazione < dopo.frazione)
    }

    /// Il polo che protegge il cancello dei byte dall'unico modo di aggirarlo:
    /// un 206 che riprende dal punto sbagliato riempirebbe il buco con i byte
    /// giusti al posto sbagliato, e il file finirebbe della taglia esatta e del
    /// contenuto sbagliato. Quattro forme storte più una vera.
    @Test func ilContentRangeSiLeggeOSiRifiuta() {
        #expect(ResumableDownload.inizioContentRange(
            "bytes 1000000000-1118241215/1118241216") == 1_000_000_000)
        #expect(ResumableDownload.inizioContentRange("bytes 0-99/1118241216") == 0)
        #expect(ResumableDownload.inizioContentRange(nil) == nil)
        #expect(ResumableDownload.inizioContentRange("1000-2000/3000") == nil)
        #expect(ResumableDownload.inizioContentRange("bytes */1118241216") == nil)
        #expect(ResumableDownload.inizioContentRange("bytes qualcosa-99/100") == nil)
    }

    @Test func ilTotaleEsattoProduceUnoEsatto() {
        let totale = PunctuationModel.totaleDownload
        let finale = PunctuationModel.avanzamento(
            completati: totale, delFile: 0, totale: totale)
        #expect(finale.scaricati == totale)
        #expect(finale.frazione == 1.0)
    }

    @Test func unParzialeDiTagliaErrataNonVieneInstallato() throws {
        let cartella = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-punct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cartella) }
        let destinazione = cartella.appendingPathComponent("peso.bin")
        let parziale = destinazione.appendingPathExtension("part")
        try Data([1, 2, 3]).write(to: parziale)

        do {
            try ResumableDownload.installaParziale(
                parziale, verso: destinazione, attesi: 4, nome: "peso.bin")
            Issue.record("Un parziale corto ha oltrepassato il cancello di taglia")
        } catch let errore as DownloadFailure {
            if case .tagliaErrata(_, let ottenuti, let attesi) = errore {
                #expect(ottenuti == 3)
                #expect(attesi == 4)
            } else {
                Issue.record("Il parziale corto non è stato distinto da un errore di rete")
            }
        } catch {
            Issue.record("Errore non tipizzato: \(error.localizedDescription)")
        }
        #expect(!FileManager.default.fileExists(atPath: destinazione.path))
        #expect(FileManager.default.fileExists(atPath: parziale.path))
    }

    /// L'altro polo di ISC-4, e quello che prima non esisteva: una connessione
    /// che non si apre deve uscire come `.rete`, non come il «scaricamento
    /// incompleto» che un tempo raccontava la stessa cosa di un file corrotto.
    /// La porta 1 su localhost rifiuta subito, quindi la prova non tocca la rete
    /// vera e non dipende da nessun server.
    @Test func unaConnessioneRifiutataNonSiChiamaCorruzione() async throws {
        let cartella = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-punct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cartella) }
        let destinazione = cartella.appendingPathComponent("peso.bin")

        do {
            try await ResumableDownload.scarica(
                da: URL(string: "http://127.0.0.1:1/peso.bin")!,
                verso: destinazione, attesi: 4, nome: "peso.bin") { _ in }
            Issue.record("Una porta chiusa ha prodotto uno scaricamento riuscito")
        } catch let errore as DownloadFailure {
            if case .rete = errore {
                // Il polo giusto.
            } else {
                Issue.record("Rete caduta classificata come \(errore)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destinazione.path))
    }

    @Test func unParzialeDiTagliaEsattaVieneInstallato() throws {
        let cartella = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-punct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cartella) }
        let destinazione = cartella.appendingPathComponent("peso.bin")
        let parziale = destinazione.appendingPathExtension("part")
        try Data([1, 2, 3, 4]).write(to: parziale)

        try ResumableDownload.installaParziale(
            parziale, verso: destinazione, attesi: 4, nome: "peso.bin")

        #expect(FileManager.default.fileExists(atPath: destinazione.path))
        #expect(!FileManager.default.fileExists(atPath: parziale.path))
        let taglia = try FileManager.default.attributesOfItem(atPath: destinazione.path)[.size] as? Int
        #expect(taglia == 4)
    }
}
