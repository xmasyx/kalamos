import Testing
@testable import Kalamos

/// ISC-111 — the "Amen", and the language decision behind it.
///
/// Every Italian and English sentence below is a REAL dictation out of
/// kalamos.log, not something written for the test. The two marked `lang=en` at
/// 01:21 and 01:22 on 2026-08-01 are the failure itself; the English ones from
/// the same log are the poles that matter just as much, because a hint that
/// re-decodes real English as Italian would be worse than the bug.
struct LanguageHintTests {

    // MARK: the failure

    /// 01:21:38 — marked `lang=en`, entirely Italian, "Amen." stuck on the end.
    @Test func theAmenSentenceIsItalian() {
        let real = """
        Un altro problema è che nelle impostazioni di Kalamos, nelle parole tue, \
        dopo l'ultima che ha aggiunto, non mi fa vedere le altre, quindi non ha un \
        menu che discende per queste. E questa parte va risolta anche. Amen.
        """
        #expect(LanguageHint.guess(real) == .italian)
        #expect(LanguageHint.contradicts(.english, text: real) == .italian)
    }

    /// 01:22:20 — the same failure, one minute later.
    @Test func theSecondMislabelledSentenceIsAlsoItalian() {
        let real = """
        inoltre serve anche fare il comando comand z all'interno delle eliminazioni \
        delle correzioni e delle parole nostre che vengono eliminate per sbaglio \
        serve poter mettere appunto il torna indietro
        """
        #expect(LanguageHint.contradicts(.english, text: real) == .italian)
    }

    // MARK: the poles — real English must stay English

    /// 17:14:07, genuinely English. Re-decoding this as Italian would be a much
    /// worse failure than the one being fixed.
    @Test func realEnglishIsLeftAlone() {
        let real = """
        Maybe it went through but I'm not sure because to me it gave error in that \
        page like a red message on top so I will be able to tell you later
        """
        #expect(LanguageHint.guess(real) == .english)
        #expect(LanguageHint.contradicts(.english, text: real) == nil)
    }

    /// 15:23:18, correctly marked `lang=it`. A correct label is never contradicted.
    @Test func acorrectItalianLabelIsNotContradicted() {
        let real = """
        Ok ho capito perché. Essendo che ne esistono due, aprendone due scrive due \
        volte, quindi questa cosa non deve essere possibile. Deve esistere solamente uno.
        """
        #expect(LanguageHint.contradicts(.italian, text: real) == nil)
    }

    // MARK: silence when unsure — the expensive direction

    /// 17:15:36, real, and four words long. Short text carries no evidence, and
    /// a guess made on none is just a coin toss with consequences.
    @Test func aShortSentenceIsNeverGuessed() {
        #expect(LanguageHint.guess("Ah yeah, this logo thing.") == nil)
    }

    @Test func twoWordsAreNeverGuessed() {
        #expect(LanguageHint.guess("va bene") == nil)
        #expect(LanguageHint.guess("") == nil)
    }

    /// Italian speech quoting English product names is still Italian, and must
    /// not be re-decoded just because English words appear in it.
    @Test func aMixedSentenceDoesNotFlipOnAFewForeignWords() {
        let mixed = """
        Ho aperto Claude Desktop e poi the settings, ma questo non funziona perché \
        nelle preferenze non c'è quella voce
        """
        #expect(LanguageHint.guess(mixed) == .italian)
    }

    /// And a genuinely ambiguous mix answers nothing rather than picking a side.
    @Test func anEvenMixAnswersNothing() {
        #expect(LanguageHint.guess("the che the che the che") == nil)
    }

    /// French is a language here too, and its markers must not read as Italian.
    @Test func frenchReadsAsFrench() {
        let fr = """
        Je ne sais pas si cette version fonctionne pour vous, mais nous devons \
        faire tout cela avec beaucoup plus de soin
        """
        #expect(LanguageHint.guess(fr) == .french)
    }

    /// Nothing is contradicted when Whisper reported nothing.
    @Test func noDetectedLanguageMeansNothingToContradict() {
        #expect(LanguageHint.contradicts(nil, text: "che cosa sono queste parole nelle preferenze") == nil)
    }
}
