import Testing
@testable import Kalamos

/// ISC-120 — an empty selection is a string, not a nil.
///
/// ⌃⌥K shipped on 2026-08-01 with no prefill, and the cause is one operator.
/// `AppDelegate.selectedTextViaAX()` returns what the focused element answers for
/// `kAXSelectedText`, and an element that supports the attribute with nothing
/// selected answers `""` — not nil. So `ax ?? clipboard` takes the empty string as
/// a real answer and never asks the clipboard.
///
/// ⌃⌥L had the same two strategies and worked, because it happened to be written
/// as `if let s = …, !s.isEmpty`. The two spellings look equivalent when you read
/// them; only one of them is right. There is one reader now, and these are the
/// cases that keep it honest.
@MainActor
struct SelectedWordTests {
    // MARK: the bug

    @Test func anEmptyAxAnswerFallsThroughToTheClipboard() {
        let picked = AppDelegate.pick(ax: "", clipboard: "calamos")
        #expect(picked?.text == "calamos")
        #expect(picked?.source == "clipboard")
    }

    /// Whitespace-only is empty too: a selection of one space must not win.
    @Test func aWhitespaceAxAnswerFallsThroughToTheClipboard() {
        #expect(AppDelegate.pick(ax: "   \n ", clipboard: "calamos")?.text == "calamos")
    }

    // MARK: the ordinary paths

    @Test func aRealSelectionWinsOverTheClipboard() {
        let picked = AppDelegate.pick(ax: "calamos", clipboard: "something else")
        #expect(picked?.text == "calamos")
        #expect(picked?.source == "AX")
    }

    @Test func aMissingAxFallsThroughToTheClipboard() {
        #expect(AppDelegate.pick(ax: nil, clipboard: "calamos")?.source == "clipboard")
    }

    @Test func theSelectionIsTrimmed() {
        #expect(AppDelegate.pick(ax: "  calamos \n", clipboard: nil)?.text == "calamos")
    }

    @Test func nothingAnywhereIsNothing() {
        #expect(AppDelegate.pick(ax: nil, clipboard: nil) == nil)
        #expect(AppDelegate.pick(ax: "", clipboard: "") == nil)
        #expect(AppDelegate.pick(ax: "  ", clipboard: "\n") == nil)
    }

    // MARK: what may be prefilled

    /// A paragraph on the clipboard is not a misheard word. It must not be read
    /// as one, and it must not land in the left-hand field either.
    @Test func onlyWordShapedTextIsOfferedAsAPrefill() {
        #expect(AppDelegate.isWordShaped("calamos"))
        #expect(AppDelegate.isWordShaped("miss sixty"))          // multi-word is fine
        #expect(!AppDelegate.isWordShaped(""))
        #expect(!AppDelegate.isWordShaped("due righe\ndi testo"))
        #expect(!AppDelegate.isWordShaped(String(repeating: "a", count: 61)))
        #expect(AppDelegate.isWordShaped(String(repeating: "a", count: 60)))
    }
}

/// ISC-113 — undo restores the LIST, not just the row.
///
/// The bin next to every word deleted immediately and for ever. the user asked
/// for ⌘Z on 2026-08-01: *"serve poter mettere appunto il torna indietro."*
///
/// The reason it is a snapshot and not a re-add is here: `Vocabulary.add`
/// appends, so putting back a word deleted from the middle would return it to
/// the bottom — the same words in a different order, which is not what was there.
@MainActor
struct ListUndoTests {
    private func withCleanLists(_ body: ([String], [CorrectionRule]) -> Void) {
        let savedTerms = Vocabulary.terms
        let savedRules = Corrections.rules
        defer { Vocabulary.setAll(savedTerms); Corrections.setAll(savedRules) }
        body(savedTerms, savedRules)
    }

    @Test func undoingADeletionFromTheMiddleKeepsTheOrder() {
        withCleanLists { _, _ in
            Vocabulary.setAll(["alfa", "beta", "gamma"])
            let before = Vocabulary.terms
            Vocabulary.remove("beta")
            #expect(Vocabulary.terms == ["alfa", "gamma"])

            Vocabulary.setAll(before)
            // Not just "beta is back" — back in the middle, where it was.
            #expect(Vocabulary.terms == ["alfa", "beta", "gamma"])
        }
    }

    /// Re-adding instead of restoring is the bug this guards against.
    @Test func reAddingWouldPutTheWordInTheWrongPlace() {
        withCleanLists { _, _ in
            Vocabulary.setAll(["alfa", "beta", "gamma"])
            Vocabulary.remove("beta")
            Vocabulary.add("beta")
            #expect(Vocabulary.terms == ["alfa", "gamma", "beta"])   // the wrong list
        }
    }

    @Test func correctionsComeBackWholeToo() {
        withCleanLists { _, _ in
            Corrections.setAll([CorrectionRule(wrong: "calamos", correct: "Kalamos"),
                                CorrectionRule(wrong: "otsium", correct: "Otium")])
            let before = Corrections.rules
            Corrections.remove(wrong: "calamos")
            #expect(Corrections.rules.count == 1)

            Corrections.setAll(before)
            #expect(Corrections.rules.count == 2)
            #expect(Corrections.rules.contains(CorrectionRule(wrong: "calamos", correct: "Kalamos")))
        }
    }

    /// A snapshot of an empty list must empty the list, not leave it alone —
    /// undoing the very first addition depends on it.
    @Test func anEmptySnapshotEmptiesTheList() {
        withCleanLists { _, _ in
            Vocabulary.setAll(["alfa"])
            Vocabulary.setAll([])
            #expect(Vocabulary.terms.isEmpty)
        }
    }
}
