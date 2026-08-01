import Foundation

/// The class `UndoManager` needs to hang an undo on, plus the one signal that
/// tells the list to redraw after one runs.
///
/// ISC-113. `registerUndo(withTarget:handler:)` wants an object, and the screen
/// that owns these lists is a SwiftUI struct. The lists themselves live in
/// UserDefaults rather than in the view, so there is nothing else to point at.
@MainActor
final class UndoBridge {
    static let shared = UndoBridge()
    static let changed = Notification.Name("KalamosWordListsChanged")

    /// Put both lists back to a snapshot, and register how to return to where we
    /// are right now.
    ///
    /// Recursive on purpose: the registration made inside an undo IS the redo,
    /// and the registration that redo makes is the undo again. That is what lets
    /// ⌘Z and ⇧⌘Z walk a whole run of deletions in both directions instead of
    /// working exactly once.
    ///
    /// Both lists move together even when only one changed. It costs nothing —
    /// the other snapshot is identical — and it means a single ⌘Z is right after
    /// any mix of deletions.
    static func restore(terms: [String], rules: [CorrectionRule], with undoManager: UndoManager) {
        let currentTerms = Vocabulary.terms
        let currentRules = Corrections.rules
        Vocabulary.setAll(terms)
        Corrections.setAll(rules)
        NotificationCenter.default.post(name: changed, object: nil)
        undoManager.registerUndo(withTarget: shared) { _ in
            MainActor.assumeIsolated {
                restore(terms: currentTerms, rules: currentRules, with: undoManager)
            }
        }
    }
}
