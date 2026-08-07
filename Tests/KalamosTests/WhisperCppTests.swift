import Testing
import Foundation
@testable import Kalamos

// Il terzo motore, 2026-08-05. Qui NON si prova che whisper.cpp trascriva bene —
// quello è il banco, `03-Plans/kalamos-whispercpp/`, che gira su audio vero e con
// un modello da 1,6 GB. Qui si provano le tre cose che possono rompersi
// modificando il codice: il giro del motore attivo, la guardia sul decode
// impazzito, e il rifiuto di un modello arrivato a metà.

@Suite("Terzo motore — whisper.cpp")
struct WhisperCppTests {

    // MARK: - Il giro del motore attivo

    /// Un finto motore che dice il proprio nome, così si vede CHI ha risposto.
    private final class Eco: Transcriber, @unchecked Sendable {
        let nome: String
        private let promptBox = Box()
        init(_ nome: String) { self.nome = nome }
        func prepare() async throws {}
        func transcribe(_ samples: [Float], allowedLanguages: Set<Language>,
                        forced: Language?) async throws -> TranscriptionResult {
            TranscriptionResult(text: nome, detectedLanguage: forced)
        }
        func setVocabulary(_ terms: [String]) { promptBox.value = terms.joined(separator: ", ") }
        var prompt: String? { promptBox.value }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func switchConTre() -> (SpeechEngineSwitch, Eco, Eco, Eco) {
        let w = Eco("whisper"), p = Eco("parakeet"), c = Eco("whispercpp")
        return (SpeechEngineSwitch(engine: .whisper, whisper: w, parakeet: p, whispercpp: c), w, p, c)
    }

    @Test("ogni caso dell'enum arriva al proprio motore")
    func instradamento() async throws {
        let (sw, _, _, _) = switchConTre()
        // Polo positivo e polo negativo insieme: non basta che `whispercpp`
        // risponda, serve che gli altri due continuino a rispondere loro. Il bug
        // che questo test previene è il ternario che c'era prima, che avrebbe
        // mandato il caso nuovo a Parakeet senza un errore di compilazione.
        for atteso in SpeechEngine.allCases {
            sw.use(atteso)
            let r = try await sw.transcribe([0.5, 0.5], allowedLanguages: [.italian], forced: .italian)
            #expect(r.text == atteso.rawValue)
        }
    }

    @Test("il vocabolario va SOLO al motore attivo")
    func promptSoloAllAttivo() async throws {
        let (sw, w, p, c) = switchConTre()
        sw.use(.whispercpp)
        sw.setVocabulary(["Kalamos", "Otium", "fork"])
        #expect(c.prompt == "Kalamos, Otium, fork")
        #expect(w.prompt == nil)
        #expect(p.prompt == nil)
    }

    @Test("i tre casi hanno titoli distinti e nessuno è vuoto")
    func titoli() {
        let titoli = SpeechEngine.allCases.map(\.title)
        #expect(titoli.count == Set(titoli).count)
        #expect(titoli.allSatisfy { !$0.isEmpty })
    }

    // MARK: - La guardia sul decode impazzito

    @Test("tre frasi identiche di fila sono un decode in loop")
    func loopRilevato() {
        // Il testo vero misurato il 5/08 col prompt e senza carry_initial_prompt.
        let degenerato = String(repeating: "La riposizione è fatta da 1:00 al mese. ", count: 13)
        #expect(RepetitionGuard.degenerated(degenerato))
        #expect(RepetitionGuard.longestRun(in: degenerato).count == 13)
    }

    @Test("il polo negativo: il parlato normale non viene accusato")
    func nessunFalsoAllarme() {
        // Una sua dettatura vera, e due ripetizioni non consecutive, che in
        // italiano parlato capitano di continuo.
        let sano = "Va bene, allora chiudiamo qui. La prima opzione non mi convince. Va bene."
        #expect(!RepetitionGuard.degenerated(sano))
        #expect(RepetitionGuard.longestRun(in: sano).count == 1)

        // Due di fila restano sotto soglia: due è parlato, tre è guasto.
        let dueDiFila = "Va bene. Va bene. Poi ne parliamo."
        #expect(!RepetitionGuard.degenerated(dueDiFila))
        #expect(RepetitionGuard.longestRun(in: dueDiFila).count == 2)
    }

    @Test("testo vuoto non manda in crisi la guardia")
    func vuoto() {
        #expect(!RepetitionGuard.degenerated(""))
        #expect(RepetitionGuard.longestRun(in: "   ").count == 0)
    }

    // MARK: - Il prompt mirato

    private let suoVocabolario = ["Claude", "ChatGPT", "limb-lengthening", "zaya", "QWEN",
                                  "Claude Desktop", "repo", "Kalamos", "LifeOS", "Parakeet",
                                  "iTerm", "endomidollare", "AssemblyAI", "Otium", "font", "excel"]

    @Test("tiene solo i termini che il grezzo sembra aver sbagliato")
    func soloISbagliati() {
        // Il grezzo vero di whisper.cpp sulla clip r02, misurato il 5/08. Il cognome che stava nella
        // dettatura è sostituito con uno d'esempio: questo repo è pubblico, e il nome di una persona
        // vera dentro una frase clinica non c'entra niente con quello che il test prova.
        let grezzo = "Ho aperto Calamos dentro iTerm e ho chiesto a Claude di controllare il chiodo endomidollare che mi ha nominato Rossi nella cartella LiveOS."
        let scelti = VocabularyPrompt.candidates(for: grezzo, terms: suoVocabolario)
        #expect(scelti.contains("Kalamos"))   // «Calamos»
        #expect(scelti.contains("LifeOS"))    // «LiveOS»
        // E NON i termini già scritti bene: è tutto il punto, perché è la
        // lunghezza del prompt a fare il danno.
        #expect(!scelti.contains("iTerm"))
        #expect(!scelti.contains("Claude"))
        #expect(!scelti.contains("endomidollare"))
        #expect(scelti.count <= VocabularyPrompt.maxTerms)
    }

    @Test("il polo negativo: se il grezzo è già giusto non si fa nessun secondo giro")
    func nienteSecondoGiro() {
        let giusto = "Ho aperto Kalamos dentro iTerm e ho chiesto a Claude di controllare il chiodo endomidollare nella cartella LifeOS."
        #expect(VocabularyPrompt.text(for: giusto, terms: suoVocabolario) == nil)
    }

    @Test("un testo che non c'entra niente non tira dentro nessun termine")
    func nessunFalsoCandidato() {
        let altro = "Domani mattina ci vediamo in ufficio e vediamo insieme il preventivo."
        #expect(VocabularyPrompt.text(for: altro, terms: suoVocabolario) == nil)
    }

    @Test("il prompt è una lista di termini, non una frase con un'etichetta")
    func formaDelPrompt() {
        let grezzo = "ho aperto Calamos"
        let p = VocabularyPrompt.text(for: grezzo, terms: suoVocabolario)
        #expect(p == "Kalamos.")
        // Un'etichetta fa credere al modello di trascrivere un glossario.
        #expect(!(p ?? "").lowercased().contains("glossario"))
    }

    // MARK: - Il modello arrivato a metà

    @Test("un file troppo corto viene rifiutato e cancellato")
    func modelloIncompleto() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalamos-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let finto = dir.appendingPathComponent("ggml-large-v3-turbo.bin")
        // Quello che arriva davvero quando una URL risponde con una pagina
        // d'errore: qualche kilobyte di HTML con l'estensione giusta.
        try Data(repeating: 0x3C, count: 2048).write(to: finto)

        #expect(throws: (any Error).self) {
            try WhisperCppTranscriber.assertModelArrived(at: finto)
        }
        // E non lo lascia sul disco: un file corto lasciato lì verrebbe creduto
        // installato al prossimo avvio, e il difetto tornerebbe muto.
        #expect(!FileManager.default.fileExists(atPath: finto.path))
    }
}
