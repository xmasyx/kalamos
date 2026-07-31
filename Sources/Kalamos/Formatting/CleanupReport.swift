import Foundation

/// Whether the last cleanup was the model's work or the fallback's.
///
/// The fidelity guard is the app's most important behaviour and, until now, its
/// most invisible: when the model's version failed the diff you silently got the
/// rule-based text instead — better than wrong, but you had no way to know it had
/// happened, and therefore no way to judge whether the guard is too strict.
/// (It was, once: it discarded real self-corrections for a whole afternoon.)
///
/// A one-slot mailbox rather than a callback: the formatter writes, the
/// controller reads it immediately afterwards, and nothing else cares.
@MainActor
final class CleanupReport: ObservableObject {
    static let shared = CleanupReport()

    /// Why the model's version was refused, in the language the user reads —
    /// nil when the model's version was used.
    @Published private(set) var lastRejection: String?

    func modelWasUsed() { lastRejection = nil }

    func modelWasRejected(_ reason: String) {
        lastRejection = reason
        Log.write("cleanup rejected: \(reason)")
    }

    /// Read once and clear.
    func take() -> String? {
        defer { lastRejection = nil }
        return lastRejection
    }
}
