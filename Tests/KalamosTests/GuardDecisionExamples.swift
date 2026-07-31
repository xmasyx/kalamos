import Testing
@testable import Kalamos

/// The guard's decisions on real pairs, printed.
///
/// Every case here is `input` = what the speech model heard, `output` = what the
/// cleanup model returned. The guard never sees the audio: it compares the two
/// texts. That distinction matters and is not marketing — if Whisper mishears a
/// word, this cannot catch it. What it catches is the SECOND model changing what
/// the first one heard.
@Suite struct GuardDecisionExamples {

    private func decide(_ input: String, _ output: String, strict: Bool = false) -> String {
        let discarded = MLXFormatter.changedTooMuch(from: input, to: output, strict: strict)
        let verdict = discarded ? "SCARTATO → si usa la pulizia a regole" : "TENUTO"
        print("""

        \(strict ? "[TERMINALE]" : "[NORMALE]  ") \(verdict)
          detto : \(input)
          modello: \(output)
        """)
        return verdict
    }

    @Test func fillerAndPunctuationArePassed() {
        #expect(decide(
            "allora ehm il punto è che dobbiamo consegnare entro venerdì perché il cliente aspetta",
            "Allora, il punto è che dobbiamo consegnare entro venerdì, perché il cliente aspetta."
        ) == "TENUTO")
    }

    @Test func aRealSelfCorrectionIsPassed() {
        #expect(decide(
            "la riunione è martedì alle dieci no aspetta mercoledì alle dieci e mezza nella sala grande",
            "La riunione è mercoledì alle dieci e mezza, nella sala grande."
        ) == "TENUTO")
    }

    /// The afternoon that put this rule in code: a leading "però" deleted four
    /// times. One small word, and the sentence stops conceding anything.
    @Test func aDroppedConnectiveIsAlwaysDiscarded() {
        #expect(decide(
            "però il preventivo che abbiamo mandato non copre la seconda sede quindi va rifatto",
            "Il preventivo che abbiamo mandato non copre la seconda sede, quindi va rifatto."
        ) == "SCARTATO → si usa la pulizia a regole")
    }

    /// A model that decides your sentence was "really" about its second half.
    @Test func aVanishedLeadInIsDiscarded() {
        #expect(decide(
            "quindi il ragionamento sull'allungamento degli arti è che la maggior parte delle persone arriva pensando che sia una questione puramente estetica ma nella pratica quello che cambia è il modo in cui si muovono nel mondo",
            "Quello che cambia è il modo in cui si muovono nel mondo."
        ) == "SCARTATO → si usa la pulizia a regole")
    }

    /// Five words carry no signal: anything past punctuation is the model
    /// rewriting. This is the case that produced a word nobody had said.
    @Test func anInventedWordOnAShortUtteranceIsDiscarded() {
        #expect(decide(
            "Osob je interest",
            "Osob je interessato"
        ) == "SCARTATO → si usa la pulizia a regole")
    }

    /// In a terminal you are dictating something someone will execute, so the
    /// budget is zero — a change that is harmless in prose is not harmless here.
    @Test func inATerminalOneWordIsEnough() {
        let sentence = "fai il commit e poi fai il push sul branch principale del repository"
        #expect(decide(sentence,
                       "Fai il commit e poi il push sul branch principale del repository.",
                       strict: true) == "SCARTATO → si usa la pulizia a regole")
        // The same edit in prose is fine: "fai" repeated is noise, not meaning.
        #expect(decide(sentence,
                       "Fai il commit e poi il push sul branch principale del repository.")
                == "TENUTO")
    }
}

/// A marker that is still in the output was never a retraction.
@Suite struct RetractionMarkerPrecision {
    @Test func aSurvivingMarkerDoesNotWidenTheBudget() {
        // "aspetta" here is a customer waiting. The model deletes a whole
        // lead-in; without the surviving-marker rule the budget would widen and
        // this would sneak through.
        let heard = "allora aspetta che ti spiego il problema della seconda sede perché il cliente aspetta una risposta entro venerdì"
        let mangled = "Il cliente aspetta una risposta entro venerdì."
        #expect(MLXFormatter.changedTooMuch(from: heard, to: mangled))
    }

    @Test func aDeletedMarkerDoesWidenIt() {
        let heard = "mandiamo la proposta giovedì mattina no aspetta scusa venerdì mattina che è meglio"
        let resolved = "Mandiamo la proposta venerdì mattina, che è meglio."
        #expect(!MLXFormatter.changedTooMuch(from: heard, to: resolved))
    }
}
