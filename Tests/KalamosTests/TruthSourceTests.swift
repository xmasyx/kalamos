import Foundation
import Testing
@testable import Kalamos

/// Settling a dictation, the two ways.
///
/// Until 2026-08-15 there was one way — retype the words that were wrong — and a
/// recording that had come out right had no way of saying so. His question was
/// the design review: *the ones I never corrected are the ones that were already
/// right; do I have to go back over all of them?* An archive that cannot record
/// "this was fine" answers that question with silence, and the silence looks
/// identical to "nobody ever looked".
@Suite("VERITÀ — corretta, oppure confermata")
struct TruthSourceTests {

    /// The block is found by a heading of CAPITALS ending in a colon. A note in
    /// lower case would stop the line being a heading, and the verbatim would be
    /// read back as part of whatever came before it — a settled dictation that
    /// reports itself unsettled forever.
    ///
    /// This is the whole reason the test exists: the file looks completely
    /// reasonable when a person opens it, so nothing else would have caught it.
    @Test("L'intestazione resta un'intestazione anche con la nota dentro")
    func noteKeepsHeadingShape() throws {
        for how in [DictationArchive.TruthSource.corrected, .confirmed, .confirmedInBulk] {
            let heading = "VERITÀ (2026-08-15 22:50\(how.note)):"
            #expect(heading.hasSuffix(":"))
            // The rule in `isHeading`, applied here rather than quoted at it: no
            // lower-case letter anywhere before the colon.
            #expect(!heading.dropLast().contains { $0.isLowercase },
                    "«\(heading)» non sarebbe più un'intestazione")
        }
    }

    /// The negative pole. Written this way first, and it compiled, ran, and wrote
    /// files that read back wrong.
    @Test("Una nota in minuscolo romperebbe l'intestazione")
    func lowercaseNoteWouldBreakIt() {
        let broken = "VERITÀ (2026-08-15 22:50, confermata senza modifiche):"
        #expect(broken.dropLast().contains { $0.isLowercase })
    }

    @Test("Le tre origini restano distinguibili nel file")
    func sourcesAreDistinct() {
        let notes = [DictationArchive.TruthSource.corrected.note,
                     DictationArchive.TruthSource.confirmed.note,
                     DictationArchive.TruthSource.confirmedInBulk.note]
        #expect(Set(notes).count == 3)
        #expect(DictationArchive.TruthSource.corrected.note.isEmpty)
    }

    // MARK: read back what was written

    /// End to end on a real sidecar: write a confirmation, read it back as
    /// settled. Counting the ways it can be written is not the same as proving
    /// one can be read (2026-08-04, gli identificatori dei segnalibri).
    @Test("Una conferma scritta si rilegge come sistemata")
    func writtenConfirmationReadsBack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalamos-truth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("20260815-151553.wav")
        try Data().write(to: wav)
        try """
        durata audio: 20.6s · microfono aperto: 20.7s
        lingua: it

        GREZZO:
        installiamo anche questa

        CONSEGNATO:
        Installiamo anche questa.
        """.write(to: DictationArchive.sidecar(of: wav), atomically: true, encoding: .utf8)

        #expect(!DictationArchive.isSettled(wav))

        DictationArchive.recordTruth(wav, verbatim: "installiamo anche questa", how: .confirmedInBulk)

        #expect(DictationArchive.isSettled(wav))
        #expect(DictationArchive.section("VERITÀ", in: wav) == "installiamo anche questa")
        // The blocks that were already there survive the append.
        #expect(DictationArchive.section("GREZZO", in: wav) == "installiamo anche questa")
        #expect(DictationArchive.section("CONSEGNATO", in: wav) == "Installiamo anche questa.")

        let file = try String(contentsOf: DictationArchive.sidecar(of: wav), encoding: .utf8)
        #expect(file.contains("CONFERMATA IN BLOCCO"))
    }
}

/// Il marchio «da verificare», nato il 2026-08-20 insieme alla morte della
/// classe «presunta»: 375 dettature erano finite nel corpus di allenamento col
/// grezzo preso per buono, e lui voleva poterle riguardare.
@Suite("DA VERIFICARE — il marchio che le rimette sotto i suoi occhi")
struct NeedsCheckTests {

    private static func sidecar(_ dir: URL, stem: String) throws -> URL {
        let wav = dir.appendingPathComponent("\(stem).wav")
        try Data().write(to: wav)
        try """
        durata audio: 12.0s · microfono aperto: 12.1s
        lingua: it

        GREZZO:
        per lifeos da vedere i gestionali

        CONSEGNATO:
        per LifeOS da vedere i gestionali
        """.write(to: DictationArchive.sidecar(of: wav), atomically: true, encoding: .utf8)
        return wav
    }

    private static func inATempDir(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalamos-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Il polo negativo prima di quello positivo: un file non marcato deve dire
    /// di no, altrimenti il sì non significa niente.
    @Test("Non marcata dice no, marcata dice sì, e due marchi restano uno")
    func markRoundTrip() throws {
        try Self.inATempDir { dir in
            let wav = try Self.sidecar(dir, stem: "20260810-101010")
            #expect(!DictationArchive.needsCheck(wav))
            #expect(DictationIndex.details(of: wav).needsCheck == false)

            DictationArchive.markNeedsCheck(wav, reason: "era entrata nell'allenamento senza il tuo sì")
            #expect(DictationArchive.needsCheck(wav))
            #expect(DictationIndex.details(of: wav).needsCheck)

            // Idempotente: rieseguire la marcatura non impila intestazioni.
            DictationArchive.markNeedsCheck(wav, reason: "un altro motivo")
            let testo = try String(contentsOf: DictationArchive.sidecar(of: wav), encoding: .utf8)
            #expect(testo.components(separatedBy: "DA VERIFICARE:").count - 1 == 1)
        }
    }

    /// **Il difetto che questo test esiste per prendere.** `SOSPETTA:` è una riga
    /// qualsiasi appesa in fondo, quindi finisce dentro l'ultimo blocco aperto e
    /// il testo della dettatura se la porta dietro. Il marchio nuovo è
    /// un'intestazione vera e CHIUDE il blocco: il testo consegnato resta quello
    /// che lui ha detto, e la riga in lista non mostra il motivo del marchio.
    @Test("Il marchio non entra nel testo della dettatura")
    func markDoesNotLeakIntoTheText() throws {
        try Self.inATempDir { dir in
            let wav = try Self.sidecar(dir, stem: "20260810-101011")
            let prima = DictationArchive.section("CONSEGNATO", in: wav)
            DictationArchive.markNeedsCheck(wav, reason: "era entrata nell'allenamento senza il tuo sì")
            #expect(DictationArchive.section("CONSEGNATO", in: wav) == prima)
            #expect(DictationIndex.details(of: wav).text == "per LifeOS da vedere i gestionali")
            #expect(DictationArchive.section("DA VERIFICARE", in: wav)
                == "era entrata nell'allenamento senza il tuo sì")
        }
    }

    /// Marcata e poi sistemata: il marchio resta scritto (è storia), ma la
    /// dettatura risulta sistemata e il pallino nella lista si spegne.
    @Test("Sistemarla dopo il marchio la chiude lo stesso")
    func settlingAfterTheMarkStillWorks() throws {
        try Self.inATempDir { dir in
            let wav = try Self.sidecar(dir, stem: "20260810-101012")
            DictationArchive.markNeedsCheck(wav, reason: "era entrata nell'allenamento senza il tuo sì")
            DictationArchive.recordTruth(wav, verbatim: "per LifeOS da vedere i gestionali",
                                         how: .confirmed)
            let d = DictationIndex.details(of: wav)
            #expect(d.corrected)
            #expect(d.needsCheck)
            #expect(DictationArchive.truthSource(of: wav) == .confirmed)
            #expect(TrainingCorpus.trainable(DictationEntry(wav: wav, started: Date(), details: nil)) != nil)
        }
    }
}
