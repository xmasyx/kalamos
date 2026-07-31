import AppKit

/// One captured transcription, kept so nothing is ever lost — even if the
/// paste-injection misfired or the wrong field was focused.
struct TranscriptEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let languageCode: String
    /// Set when the fidelity guard threw the model's version away and this is
    /// the rule-based text instead. Optional so entries written before this
    /// existed still decode.
    let cleanupRejected: String?

    init(text: String, language: Language, date: Date = Date(), cleanupRejected: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.languageCode = language.rawValue
        self.cleanupRejected = cleanupRejected
    }

    /// Short, single-line label for the menu (truncated).
    var menuLabel: String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let clipped = oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
        let time = Self.timeFormatter.string(from: date)
        // The marker is the whole point of recording the rejection: it is how you
        // find out, afterwards, that a dictation came out of the fallback.
        let mark = cleanupRejected == nil ? "" : "⚠︎ "
        return "\(mark)\(time)  \(clipped)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

/// Rolling buffer of recent transcriptions. Every transcription is recorded
/// here *before* injection is attempted, so it's always recoverable. Persisted
/// across launches; surfaced in the menu bar for one-click copy-to-clipboard.
@MainActor
final class TranscriptHistory: ObservableObject {
    static let shared = TranscriptHistory()

    @Published private(set) var entries: [TranscriptEntry] = []
    let maxEntries = 25

    private let defaultsKey = "transcriptHistory"
    private let defaults = UserDefaults.standard

    private init() { load() }

    /// Record a transcription. Most-recent first.
    func add(_ text: String, language: Language, cleanupRejected: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(TranscriptEntry(text: trimmed, language: language,
                                       cleanupRejected: cleanupRejected), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        persist()
    }

    /// Most recent transcription, if any.
    var last: TranscriptEntry? { entries.first }

    /// Put an entry's text on the clipboard, ready for the user to ⌘V.
    func copyToClipboard(_ entry: TranscriptEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
    }

    func clear() { entries.removeAll(); persist() }

    // MARK: Persistence
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
