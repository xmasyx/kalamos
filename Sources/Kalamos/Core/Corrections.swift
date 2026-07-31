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

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

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
