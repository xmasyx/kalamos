import Foundation
import Testing
@testable import Kalamos

/// Dictated shortcuts, and the ordinary sentences that must survive them.
///
/// The half that matters is the second one. A shortcut that does not get its
/// plus is a plus you type yourself; a sentence that gets one it did not ask for
/// is a sentence you have to go back and repair, and you only notice after you
/// have sent it.
@Suite struct KeyCombosTests {

    private func shape(_ s: String) -> String { KeyCombos.apply(to: s) }

    // MARK: What it is for

    @Test func oneModifierAndOneLetter() {
        #expect(shape("CMD A") == "CMD+A")
        #expect(shape("CTRL A") == "CTRL+A")
        #expect(shape("premi CMD S per salvare") == "premi CMD+S per salvare")
    }

    @Test func twoModifiersStack() {
        #expect(shape("CMD SHIFT A") == "CMD+SHIFT+A")
        #expect(shape("CTRL ALT CANC") == "CTRL+ALT+CANC")
    }

    @Test func keysWithNamesCount() {
        #expect(shape("CMD invio") == "CMD+invio")
        #expect(shape("ALT tab") == "ALT+tab")
        #expect(shape("CMD F5") == "CMD+F5")
        #expect(shape("CTRL 3") == "CTRL+3")
    }

    @Test func casingIsTheSpeakersChoice() {
        // "cmd" and "comando" are two ways he says the same key. Normalising one
        // into the other would be a decision nobody asked for; the plus is the
        // only thing being added.
        #expect(shape("cmd b") == "cmd+b")
        #expect(shape("premi ctrl S") == "premi ctrl+S")
    }

    // MARK: The negative pole — ordinary sentences

    @Test func anItalianNounIsNeverAModifier() {
        // The sentences this costs a feature to protect. The first version
        // accepted "opzione" and "controllo" behind an article guard, and this
        // list broke it: "la prima opzione B" puts an adjective in between, so
        // the word in front is not an article and the guard never fires. Italian
        // key-nouns are out entirely, and "comando S" gets no plus — a stated
        // price, not a bug.
        let untouched = [
            "l'opzione B è migliore",
            "la prima opzione B non mi convince",
            "il controllo A è già passato",
            "questa opzione A la scarto",
            "premi comando S per salvare",
            "the option B is better",
        ]
        for sentence in untouched {
            #expect(shape(sentence) == sentence, "ha toccato «\(sentence)»")
        }
    }

    @Test func aModifierWithNothingToPressIsJustAWord() {
        #expect(shape("il comando è partito") == "il comando è partito")
        #expect(shape("shift verso destra") == "shift verso destra")
        #expect(shape("ho perso il controllo della situazione")
                == "ho perso il controllo della situazione")
        // "e" is a conjunction, and it follows a key name constantly. A single
        // letter that is also a word only counts when it is capital, which is how
        // a dictated shortcut arrives and how a conjunction never does.
        #expect(shape("premi shift e vai avanti") == "premi shift e vai avanti")
        #expect(shape("usa ctrl o lascia stare") == "usa ctrl o lascia stare")
        #expect(shape("CMD E") == "CMD+E")
        #expect(shape("cmd a") == "cmd a")
    }

    @Test func punctuationBetweenThemEndsTheRun() {
        // "CMD, A" is a list, not a chord — whatever the words say, something
        // came between them.
        #expect(shape("CMD, A") == "CMD, A")
        #expect(shape("CMD. A") == "CMD. A")
        #expect(shape("usa CMD\nA") == "usa CMD\nA")
    }

    @Test func aWholeWordAfterAModifierIsNotAKey() {
        #expect(shape("CMD apri il file") == "CMD apri il file")
        #expect(shape("premi shift adesso") == "premi shift adesso")
    }

    @Test func emptyAndShortInputsAreFine() {
        #expect(shape("") == "")
        #expect(shape("CMD") == "CMD")
        #expect(shape("A") == "A")
    }

    // MARK: The whole point, in one sentence of his

    @Test func aRealInstructionSurvivesIntact() {
        let said = "per salvare fai CMD S e poi CMD SHIFT P per aprire la palette"
        #expect(shape(said) == "per salvare fai CMD+S e poi CMD+SHIFT+P per aprire la palette")
    }
}
