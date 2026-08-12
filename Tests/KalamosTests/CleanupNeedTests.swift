import Testing
@testable import Kalamos

/// Both poles, every time: the run-on has to reach the model AND the text that
/// is already fine has to stay instant. A trigger that only ever says yes is
/// not a trigger, it is the old behaviour with a new name.
@Suite("CleanupNeed — when the model earns its seconds")
struct CleanupNeedTests {

    /// A real dictation of 2026-08-11, 23:29:17, verbatim from the log. 63 words, and Whisper returned it with not one internal mark.
    /// This is the case the whole feature exists for.
    @Test func theRealRunOnGoesToTheModel() {
        let raw = "Adesso sto parlando a fare un paragrafo lungo perché tu mi dici che oltre " +
            "le 25 parole arriva senza una sola virgola Ma in realtà adesso voglio provare a parlare tanto " +
            "e vediamo un po' cosa succede Perché ad esempio questo è un testo di prova che io sto parlando " +
            "tranquillamente C'è della musica in sottofondo e voglio vedere se alla fine comunque c'è la " +
            "punteggiatura come dovrebbe essere"
        #expect(raw.split(whereSeparator: \.isWhitespace).count > 50)
        #expect(CleanupNeed.needsModel(raw))
    }

    /// The negative pole, and the one that protects the feeling of the app: a
    /// long dictation Whisper already punctuated must NOT pay for the model.
    /// 58% of his dictations over 50 words look like this one.
    @Test func theLongButWellPunctuatedStaysInstant() {
        let raw = "In realtà quella chiave è messa lì perché è all'interno dello script, quindi " +
            "cosa ne pensi? Va spostata per forza? Inoltre dovrebbe esserci anche il file con le varie " +
            "battute che spiega anche il tono da utilizzare, e vorrei capire se ha senso o no. Verifica, " +
            "cercalo!"
        #expect(raw.split(whereSeparator: \.isWhitespace).count > 40)
        #expect(!CleanupNeed.needsModel(raw))
    }

    /// Short text is the overwhelming majority of real use (88% under 50 words)
    /// and never goes to the model, however badly punctuated.
    @Test func shortTextIsAlwaysInstantEvenUnpunctuated() {
        #expect(!CleanupNeed.needsModel("questo è un test breve senza nessuna punteggiatura dentro"))
    }

    /// The boundary is on words, not characters, and it is exclusive: exactly
    /// `minWords` is still short.
    @Test func theWordBoundaryIsExclusive() {
        let word = "parola "
        #expect(!CleanupNeed.needsModel(String(repeating: word, count: CleanupNeed.minWords)))
        #expect(CleanupNeed.needsModel(String(repeating: word, count: CleanupNeed.minWords + 1)))
    }

    /// A long text with a single trailing period is still a wall: one mark in
    /// sixty words is not punctuation, it is a full stop someone remembered.
    @Test func aLoneTrailingPeriodDoesNotSaveAWallOfWords() {
        #expect(CleanupNeed.needsModel(String(repeating: "parola ", count: 60) + "."))
    }

    /// Empty and whitespace never trigger anything, and never divide by zero.
    @Test func emptyIsNeverSentAnywhere() {
        #expect(!CleanupNeed.needsModel(""))
        #expect(!CleanupNeed.needsModel("   \n  "))
    }
}
