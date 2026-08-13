import Foundation

/// Replacement rules: "when transcription produces X, write Y instead". Fixes
/// persistent misrecognitions (a name Whisper always spells wrong) — the same
/// idea as Wispr Flow's dictionary replacements. Applied deterministically to
/// the transcription BEFORE formatting/translation. Stored in UserDefaults as a
/// `[wrong(lowercased): correct]` map so the menu and the dictation task share
/// one source of truth.
/// One replacement rule: what Kalamos hears, and what it should write instead.
struct CorrectionRule: Hashable, Sendable {
    let wrong: String
    let correct: String
}

enum Corrections {
    private static let key = "corrections"

    private static func map() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Rules, sorted for stable display.
    ///
    /// A named type rather than the `(wrong:correct:)` tuple it used to be: a
    /// tuple is not `Hashable`, so a SwiftUI list cannot identify its rows by it.
    static var rules: [CorrectionRule] {
        map().map { CorrectionRule(wrong: $0.key, correct: $0.value) }
            .sorted { $0.wrong.localizedCaseInsensitiveCompare($1.wrong) == .orderedAscending }
    }

    /// Add/replace a rule. The heard side is lowercased (match is
    /// case-insensitive); the written side keeps its exact casing.
    static func add(wrong: String, correct: String) {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let c = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !c.isEmpty else { return }
        var m = map()
        m[w] = c
        UserDefaults.standard.set(m, forKey: key)
    }

    static func remove(wrong: String) {
        var m = map()
        m[wrong.lowercased()] = nil
        UserDefaults.standard.set(m, forKey: key)
    }

    /// Put the rules back exactly as they were (ISC-113, undo). Same reasoning
    /// as `Vocabulary.setAll` — a snapshot restores the list, not just the row.
    static func setAll(_ rules: [CorrectionRule]) {
        var m: [String: String] = [:]
        for r in rules { m[r.wrong] = r.correct }
        UserDefaults.standard.set(m, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Change an existing rule, on either side of the arrow.
    ///
    /// Asked for on 2026-08-12: a word in "Parole tue" could be edited in place
    /// and a correction could not, so fixing a typo in one meant deleting it and
    /// typing both halves again. Removing the old heard-side first matters —
    /// editing what it hears means the rule moves to a different key, and adding
    /// without removing would leave the wrong one behind, still firing.
    static func replace(_ old: CorrectionRule, with new: CorrectionRule) {
        let w = new.wrong.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let c = new.correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !c.isEmpty else { return }
        var m = map()
        m[old.wrong.lowercased()] = nil
        m[w] = c
        UserDefaults.standard.set(m, forKey: key)
    }

    /// Read a rule back from the single line the list shows it on.
    ///
    /// One field, not two, because the row already reads `sente → scrive` and a
    /// second box would make the list jump about while being edited. The arrow
    /// is accepted in the shapes a keyboard can actually produce; a line without
    /// one, or with an empty half, is not a rule and changes nothing.
    static func parse(_ line: String) -> CorrectionRule? {
        for arrow in ["→", "->", "=>", "»"] {
            guard let r = line.range(of: arrow) else { continue }
            let wrong = line[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let correct = line[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wrong.isEmpty, !correct.isEmpty else { return nil }
            return CorrectionRule(wrong: wrong.lowercased(), correct: correct)
        }
        return nil
    }

    /// The line the list shows, and the one `parse` reads back.
    static func line(for rule: CorrectionRule) -> String {
        "\(rule.wrong) → \(rule.correct)"
    }

    /// Apply every rule to `text` (whole-word, case-insensitive). Longest heard
    /// phrase first so multi-word rules win over single-word ones.
    static func apply(to text: String) -> String {
        let m = map()
        guard !m.isEmpty else { return text }
        var out = text
        for (wrong, correct) in m.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
            let template = NSRegularExpression.escapedTemplate(for: correct)
            out = out.replacingOccurrences(of: pattern, with: template,
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}
