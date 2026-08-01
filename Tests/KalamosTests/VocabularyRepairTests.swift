import Foundation
import Testing
@testable import Kalamos

/// The vocabulary repair, and above all the ways it must NOT fire.
///
/// Every "must not" here is a real sentence from a real failure: on 2026-07-31 an
/// acoustic rescorer with default settings rewrote "nella sala grande" into
/// "nella sala Claude" and "il 23 settembre" into "il 23 iTerm". That is the
/// failure this guard is measured against, not the missed name — a missed name
/// you can see, a vandalised sentence you cannot.
@Suite struct VocabularyRepairTests {

    /// His real list, as of 2026-08-01 (`defaults read com.kalamos.app vocabulary`).
    static let terms = [
        "Claude", "ChatGPT", "limb-lengthening", "zaya", "QWEN",
        "Claude Desktop", "repo", "Kalamos", "lifeOS", "Parakeet",
    ]

    private func repair(_ s: String) -> String {
        VocabularyRepair.apply(to: s, terms: Self.terms)
    }

    // MARK: The positive pole — the four names three engines got wrong

    @Test func theKThatNoEngineCanHear() {
        // "Calamos" and "Kalamos" are the same sound. Whisper, Parakeet and
        // Cohere all wrote it with a C, 10 passes out of 10 each.
        #expect(repair("Ho aperto Calamos dentro iTerm") == "Ho aperto Kalamos dentro iTerm")
    }

    @Test func theWordBoundaryIsNotInformation() {
        // Where an engine puts its spaces is not information about what it heard,
        // so the comparison drops them: Cohere hears "Claude Desktop" as one word,
        // and a two-word term must still be found in it.
        #expect(repair("ho aperto claudedesktop ieri") == "ho aperto Claude Desktop ieri")
        // And "l'iFOS" → "lifeOS" is exactly the repair the swept threshold gives
        // up: "lifeOS" is six characters, so it is case-normalised and never
        // guessed. Stated as a test so the trade-off is visible rather than
        // discovered later.
        #expect(repair("nella cartella l'iFOS") == "nella cartella l'iFOS")
        #expect(repair("nella cartella lifeos") == "nella cartella lifeOS")
    }

    @Test func casingAloneIsRepairedWithoutAnyDistance() {
        // Parakeet writes "rossi" lowercase and "claude" lowercase. Nothing
        // is being guessed here, so no threshold is involved.
        #expect(repair("ho chiesto a claude") == "ho chiesto a Claude")
        #expect(repair("scarica qwen adesso") == "scarica QWEN adesso")
    }

    @Test func theLongestTermWinsOverItsOwnPrefix() {
        // "Claude Desktop" must not be eaten by "Claude" — which it is, if the
        // terms are applied in list order instead of longest-first.
        #expect(repair("aperto claude desktop ieri") == "aperto Claude Desktop ieri")
    }

    // MARK: The negative pole — the sentences it must leave alone

    @Test func itDoesNotVandaliseOrdinarySpeech() {
        // The four real failures of the acoustic rescorer, 2026-07-31.
        let untouched = [
            "ci vediamo nella sala grande",
            "la consegna è il 23 settembre",
            "fai il push sul branch del repository",
            "ti ho chiesto di controllare il chiodo",
        ]
        for sentence in untouched {
            #expect(repair(sentence) == sentence, "ha toccato «\(sentence)»")
        }
    }

    /// The one the corpus found, and the reason the threshold is seven.
    ///
    /// "Claude" is six characters, so its edit budget is one, and "cloud" is one
    /// edit away. Running the repair over his 240 real dictations turned "una
    /// cartella temporanea di **cloud e** per me" into "di **Claude** per me" —
    /// the wrong word AND the conjunction swallowed. No test would have predicted
    /// this sentence; only the corpus had it.
    @Test func aSixLetterTermDoesNotEatARealWord() {
        let sentence = "una cartella temporanea di cloud e per me non è facile"
        #expect(repair(sentence) == sentence)
        // And the same word spelled right is still normalised, at zero distance.
        #expect(repair("ho chiesto a CLAUDE") == "ho chiesto a Claude")
    }

    @Test func aFourLetterTermNeverGuesses() {
        // "repo" is in his list and is four characters. Every four-letter Italian
        // word is one edit from another one, so fuzzy matching is switched off
        // below seven characters — otherwise "reso", "rete", "remo" all become
        // "repo" and the app starts rewriting ordinary sentences.
        for word in ["reso", "rete", "remo", "reti", "rene"] {
            #expect(repair("ho \(word) il file") == "ho \(word) il file")
        }
        // But the exact word, in any case, still gets its canonical spelling.
        #expect(repair("dentro il REPO") == "dentro il repo")
    }

    @Test func aLongTermDoesNotSwallowALongUnrelatedWord() {
        // A similarity RATIO alone would allow this: "controllare" is 54% similar
        // to "endomidollare", and that exact substitution is one the model made.
        // The absolute budget — max(1, length/5) — is what refuses it.
        let terms = Self.terms + ["endomidollare"]
        let sentence = "ti ho chiesto di controllare il chiodo"
        #expect(VocabularyRepair.apply(to: sentence, terms: terms) == sentence)
        // And the real mishearing, one edit away, IS repaired.
        #expect(VocabularyRepair.apply(to: "il chiodo indomidollare", terms: terms)
                == "il chiodo endomidollare")
    }

    @Test func punctuationAndSpacingSurviveExactly() {
        #expect(repair("Ho aperto Calamos, e poi?") == "Ho aperto Kalamos, e poi?")
        #expect(repair("  claude  ") == "  Claude  ")
        #expect(repair("(qwen)") == "(QWEN)")
    }

    @Test func emptyInputsAreNotAProblem() {
        #expect(VocabularyRepair.apply(to: "", terms: Self.terms) == "")
        #expect(VocabularyRepair.apply(to: "qualcosa", terms: []) == "qualcosa")
    }

    // MARK: The distance function, which nobody would otherwise check

    @Test func theCappedDistanceAgreesWithTheUncappedOne() {
        // A capped Levenshtein that returns cap+1 early is easy to get subtly
        // wrong, and every guard above rests on it.
        let cases: [(String, String, Int)] = [
            ("calamos", "kalamos", 1),
            ("aiterm", "iterm", 1),
            ("lifos", "lifeos", 1),
            ("indomidollare", "endomidollare", 1),
            ("", "abc", 3),
            ("abc", "abc", 0),
            ("kitten", "sitting", 3),
        ]
        for (a, b, want) in cases {
            #expect(VocabularyRepair.distance(a, b, cap: 99) == want, "\(a) vs \(b)")
        }
        // And it abandons rather than lying low.
        #expect(VocabularyRepair.distance("kitten", "sitting", cap: 2) > 2)
    }

    @Test func foldingDropsWhatIsNotEvidence() {
        #expect(VocabularyRepair.fold("l'iFOS") == "lifos")
        #expect(VocabularyRepair.fold("ai Term") == "aiterm")
        #expect(VocabularyRepair.fold("perché") == "perche")
    }
}
