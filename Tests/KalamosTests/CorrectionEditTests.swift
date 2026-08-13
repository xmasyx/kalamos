import Foundation
import Testing
@testable import Kalamos

/// Editing a correction in place, asked for on 2026-08-12.
@Suite struct CorrectionEditTests {
    @Test func aRuleSurvivesTheRoundTrip() {
        let rule = CorrectionRule(wrong: "calamos", correct: "Kalamos")
        #expect(Corrections.parse(Corrections.line(for: rule)) == rule)
    }

    @Test func theHeardSideIsAlwaysLowercased() {
        // The match is case-insensitive and the map is keyed lowercased; an
        // edited rule that kept its capitals would sit under a key nothing looks
        // up, and would silently stop firing.
        #expect(Corrections.parse("Calamos → Kalamos")?.wrong == "calamos")
    }

    @Test func theWrittenSideKeepsItsCase() {
        #expect(Corrections.parse("cloud code → Claude Code")?.correct == "Claude Code")
    }

    @Test func theArrowCanBeTyped() {
        // Nobody reaches for → on an Italian keyboard.
        #expect(Corrections.parse("ossium -> Otium")?.correct == "Otium")
        #expect(Corrections.parse("ossium => Otium")?.correct == "Otium")
    }

    @Test func aLineWithoutAnArrowIsNotARule() {
        #expect(Corrections.parse("ossium Otium") == nil)
    }

    @Test func anEmptyHalfIsNotARule() {
        // Deleting one side while editing must leave the rule alone, not create
        // a rule that rewrites a word to nothing.
        #expect(Corrections.parse("ossium →") == nil)
        #expect(Corrections.parse("→ Otium") == nil)
    }

    @Test func spacesAroundTheArrowDoNotMatter() {
        #expect(Corrections.parse("  ossium→Otium  ") == CorrectionRule(wrong: "ossium", correct: "Otium"))
    }

    @Test func aMultiWordRuleIsStillOneRule() {
        #expect(Corrections.parse("lim lengthening → limb-lengthening")
                == CorrectionRule(wrong: "lim lengthening", correct: "limb-lengthening"))
    }
}
