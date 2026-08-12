import Foundation

/// Turns the dictation archive into training material, which is a different job
/// from keeping it.
///
/// The archive answers *what did the microphone hear*. This answers the question
/// that comes after it: *and what should it have written*. Nothing inside the app
/// knows that. The raw transcript is what Whisper heard, and the delivered text
/// is the same mistake with the punctuation tidied: on 2026-08-12 a dictation
/// that said one hundred euros was archived as two hundred, and both halves of
/// the sidecar agreed with each other and with nothing that had been said.
///
/// So truth has exactly one source, which is the person who spoke, and the whole
/// design is about asking him as rarely as possible. Two moves:
///
///   1. `isRedo` finds the dictations that probably went wrong, for free, by
///      noticing that he said the same thing twice.
///   2. ⌃⌥V asks him for the verbatim on one of those, and only when he offers.
enum DictationTruth {

    /// How alike two transcripts are, as the fraction of distinct words they
    /// share. Case and punctuation are dropped, because a redo differs in the
    /// word that was misheard and not in the comma after it.
    static func similarity(_ a: String, _ b: String) -> Double {
        let A = words(a), B = words(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        return Double(A.intersection(B).count) / Double(A.union(B).count)
    }

    /// Above this, two consecutive dictations are the same sentence said twice.
    ///
    /// **Measured, then read by hand.** Over the 813 consecutive pairs in his
    /// log the median similarity is **0.048** and the 90th percentile **0.125**:
    /// speech moving from one subject to the next barely overlaps with itself.
    /// Five pairs reach 0.5 and all five are redos, so 0.5 was the obvious
    /// threshold and it was wrong in the direction that costs something.
    /// Reading every pair between 0.20 and 0.50 — twenty-one of them — turned up
    /// two more real redos at **0.38** and **0.29** ("Per salvare fai come
    /// andasse" said again as "Per salvare fai Command + S"), and those are the
    /// interesting ones: the worse the mistranscription, the fewer words the two
    /// attempts share, so the most damaging cases sit LOWEST on this scale.
    ///
    /// At 0.35 the marker catches six of the seven known redos with no false
    /// positive anywhere in the corpus. Lower would start paying: the nineteen
    /// remaining pairs in that band are ordinary conversation staying on one
    /// subject, and at 0.20 all nineteen would be marked.
    ///
    /// So this is deliberately incomplete, and that is the correct failure
    /// direction. A missed redo costs one unmarked dictation among thousands
    /// kept; a marker that fires on ordinary speech destroys the only thing it
    /// is for, which is pointing at three recordings a day instead of twenty.
    static let redoSimilarity = 0.35

    /// A redo happens while the wrong text is still on screen. Beyond this it is
    /// a new thought that happens to reuse words, so the similarity alone would
    /// stop being evidence of anything.
    static let redoWindow: TimeInterval = 300

    /// True when `current` looks like `previous` said again because it came out
    /// wrong. Both conditions are required: similarity alone would fire on a
    /// sentence legitimately repeated an hour later, and the clock alone would
    /// fire on every chained dictation, which is a feature of this app.
    static func isRedo(previous: String, current: String, gap: TimeInterval) -> Bool {
        guard gap >= 0, gap <= redoWindow else { return false }
        return similarity(previous, current) >= redoSimilarity
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
    }
}

/// The last dictation that reached the disk, so the parts of the app that arrive
/// afterwards can point at it.
///
/// It exists because the fact has one owner and several readers: the controller
/// knows which file it just wrote and when, while ⌃⌥L, ⌃⌥K and ⌃⌥V run from the
/// menu with none of that in hand. The alternative was for each of them to guess
/// the newest file by its timestamp, which is a component re-deriving by
/// heuristic something the caller held exactly.
final class LastDictation: @unchecked Sendable {
    static let shared = LastDictation()

    private let lock = NSLock()
    private var wav: URL?
    private var raw = ""
    private var finishedAt: Date?

    func record(wav: URL?, raw: String, finishedAt: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.wav = wav
        self.raw = raw
        self.finishedAt = finishedAt
    }

    /// What was archived last, or nil when nothing has been (archiving off, a
    /// failed write, a fresh launch).
    var snapshot: (wav: URL, raw: String, finishedAt: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let wav, let finishedAt else { return nil }
        return (wav, raw, finishedAt)
    }

    /// The same thing, but only if it is recent enough that a gesture made now is
    /// plausibly about it. Used by ⌃⌥L and ⌃⌥K, where teaching the app a word
    /// seconds after a dictation is itself the report that the dictation was
    /// wrong.
    func recent(within seconds: TimeInterval) -> (wav: URL, raw: String)? {
        guard let s = snapshot, Date().timeIntervalSince(s.finishedAt) <= seconds else { return nil }
        return (s.wav, s.raw)
    }
}
