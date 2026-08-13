import Foundation
import Testing
@testable import Kalamos

/// What ⌃⌥V is allowed to teach the app, and everything it must refuse to.
///
/// The refusals carry more weight than the successes here: a learned rule is
/// global, permanent and applied without anybody looking, so every test below
/// that expects an empty result is guarding text nobody will proofread.
@Suite struct LearnedCorrectionsTests {

    @Test func aMisheardWordBecomesARule() {
        let rules = LearnedCorrections.rules(
            heard: "per Ozium dovremmo inserire un modo facile",
            meant: "per Otium dovremmo inserire un modo facile")
        #expect(rules == [CorrectionRule(wrong: "ozium", correct: "Otium")])
    }

    @Test func punctuationAroundTheWordDoesNotTravelIntoTheRule() {
        let rules = LearnedCorrections.rules(heard: "parliamo di Calamos, poi vediamo",
                                             meant: "parliamo di Kalamos, poi vediamo")
        #expect(rules == [CorrectionRule(wrong: "calamos", correct: "Kalamos")])
    }

    @Test func aNameLearnsItsCapital() {
        let rules = LearnedCorrections.rules(heard: "ho aperto otium stamattina",
                                             meant: "ho aperto Otium stamattina")
        #expect(rules == [CorrectionRule(wrong: "otium", correct: "Otium")])
    }

    // MARK: what it must refuse

    @Test func aNumberIsNeverLearned() {
        // The dictation that started all of this said one hundred and was
        // written two hundred. «200 → 100» would rewrite every future amount.
        let rules = LearnedCorrections.rules(heard: "il totale è 200 euro",
                                             meant: "il totale è 100 euro")
        #expect(rules.isEmpty)
    }

    @Test func aShortWordIsNeverLearned() {
        // "e" against "è" is decided by the sentence, never globally.
        let rules = LearnedCorrections.rules(heard: "questo e quello che serve",
                                             meant: "questo è quello che serve")
        #expect(rules.isEmpty)
    }

    @Test func punctuationOnlyChangesTeachNothing() {
        let rules = LearnedCorrections.rules(heard: "arriva senza una sola virgola",
                                             meant: "arriva, senza una sola virgola")
        #expect(rules.isEmpty)
    }

    @Test func aRewrittenSentenceTeachesNothing() {
        // He did not correct a word, he changed his mind. The alignment between
        // the two texts is meaningless and must produce no rules at all.
        let rules = LearnedCorrections.rules(
            heard: "oggi parliamo del podcast e di come lanciarlo la settimana prossima",
            meant: "domani chiamo il commercialista per la fattura di agosto")
        #expect(rules.isEmpty)
    }

    @Test func anInsertedWordIsNotARule() {
        // Nothing was misheard: a word was added. There is no heard side to key
        // a rule on.
        let rules = LearnedCorrections.rules(heard: "presentiamo tutti progetti nuovi",
                                             meant: "presentiamo tutti i progetti nuovi")
        #expect(rules.isEmpty)
    }

    @Test func aDeletedWordIsNotARule() {
        let rules = LearnedCorrections.rules(heard: "presentiamo proprio tutti i progetti nuovi",
                                             meant: "presentiamo tutti i progetti nuovi")
        #expect(rules.isEmpty)
    }

    @Test func aRuleAlreadyKnownIsNotLearnedAgain() {
        let rules = LearnedCorrections.rules(heard: "per Ozium dovremmo inserire un modo",
                                             meant: "per Otium dovremmo inserire un modo",
                                             known: ["ozium"])
        #expect(rules.isEmpty)
    }

    @Test func atMostThreeRulesComeOutOfOneCorrection() {
        // Long enough that four corrections still leave the two texts obviously
        // the same sentence, which is the case the cap is written for.
        let heard = "stamattina ho lasciato Calamos e Ozium e Parakite e Vignitate aperti sul "
            + "secondo schermo mentre lavoravo al montaggio del podcast in cucina"
        let meant = "stamattina ho lasciato Kalamos e Otium e Parakeet e dignitate aperti sul "
            + "secondo schermo mentre lavoravo al montaggio del podcast in cucina"
        #expect(LearnedCorrections.rules(heard: heard, meant: meant).count == LearnedCorrections.cap)
    }

    @Test func nothingIsLearnedFromNothing() {
        #expect(LearnedCorrections.rules(heard: "", meant: "qualcosa").isEmpty)
        #expect(LearnedCorrections.rules(heard: "qualcosa", meant: "").isEmpty)
    }

    @Test func anIdenticalCorrectionTeachesNothing() {
        // He opened the panel, changed nothing, saved.
        let text = "presentiamo tutti i progetti nuovi domani mattina"
        #expect(LearnedCorrections.rules(heard: text, meant: text).isEmpty)
    }
}
