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
