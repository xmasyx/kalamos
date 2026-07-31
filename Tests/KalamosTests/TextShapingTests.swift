import Testing
@testable import Kalamos

/// Chaining one dictation onto the last one (ISC-109).
@Suite struct TextShapingTests {

    private func shape(_ text: String, after before: String?) -> String {
        TextShaping.prepare(text, before: before, addSpace: true, smartCapitals: true)
    }

    @Test func continuesASentenceInLowercase() {
        #expect(shape("Poi andiamo a cena", after: "ci vediamo alle otto e") == " poi andiamo a cena")
    }

    @Test func startsANewSentenceWithACapital() {
        #expect(shape("poi andiamo a cena", after: "Ci vediamo alle otto.") == " Poi andiamo a cena")
    }

    @Test func addsNoSpaceWhenThereIsAlreadyOne() {
        #expect(shape("ciao", after: "dimmi ") == "ciao")
    }

    @Test func addsNoSpaceAtTheVeryBeginning() {
        #expect(shape("ciao", after: "") == "Ciao")
    }

    /// A space before a comma is wrong in all three languages.
    @Test func neverPutsASpaceBeforeBindingPunctuation() {
        #expect(shape(", e poi ne parliamo", after: "va bene") == ", e poi ne parliamo")
    }

    /// Electron and terminals answer nothing. The space is still added — it is
    /// what the setting was turned on for — but the capital is left alone,
    /// because changing it would be a guess.
    @Test func withoutContextItAddsTheSpaceAndLeavesTheCapital() {
        #expect(shape("Poi andiamo a cena", after: nil) == " Poi andiamo a cena")
        #expect(shape("poi andiamo a cena", after: nil) == " poi andiamo a cena")
    }

    /// An acronym is not a capitalised sentence.
    @Test func doesNotLowercaseAnAcronym() {
        #expect(shape("API restituisce una lista", after: "quando chiami il servizio")
                == " API restituisce una lista")
    }

    @Test func bothSettingsOffChangesNothing() {
        #expect(TextShaping.prepare("ciao", before: "dimmi", addSpace: false, smartCapitals: false)
                == "ciao")
    }
}

/// The two small toggles for search fields and terminals.
@Suite struct SearchFieldTogglesTests {
    @Test func dropsTheFinalFullStopButNotAQuestionMark() {
        #expect(TextShaping.prepare("come si chiama.", before: nil, addSpace: false,
                                    smartCapitals: false, dropTrailingPeriod: true)
                == "come si chiama")
        #expect(TextShaping.prepare("come si chiama?", before: nil, addSpace: false,
                                    smartCapitals: false, dropTrailingPeriod: true)
                == "come si chiama?")
    }

    /// An ellipsis is not a full stop someone forgot to remove.
    @Test func leavesAnEllipsisAlone() {
        #expect(TextShaping.prepare("aspetta…", before: nil, addSpace: false,
                                    smartCapitals: false, dropTrailingPeriod: true)
                == "aspetta…")
        #expect(TextShaping.prepare("aspetta...", before: nil, addSpace: false,
                                    smartCapitals: false, dropTrailingPeriod: true)
                == "aspetta...")
    }

    @Test func forcedLowercaseBeatsTheContextRule() {
        // Context says "new sentence, capitalise"; the explicit setting wins.
        #expect(TextShaping.prepare("Roma", before: "cerca.", addSpace: false,
                                    smartCapitals: true, forceLowercase: true)
                == "roma")
    }
}
