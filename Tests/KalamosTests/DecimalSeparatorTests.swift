import Testing
@testable import Kalamos

/// `tidySpacing` put a space after every `.` and `,` without looking at what sat
/// on either side, and `capitalizeSentences` — which runs first — armed a capital
/// on the same dot. A dictated number came back split in two: "1,73 ore" →
/// "1, 73 ore", "2.5 gigabyte" → "2. 5 Gigabyte".
///
/// The guard is deliberately narrow: a separator BETWEEN TWO DIGITS is part of
/// the number, everything else keeps the old behaviour. So this suite has two
/// poles — the numbers must survive, and ordinary prose must still get its space
/// after a comma and its capital after a full stop. Without the second pole the
/// first one could be satisfied by simply disabling the rule.
@Suite struct DecimalSeparatorTests {

    private let formatter = RuleBasedFormatter()

    private func clean(_ raw: String, _ lang: Language = .italian) async -> String {
        await formatter.format(raw, context: FormattingContext(language: lang,
                                                              frontmostBundleID: nil))
    }

    // MARK: - Pole 1 · numbers stay whole

    /// The three cases from `dati/sonda-decimali.json`, verbatim.
    @Test func dictatedDecimalsSurviveIntact() async {
        #expect(await clean("sei sicuro che siano 1,73 ore di audio")
                == "Sei sicuro che siano 1,73 ore di audio.")
        #expect(await clean("il file pesa 2.5 gigabyte")
                == "Il file pesa 2.5 gigabyte.")
        #expect(await clean("Costa 1.250,40 euro.")
                == "Costa 1.250,40 euro.")
    }

    /// Both separators inside one number, and a number that ends the sentence.
    @Test func thousandsAndDecimalMarksBothHold() async {
        #expect(await clean("il fatturato è 1.234.567,89 euro")
                == "Il fatturato è 1.234.567,89 euro.")
        #expect(await clean("la media è 3,14")
                == "La media è 3,14.")
    }

    @Test func decimalsHoldInEnglishAndFrench() async {
        #expect(await clean("the file weighs 2.5 gigabytes", .english)
                == "The file weighs 2.5 gigabytes.")
        #expect(await clean("le fichier pèse 2,5 gigaoctets", .french)
                == "Le fichier pèse 2,5 gigaoctets.")
    }

    // MARK: - Pole 2 · ordinary prose is untouched

    /// If this pole ever goes green by accident the first one stops meaning
    /// anything: a formatter that never inserts a space also never splits a
    /// number.
    @Test func spaceAfterCommaInProseStillAppears() async {
        #expect(await clean("prima questo,poi quello")
                == "Prima questo, poi quello.")
        #expect(await clean("uno,due,tre")
                == "Uno, due, tre.")
    }

    @Test func capitalAndSpaceAfterFullStopStillAppear() async {
        #expect(await clean("questo è finito.adesso ricomincio")
                == "Questo è finito. Adesso ricomincio.")
        #expect(await clean("basta!ricomincio")
                == "Basta! Ricomincio.")
    }

    /// A digit on ONE side only is not a number: an enumeration ("3. Poi…") and a
    /// sentence closing on a figure both still get the space and the capital.
    @Test func aDigitOnOneSideOnlyIsNotANumber() async {
        #expect(await clean("punto 3.poi si vede") == "Punto 3. Poi si vede.")
        #expect(await clean("ne restano 4,quindi aspetto")
                == "Ne restano 4, quindi aspetto.")
        #expect(await clean("scade il 2026.anno prossimo")
                == "Scade il 2026. Anno prossimo.")
    }

    /// The other marks are not separators inside numbers and keep their space
    /// even between digits — a dictated time or ratio reads as punctuation.
    @Test func colonsAndSemicolonsBetweenDigitsAreUnaffected() async {
        #expect(await clean("il rapporto è 3;4") == "Il rapporto è 3; 4.")
    }
}
