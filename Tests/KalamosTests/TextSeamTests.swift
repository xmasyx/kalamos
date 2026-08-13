import Foundation
import Testing
@testable import Kalamos

/// The seam between a repaired stretch and the text around it.
@Suite struct TextSeamTests {
    @Test func theDuplicatedWordAtTheSeamGoes() {
        // Verbatim from the 2026-08-12 repair.
        let joined = TextSeam.join("tutti i progetti che stiamo sviluppando",
                                   "sviluppando, qui abbiamo parlato con System Preferences")
        #expect(joined == "tutti i progetti che stiamo sviluppando, qui abbiamo parlato con System Preferences")
    }

    @Test func aRepeatedPhraseGoesToo() {
        let joined = TextSeam.join("e avere un overview più ampia su tutto",
                                   "più ampia su tutto quello che il mercato offre")
        #expect(joined == "e avere un overview più ampia su tutto quello che il mercato offre")
    }

    @Test func hisOwnRepetitionSurvives() {
        // He really does say this, in the very recording this was built for.
        // A de-duplicator that edits it is worse than the bug it fixes.
        let joined = TextSeam.join("tutto tutto", "tutto, lì mettiamo proprio tutto")
        #expect(joined == "tutto tutto tutto, lì mettiamo proprio tutto")
    }

    @Test func punctuationDoesNotBlockAMatch() {
        // The right-hand rendering is the one kept, so the comma survives — and
        // its capital does not, because nothing before it ended a sentence.
        #expect(TextSeam.join("che stiamo sviluppando.", "Sviluppando, qui abbiamo")
                == "che stiamo sviluppando, qui abbiamo")
    }

    @Test func aCapitalAfterAFullStopIsLeftAlone() {
        #expect(TextSeam.join("questo è finito. Sviluppando", "Sviluppando, riprendo")
                == "questo è finito. Sviluppando, riprendo")
    }

    @Test func unrelatedPiecesAreJustJoined() {
        #expect(TextSeam.join("buongiorno a tutti", "oggi parliamo di altro")
                == "buongiorno a tutti oggi parliamo di altro")
    }

    @Test func anEmptyPieceIsNotASeam() {
        #expect(TextSeam.join("solo questo", "") == "solo questo")
        #expect(TextSeam.join("", "solo questo") == "solo questo")
    }

    @Test func aPieceFullyContainedInTheSeamDisappears() {
        #expect(TextSeam.join("che stiamo sviluppando", "sviluppando") == "che stiamo sviluppando")
    }

    @Test func manyPiecesJoinInOrder() {
        let joined = TextSeam.join(["il primo passaggio", "passaggio del secondo blocco",
                                    "blocco finale e chiudo"])
        #expect(joined == "il primo passaggio del secondo blocco finale e chiudo")
    }
}
