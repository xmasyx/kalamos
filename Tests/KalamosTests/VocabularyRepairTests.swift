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

    /// A vocabulary with the shapes that matter, not a real user's list.
    ///
    /// Every entry is here for a property the tests exercise: a four-letter term
    /// that must never be guessed at ("repo"), a six-letter one that collides
    /// with an ordinary word ("Claude" against "cloud"), a two-word one that a
    /// single-word term could swallow ("Claude Desktop"), and one whose casing
    /// is its whole point ("lifeOS"). Public product names only — the list a
    /// person actually dictates with says what they work on, and a test fixture
    /// is a poor place to publish that.
    static let terms = [
        "Claude", "ChatGPT", "QWEN", "Claude Desktop",
        "repo", "Kalamos", "lifeOS", "Parakeet",
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
        // Parakeet's two real mis-splits on his own recordings, 10 passes out of
        // 10 each: the article swallows the head of the foreign word.
        #expect(repair("nella cartella l'iFOS") == "nella cartella lifeOS")
        #expect(repair("nella cartella lifeos") == "nella cartella lifeOS")
    }

    /// The direction rule, which is what let the floor drop below seven.
    ///
    /// A window wider than the term is a bet that the engine split one word in
    /// two, and that bet is only right leftwards: "iTerm" arrives as "ai term",
    /// never as "iTe rm". Symmetric widening is what turned "di cloud e per me"
    /// into "di Claude per me" — the conjunction after the word was eaten.
    @Test func aWindowOnlyWidensBackwards() {
        let terms = Self.terms + ["iTerm", "endomidollare"]
        let r = { VocabularyRepair.apply(to: $0, terms: terms) }
        // Leftward: the extra word precedes the core. Repaired.
        #expect(r("ho aperto Calamos dentro ai term") == "ho aperto Kalamos dentro iTerm")
        #expect(r("controllare il chiodo e indomidollare") == "controllare il chiodo endomidollare")
        // Rightward: the core is first and the extra follows. Refused — this is
        // the sentence of his the corpus caught.
        let cloud = "una cartella temporanea di cloud e per me non è facile"
        #expect(r(cloud) == cloud)
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
        // "cloud" on its own is TWO edits from "claude", so the single-word path
        // never had a problem — it was only ever reachable by widening rightward.
        #expect(VocabularyRepair.distance("cloud", "claude", cap: 9) == 2)
        // And the same word spelled right is still normalised, at zero distance.
        #expect(repair("ho chiesto a CLAUDE") == "ho chiesto a Claude")
    }

    @Test func aFourLetterTermNeverGuesses() {
        // "repo" is in his list and is four characters. Every four-letter Italian
        // word is one edit from another one, so fuzzy matching is switched off
        // below five characters — otherwise "reso", "rete", "remo" all become
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

/// The engine switch: which of the two is actually asked to listen.
///
/// Worth a test because the failure is silent in both directions — an app that
/// keeps using the old engine after you changed the setting looks exactly like an
/// app that changed it, until you notice the speed.
@Suite struct SpeechEngineSwitchTests {

    /// A transcriber that only says who it is.
    private final class Named: Transcriber, @unchecked Sendable {
        let name: String
        init(_ name: String) { self.name = name }
        func prepare() async throws {}
        func transcribe(_ samples: [Float], allowedLanguages: Set<Language>,
                        forced: Language?) async throws -> TranscriptionResult {
            TranscriptionResult(text: name, detectedLanguage: nil)
        }
    }

    private func make(_ engine: SpeechEngine) -> SpeechEngineSwitch {
        SpeechEngineSwitch(engine: engine, whisper: Named("whisper"), parakeet: Named("parakeet"))
    }

    @Test func itAsksTheEngineYouChose() async throws {
        let s = make(.whisper)
        var out = try await s.transcribe([], allowedLanguages: [.italian], forced: nil)
        #expect(out.text == "whisper")

        s.use(.parakeet)
        out = try await s.transcribe([], allowedLanguages: [.italian], forced: nil)
        #expect(out.text == "parakeet")
        #expect(s.engine == .parakeet)

        s.use(.whisper)
        out = try await s.transcribe([], allowedLanguages: [.italian], forced: nil)
        #expect(out.text == "whisper")
    }

    @Test func aStartOnParakeetStartsOnParakeet() async throws {
        let out = try await make(.parakeet)
            .transcribe([], allowedLanguages: [.italian], forced: nil)
        #expect(out.text == "parakeet")
    }

    @Test func theSettingSurvivesARoundTripThroughItsRawValue() {
        // It is persisted as a string, so a typo in either direction would leave
        // the app silently back on the default.
        for engine in SpeechEngine.allCases {
            #expect(SpeechEngine(rawValue: engine.rawValue) == engine)
        }
        #expect(SpeechEngine(rawValue: "qualcosa-che-non-esiste") == nil)
    }
}
