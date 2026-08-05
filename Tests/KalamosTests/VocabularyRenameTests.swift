import Testing
import Foundation
@testable import Kalamos

/// La modifica di una parola già salvata (richiesta sua, 2026-08-05).
///
/// Il difetto che questi test esistono per prevenire non è «non si può
/// modificare»: è **modificare spostando**. `add` accoda, quindi la strada facile
/// (togli e rimetti) manderebbe in fondo alla lista una voce corretta a metà, e
/// chi ha vent'anni di termini non ritrova più quello che ha appena scritto.
@Suite("Vocabolario — modifica di una voce")
struct VocabularyRenameTests {

    @Test("la voce cambia AL SUO POSTO, non in fondo")
    func restaAlSuoPosto() {
        #expect(Vocabulary.renamed(["Claude", "wisper.cpp", "Kalamos"], "wisper.cpp",
                                   to: "whisper.cpp") == ["Claude", "whisper.cpp", "Kalamos"])
    }

    @Test("un nome vuoto non passa, e non lascia una riga fantasma")
    func vuotoRifiutato() {
        #expect(Vocabulary.renamed(["Claude", "Kalamos"], "Kalamos", to: "   ") == nil)
    }

    @Test("un duplicato non passa: due righe identiche, una sola riparabile")
    func duplicatoRifiutato() {
        #expect(Vocabulary.renamed(["Claude", "Kalamos"], "Kalamos", to: "claude") == nil)
    }

    @Test("cambiare solo le maiuscole della STESSA voce si può")
    func soloMaiuscole() {
        #expect(Vocabulary.renamed(["kalamos", "Claude"], "kalamos",
                                   to: "Kalamos") == ["Kalamos", "Claude"])
    }

    @Test("una voce che non esiste non inventa niente")
    func voceInesistente() {
        #expect(Vocabulary.renamed(["Claude"], "Otium", to: "Otium2") == nil)
    }

    @Test("gli spazi ai lati si tolgono, come nell'aggiunta")
    func spaziTolti() {
        #expect(Vocabulary.renamed(["a"], "a", to: "  whisper.cpp  ") == ["whisper.cpp"])
    }
}
