import Foundation
import Testing
@testable import Kalamos

/// Both poles, every time: a redo has to be caught AND ordinary consecutive
/// speech has to be left alone. The second half is the one that matters here —
/// a marker that fires on everything marks nothing, and the whole value of this
/// signal is that it points at three dictations a day instead of twenty.
@Suite("DictationTruth — spotting the dictation that went wrong")
struct DictationTruthTests {

    // Real consecutive pairs from his log, quoted rather than invented: the
    // threshold was measured on this corpus, so the tests have to be made of it.

    /// gap 20s, a proper name that came back one letter short. Similarity 0.85.
    /// The name itself is replaced here — the sentence shape, the gap and the
    /// score are the real ones, and the person's name is nobody's business in a
    /// public repository.
    static let redoA = ("E se lo segnalassimo a Whisper come possibile bug del sistema",
                        "E se lo segnalassimo a WhisperKit come possibile bug del sistema")

    /// gap 39s, and the misheard half is punctuation-shaped: "Command + S"
    /// against "Command S". Similarity 0.83.
    static let redoB = ("Per salvare fai Command + S", "Per salvare fai Command S")

    /// The redo that 0.5 used to miss: the transcription failed so badly that the
    /// two attempts barely share words. Similarity 0.38, gap 7s.
    static let redoC = ("Per salvare fai come andasse.", "Per salvare fai Command + S")

    /// Two dictations that simply followed each other, from the same afternoon.
    /// This is what 88% of consecutive pairs look like.
    static let unrelated = (
        "Dobbiamo aggiungere il lavoro completato oggi a quello che mancava da fare ieri",
        "Ma prima di pubblicarlo su GitHub vorrei capire se può funzionare sull'Apple Store")

    /// **The negative pole that decides the threshold**, and the reason the tests
    /// are quoted from the log instead of invented: this is the highest-scoring
    /// pair in the whole corpus that is NOT a redo. He dictated a quotation, then
    /// dictated the same quotation again as part of a different instruction. At
    /// 0.29 it sits just under the line, and any threshold loose enough to catch
    /// it also catches nineteen pairs of ordinary conversation.
    static let hardestNonRedo = (
        "\"He who is satisfied with his lot is rich\" queste sono le citazioni presenti data da Confucio ma sei sicuro che la traduzione sia corretta?",
        "\"Who is satisfied with his lot is rich.\"")

    @Test("the same sentence said twice scores far above the threshold")
    func redoScoresHigh() {
        #expect(DictationTruth.similarity(Self.redoA.0, Self.redoA.1) >= 0.8)
        #expect(DictationTruth.similarity(Self.redoB.0, Self.redoB.1) >= 0.8)
    }

    @Test("consecutive but unrelated speech stays near zero")
    func unrelatedScoresLow() {
        let s = DictationTruth.similarity(Self.unrelated.0, Self.unrelated.1)
        #expect(s < 0.2, "misurato sul corpus: mediana 0.048, p90 0.125 — \(s)")
    }

    @Test("an identical repeat is 1, two empty strings are 0")
    func edges() {
        #expect(DictationTruth.similarity("ciao come stai", "ciao come stai") == 1.0)
        #expect(DictationTruth.similarity("", "qualcosa") == 0.0)
        #expect(DictationTruth.similarity("", "") == 0.0)
    }

    @Test("case and punctuation do not count as a difference")
    func normalisation() {
        #expect(DictationTruth.similarity("Ciao, come stai?", "ciao come stai") == 1.0)
    }

    @Test("a redo inside the window is caught")
    func catchesRedo() {
        #expect(DictationTruth.isRedo(previous: Self.redoA.0, current: Self.redoA.1, gap: 20))
        #expect(DictationTruth.isRedo(previous: Self.redoB.0, current: Self.redoB.1, gap: 39))
    }

    /// The badly-mangled redo, which the first threshold missed. It is the case
    /// worth catching most, because a transcription that loses this many words is
    /// a worse defect than one that swaps a letter.
    @Test("a redo the two attempts barely share words with is still caught")
    func catchesMangledRedo() {
        #expect(DictationTruth.isRedo(previous: Self.redoC.0, current: Self.redoC.1, gap: 7))
    }

    /// The negative pole, and the reason the clock is in the condition at all:
    /// this app chains consecutive dictations on purpose, so a short gap by
    /// itself would mark half his day as suspect.
    @Test("ordinary chained speech is never marked")
    func leavesChainingAlone() {
        #expect(!DictationTruth.isRedo(previous: Self.unrelated.0, current: Self.unrelated.1, gap: 3))
    }

    /// **The test that fails if the threshold is loosened**, which is what makes
    /// the green above mean anything. Lowering `redoSimilarity` to catch more
    /// redos turns this pair red first, and the corpus says nineteen ordinary
    /// pairs follow it in.
    @Test("the hardest non-redo in the corpus stays unmarked")
    func holdsTheLine() {
        let s = DictationTruth.similarity(Self.hardestNonRedo.0, Self.hardestNonRedo.1)
        #expect(s > 0.2 && s < DictationTruth.redoSimilarity,
                "il polo negativo deve stare vicino alla soglia, non lontano — \(s)")
        #expect(!DictationTruth.isRedo(previous: Self.hardestNonRedo.0,
                                       current: Self.hardestNonRedo.1, gap: 38))
    }

    @Test("the same sentence an hour later is not a redo")
    func windowCloses() {
        #expect(!DictationTruth.isRedo(previous: Self.redoA.0, current: Self.redoA.1, gap: 3600))
        #expect(!DictationTruth.isRedo(previous: Self.redoA.0, current: Self.redoA.1, gap: -1))
    }
}

/// The sidecar is the file that has to survive being read months later by
/// something that is not this app, so its shape is part of the contract.
@Suite("DictationArchive — reading and appending to a sidecar")
struct DictationSidecarTests {

    /// A sidecar exactly as `annotate` writes one, plus the two blocks that get
    /// appended afterwards.
    private func makeSidecar() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kalamos-truth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("20260812-143013.wav")
        try """
        durata audio: 50.0s · microfono aperto: 50.0s
        lingua: it

        GREZZO:
        paghiamo 200€ per la licenza

        CONSEGNATO:
        Paghiamo 200€ per la licenza.
        """.write(to: DictationArchive.sidecar(of: wav), atomically: true, encoding: .utf8)
        return wav
    }

    @Test("a labelled block is read back whole and without its neighbours")
    func readsSections() throws {
        let wav = try makeSidecar()
        #expect(DictationArchive.section("GREZZO", in: wav) == "paghiamo 200€ per la licenza")
        #expect(DictationArchive.section("CONSEGNATO", in: wav) == "Paghiamo 200€ per la licenza.")
        #expect(DictationArchive.section("VERITÀ", in: wav) == nil)
    }

    @Test("marking and recording the truth append, and never overwrite")
    func appendsWithoutLosing() throws {
        let wav = try makeSidecar()
        DictationArchive.mark(wav, reason: "ridetta subito dopo")
        DictationArchive.recordTruth(wav, verbatim: "paghiamo 100 euro per la licenza")

        // The machine's guess survives, which is the point: the file has to show
        // what it wrote AND what was said, or it proves nothing about either.
        #expect(DictationArchive.section("GREZZO", in: wav) == "paghiamo 200€ per la licenza")
        let text = try String(contentsOf: DictationArchive.sidecar(of: wav), encoding: .utf8)
        #expect(text.contains("SOSPETTA: ridetta subito dopo"))
        #expect(DictationArchive.section("VERITÀ", in: wav) == "paghiamo 100 euro per la licenza")
    }

    /// A transcript can contain anything, including a line that looks like a
    /// heading. Only all-caps lines ending in a colon close a block, so ordinary
    /// speech cannot truncate the text it is part of.
    @Test("a sentence with a colon does not end its own block")
    func colonInSpeechIsNotAHeading() throws {
        let wav = try makeSidecar()
        DictationArchive.recordTruth(wav, verbatim: "gli ho detto: vieni domani\ne poi basta")
        #expect(DictationArchive.section("VERITÀ", in: wav) == "gli ho detto: vieni domani\ne poi basta")
    }
}
