import Testing
@testable import Kalamos

#if canImport(MLXLLM)

/// The cleanup model occasionally deletes words the speaker actually said — most
/// destructively when the text is self-referential, where a whole lead-in clause
/// can vanish because the model decided the sentence was "really" about its second
/// half. Measured over 58 real dictations, 22 lost at least one content word.
///
/// `changedTooMuch` is the deterministic net under that: it cannot make the model
/// behave, but it can stop a mangled result from reaching the cursor, because the
/// rule-based fallback is strictly better than a confident wrong answer.
@Suite struct FidelityGuardTests {

    /// The real failure, from the log: everything before the example was deleted.
    @Test func catchesALeadInBeingSwallowed() {
        let said = """
            la correzione che hai messo sembra poco scenica devono esserci maggiori \
            correzioni ad esempio oggi sono andato al mare anzi no volevo dire oggi \
            sono andato in montagna
            """
        let got = "Oggi sono andato in montagna. Anzi, volevo dire: oggi sono andato in montagna."
        #expect(MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// A genuine self-correction DROPS the retracted half on purpose. The guard must
    /// not fire here, or it would undo the feature it is protecting.
    @Test func allowsAGenuineSelfCorrection() {
        let said = "allora ci vediamo domani alle due cioè no facciamo alle tre davanti al bar"
        let got = "Allora ci vediamo domani alle tre davanti al bar."
        #expect(!MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// Ordinary punctuation work changes nothing but the marks.
    @Test func allowsPunctuationOnly() {
        let said = "per il turno di domani sera il messaggio va inviato a costa e poi si aspetta la conferma"
        let got = "Per il turno di domani sera, il messaggio va inviato a Costa e poi si aspetta la conferma."
        #expect(!MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// Filler removal is free: those words are not content, so taking them out
    /// changes nothing the guard measures.
    @Test func allowsFillerRemoval() {
        let said = "ehm praticamente il documento nuovo cioè va rivisto insomma prima di lunedì"
        let got = "Il documento nuovo va rivisto prima di lunedì."
        #expect(!MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// A short utterance is where the guard is STRICTEST, not loosest — the
    /// opposite of what it did when first written. There is nothing to restructure
    /// in three words, so deleting one is not cleanup, it is loss. This exact shape
    /// ("Ah yeah, this logo thing" → "This logo thing.") is what made the setting
    /// feel invasive in real use.
    @Test func catchesDeletionInAShortUtterance() {
        #expect(MLXFormatter.changedTooMuch(from: "dammi un attimo", to: "Dammi."))
        #expect(MLXFormatter.changedTooMuch(from: "ah yeah this logo thing", to: "This logo thing."))
    }

    /// The tic that made this necessary: a leading "però" deleted as if it were
    /// filler. One word, but it is the word that says the sentence is a concession.
    /// Asking the model nicely did not work, so the guard decides instead.
    @Test func catchesADroppedConnective() {
        let said = "però nella seconda fase deve comunque vedersi il countdown così la persona sa quanto manca"
        let got  = "Nella seconda fase deve comunque vedersi il countdown, così la persona sa quanto manca."
        #expect(MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// …and it must not fire when the connective survived.
    @Test func allowsAKeptConnective() {
        let said = "però nella seconda fase deve comunque vedersi il countdown così la persona sa quanto manca"
        let got  = "Però nella seconda fase deve comunque vedersi il countdown, così la persona sa quanto manca."
        #expect(!MLXFormatter.changedTooMuch(from: said, to: got))
    }

    /// The model inventing a word — the second failure, found in the log the same
    /// day the first one was fixed. "interest" was misheard, and the cleanup pass
    /// confidently turned it into a different, longer word that was never spoken.
    /// A five-word utterance has nothing to restructure, so it gets no latitude.
    @Test func catchesAnInventedWordInAShortUtterance() {
        #expect(MLXFormatter.changedTooMuch(from: "Osob je interest", to: "Osob je interessato."))
    }

    /// …but punctuation and capitals on a short utterance are exactly the job.
    @Test func allowsPunctuationOnAShortUtterance() {
        #expect(!MLXFormatter.changedTooMuch(from: "chiudi tutto quello che devi chiudere",
                                             to: "Chiudi tutto quello che devi chiudere."))
    }

    /// Invention in a long text: one swapped word inside a sentence that is
    /// otherwise intact must still be caught when it goes beyond the budget.
    @Test func catchesWholesaleRewriting() {
        let said = "per la foto mancante e per le foto mancanti in generale puoi trovarle anche su google"
        let rewritten = "Riguardo alle immagini assenti, in linea di massima reperibili tramite ricerca online."
        #expect(MLXFormatter.changedTooMuch(from: said, to: rewritten))
    }

    /// In a terminal the budget is zero. Filler may go; a word the speaker said
    /// may not, however sensible the replacement looks.
    @Test func strictModeAllowsNothingButFillerAndPunctuation() {
        let said = "allora vediamo se questa cosa funziona come dovrebbe funzionare"
        #expect(!MLXFormatter.changedTooMuch(
            from: said,
            to: "Allora, vediamo se questa cosa funziona come dovrebbe funzionare.",
            strict: true))
        // one word swapped for a synonym — fine anywhere else, not here
        #expect(MLXFormatter.changedTooMuch(
            from: said,
            to: "Allora, vediamo se questa cosa opera come dovrebbe funzionare.",
            strict: true))
        // one word dropped
        #expect(MLXFormatter.changedTooMuch(
            from: said,
            to: "Vediamo se questa cosa funziona come dovrebbe.",
            strict: true))
    }

    /// An empty or wildly truncated answer is the clearest case of all.
    @Test func catchesTruncation() {
        let said = """
            durante la pausa non sono venute fuori le due fasi ma è rimasta quella che \
            vedi nello screenshot e in più in alto a sinistra vedi che metà del testo è \
            in inglese e l'altra metà in italiano
            """
        #expect(MLXFormatter.changedTooMuch(from: said, to: "Durante la pausa."))
    }
}

#endif
