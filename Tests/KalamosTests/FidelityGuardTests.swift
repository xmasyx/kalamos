import Testing
@testable import Kalamos

#if canImport(MLXLLM)

/// The cleanup model occasionally deletes words the speaker actually said — most
/// destructively when the text is self-referential, where a whole lead-in clause
/// can vanish because the model decided the sentence was "really" about its second
/// half. Measured over 58 real dictations, 22 lost at least one content word.
///
/// `droppedTooMuch` is the deterministic net under that: it cannot make the model
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
        #expect(MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// A genuine self-correction DROPS the retracted half on purpose. The guard must
    /// not fire here, or it would undo the feature it is protecting.
    @Test func allowsAGenuineSelfCorrection() {
        let said = "allora ci vediamo domani alle due cioè no facciamo alle tre davanti al bar"
        let got = "Allora ci vediamo domani alle tre davanti al bar."
        #expect(!MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// Ordinary punctuation work changes nothing but the marks.
    @Test func allowsPunctuationOnly() {
        let said = "per il turno di domani sera il messaggio va inviato a costa e poi si aspetta la conferma"
        let got = "Per il turno di domani sera, il messaggio va inviato a Costa e poi si aspetta la conferma."
        #expect(!MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// Filler removal is free: those words are not content.
    @Test func allowsFillerRemoval() {
        let said = "ehm allora praticamente il documento cioè quello nuovo va rivisto insomma prima di lunedì"
        let got = "Allora, il documento nuovo va rivisto prima di lunedì."
        #expect(!MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// Too short to judge: an aggressive guard on six words would fire on normal
    /// edits and send everything to the fallback.
    @Test func staysOutOfShortUtterances() {
        #expect(!MLXFormatter.droppedTooMuch(from: "dammi un attimo", to: "Dammi."))
    }

    /// The tic that made this necessary: a leading "però" deleted as if it were
    /// filler. One word, but it is the word that says the sentence is a concession.
    /// Asking the model nicely did not work, so the guard decides instead.
    @Test func catchesADroppedConnective() {
        let said = "però nella seconda fase deve comunque vedersi il countdown così la persona sa quanto manca"
        let got  = "Nella seconda fase deve comunque vedersi il countdown, così la persona sa quanto manca."
        #expect(MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// …and it must not fire when the connective survived.
    @Test func allowsAKeptConnective() {
        let said = "però nella seconda fase deve comunque vedersi il countdown così la persona sa quanto manca"
        let got  = "Però nella seconda fase deve comunque vedersi il countdown, così la persona sa quanto manca."
        #expect(!MLXFormatter.droppedTooMuch(from: said, to: got))
    }

    /// An empty or wildly truncated answer is the clearest case of all.
    @Test func catchesTruncation() {
        let said = """
            durante la pausa non sono venute fuori le due fasi ma è rimasta quella che \
            vedi nello screenshot e in più in alto a sinistra vedi che metà del testo è \
            in inglese e l'altra metà in italiano
            """
        #expect(MLXFormatter.droppedTooMuch(from: said, to: "Durante la pausa."))
    }
}

#endif
