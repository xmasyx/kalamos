import Foundation
import Testing
@testable import Kalamos

/// The corpus set aside for a fine-tune: when a batch goes out, and what one
/// line of it says.
///
/// The disk half of this — copy the wav, append the line — is tested by using
/// the app; what is testable without one is the arithmetic that decides *when*,
/// and the shape of what gets written, which is the part a training script will
/// read months from now with nobody around to fix it.
@Suite("TrainingCorpus — le coppie messe da parte")
struct TrainingCorpusTests {

    @Test("Un blocco esce quando ci sono venticinque correzioni nuove")
    func batchThreshold() {
        #expect(TrainingCorpus.shouldExport(have: 25, exported: 0))
        #expect(TrainingCorpus.shouldExport(have: 60, exported: 35))
        #expect(TrainingCorpus.shouldExport(have: 100, exported: 0))
    }

    /// The pole that matters: this runs on the tail of every single correction,
    /// so a threshold that fires early would copy a 400 KB file inside a gesture
    /// that is supposed to feel instant.
    @Test("Sotto la soglia non esce niente")
    func belowThresholdDoesNothing() {
        #expect(!TrainingCorpus.shouldExport(have: 24, exported: 0))
        #expect(!TrainingCorpus.shouldExport(have: 59, exported: 35))
        #expect(!TrainingCorpus.shouldExport(have: 0, exported: 0))
    }

    /// An archive that has been pruned holds fewer corrected pairs than have
    /// already gone out. That is the normal end state, not an anomaly, and it
    /// must not come out as a permanently armed export.
    @Test("Se l'archivio è stato potato sotto quello già esportato, non riparte")
    func prunedArchiveDoesNotRetrigger() {
        #expect(!TrainingCorpus.shouldExport(have: 10, exported: 200))
        #expect(!TrainingCorpus.shouldExport(have: 0, exported: 25))
    }

    @Test("La soglia è un parametro, e a uno esce ogni volta")
    func thresholdIsAParameter() {
        #expect(TrainingCorpus.shouldExport(have: 1, exported: 0, batch: 1))
        #expect(!TrainingCorpus.shouldExport(have: 1, exported: 1, batch: 1))
    }

    // MARK: one line of the manifest

    static let sample = TrainingCorpus.line(
        audio: "audio/20260815-151553.wav",
        verbatim: "per LifeOS da vedere i gestionali che avevamo sviluppato",
        heard: "per lifeos da vedere i gestionali che avevamo sviluppato",
        language: "it",
        seconds: 20.6,
        started: Date(timeIntervalSince1970: 1_786_000_000), source: .corrected)

    @Test("Una riga è un oggetto JSON valido, su una riga sola")
    func lineIsOneJSONObject() throws {
        #expect(!Self.sample.contains("\n"))
        let obj = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.sample.utf8)) as? [String: Any])
        #expect(obj["audio"] as? String == "audio/20260815-151553.wav")
        #expect(obj["language"] as? String == "it")
        #expect(obj["duration"] as? Double == 20.6)
    }

    /// `text` is the target of the training, so it has to be the verbatim he
    /// typed and never what the engine produced. Getting these two the wrong way
    /// round would train the model to reproduce its own mistakes, and nothing
    /// downstream could tell.
    @Test("Il campo «text» è il verbatim, e il grezzo resta accanto")
    func targetIsTheVerbatim() throws {
        let obj = try #require(try JSONSerialization.jsonObject(
            with: Data(Self.sample.utf8)) as? [String: Any])
        #expect(obj["text"] as? String == "per LifeOS da vedere i gestionali che avevamo sviluppato")
        #expect(obj["heard"] as? String == "per lifeos da vedere i gestionali che avevamo sviluppato")
        #expect(obj["text"] as? String != obj["heard"] as? String)
    }

    /// Apostrophes, accents and quotation marks are in every second Italian
    /// sentence; a manifest that breaks on them breaks on ordinary speech.
    @Test("Virgolette e accenti non rompono la riga")
    func quotingSurvives() throws {
        let line = TrainingCorpus.line(
            audio: "audio/x.wav",
            verbatim: "l'«ecopadoy» è già funzionale, no?\tdavvero",
            heard: "l'ecopadoy e gia funzionale",
            language: "it", seconds: 3, started: Date(timeIntervalSince1970: 0), source: .confirmed)
        #expect(!line.contains("\n"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["text"] as? String == "l'«ecopadoy» è già funzionale, no?\tdavvero")
    }

    /// Every line says how much it is worth. Without it, a guess the app made
    /// and a sentence he retyped by hand are the same row in the same file, and
    /// nothing downstream can ever tell them apart again.
    @Test("Ogni riga dichiara da dove viene")
    func lineCarriesItsSource() throws {
        for how in [DictationArchive.TruthSource.corrected, .confirmed, .confirmedInBulk, .presumed] {
            let line = TrainingCorpus.line(audio: "audio/x.wav", verbatim: "ciao", heard: "ciao",
                                           language: "it", seconds: 1,
                                           started: Date(timeIntervalSince1970: 0), source: how)
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(obj["source"] as? String == how.rawValue)
        }
        #expect(DictationArchive.TruthSource.confirmedInBulk.rawValue == "confirmed_bulk")
    }

    // MARK: which recordings are worth training on

    /// A sidecar on disk, because `trainable` reads one.
    static func sidecar(_ dir: URL, stem: String, raw: String, extra: String = "") throws -> DictationEntry {
        let wav = dir.appendingPathComponent("\(stem).wav")
        try Data().write(to: wav)
        try """
        durata audio: 12.0s · microfono aperto: 12.1s
        lingua: it

        GREZZO:
        \(raw)
        \(extra)
        """.write(to: DictationArchive.sidecar(of: wav), atomically: true, encoding: .utf8)
        return DictationEntry(wav: wav, started: DictationIndex.date(fromStem: stem) ?? Date(), details: nil)
    }

    @Test("Una dettatura usata e mai ripresa NON entra")
    func untouchedNeverEnters() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalamos-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let e = try Self.sidecar(dir, stem: "20260810-101010", raw: "installiamo anche questa")
        // Il polo che conta: per quanto vecchia, senza la sua parola non entra.
        #expect(TrainingCorpus.trainable(e) == nil)

        // Corretta da lui: adesso sì, e con le parole sue.
        DictationArchive.recordTruth(e.wav, verbatim: "installiamo anche quella", how: .corrected)
        let after = try #require(TrainingCorpus.trainable(e))
        #expect(after.1 == .corrected)
        #expect(after.0 == "installiamo anche quella")
    }

    /// The refusals matter more than the acceptance: each one is a way of putting
    /// a sentence he never approved into a training set.
    @Test("Sospetta, vuota o mai guardata non entrano")
    func refusals() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalamos-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Flagged by the app as a redo he never settled.
        let suspect = try Self.sidecar(dir, stem: "20260810-101011", raw: "ciao come stai",
                                       extra: "\nSOSPETTA: ridettata dopo 12s")
        #expect(TrainingCorpus.trainable(suspect) == nil)

        // Nothing was written: there is no target to train towards.
        let empty = try Self.sidecar(dir, stem: "20260810-101012", raw: "")
        #expect(TrainingCorpus.trainable(empty) == nil)

        // Detta un minuto fa e mai guardata: il silenzio non è una prova, e non
        // lo diventa invecchiando. Confermata, entra.
        let fresh = try Self.sidecar(dir, stem: "20260810-101013", raw: "prova")
        #expect(TrainingCorpus.trainable(fresh) == nil)
        DictationArchive.recordTruth(fresh.wav, verbatim: "prova", how: .confirmed)
        #expect(TrainingCorpus.trainable(fresh) != nil)
    }
}
