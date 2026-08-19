import Foundation

/// Sets the corrected dictations aside, in the shape a fine-tune wants.
///
/// The archive is not that shape. It is capped, it holds the failures next to
/// the successes, and every recording in it is one prune away from gone — which
/// is exactly right for answering *what did the microphone hear last Tuesday*
/// and exactly wrong for a training set, where the whole value is that nothing
/// ever disappears. So the pairs he has settled by hand get copied out, into a
/// folder he can open, and the copy is the thing that is never pruned.
///
/// One pair is one recording plus the verbatim he typed: the audio, and what it
/// should have said. That is the only material in this app that is not a guess.
enum TrainingCorpus {

    /// Somewhere he can find it. Not Application Support: a folder he is meant
    /// to open, hand to a training script, or copy to another machine has no
    /// business inside a hidden tree.
    static var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Kalamos-corpus", isDirectory: true)
    }

    static var manifest: URL { folder.appendingPathComponent("corpus.jsonl") }
    static var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }

    /// How many new corrections it takes to set another batch aside.
    ///
    /// Every single one would copy a 400 KB file on the tail of a gesture that
    /// is supposed to feel instant; never would leave the whole corpus hostage
    /// to a prune. Twenty-five is a few days of his corrections, and the button
    /// in the panel exists for the day he does not want to wait for them.
    static let batchSize = 25

    private static let markKey = "corpusExportedCount"

    /// True when enough new pairs have accumulated. Pure, so the threshold is
    /// testable without a disk: `have` is what is on hand now, `exported` is what
    /// went out last time.
    static func shouldExport(have: Int, exported: Int, batch: Int = batchSize) -> Bool {
        have - exported >= batch
    }

    /// Copy out every dictation whose text is worth training on.
    ///
    /// **Two sources, and both are his word.** Corrected means he retyped what
    /// was wrong, confirmed means he read it and said it was right. There is no
    /// third class: from 2026-08-20 a dictation he never went back to does not
    /// enter, however long it has sat there. It used to, as `presumed`, on the
    /// reasoning that silence was weak evidence a sentence had worked — and the
    /// reasoning is wrong, because silence is also what a sentence gets when he
    /// read it, saw it was mangled, and had no time to fix it. Those two are
    /// indistinguishable from the outside, so the corpus takes neither and the
    /// recording stays in "Da guardare" until he settles it.
    ///
    /// **Idempotent by audio AND source.** A recording exported as confirmed at
    /// a glance and retyped next week appends a second, stronger line; the
    /// trainer keeps the best per audio. Keying only on the file name — which is
    /// what the first version did — would have frozen the weaker reading and
    /// thrown the correction away silently, the worst of the three outcomes.
    @discardableResult
    static func export() -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: audioFolder, withIntermediateDirectories: true)

        let copied = Set((try? fm.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent) ?? [])
        let already = writtenPairs()

        var written = 0
        var lines: [String] = []
        for entry in DictationIndex.stems() {
            guard let (text, source) = trainable(entry) else { continue }
            let name = entry.wav.lastPathComponent
            guard !already.contains(Pair(audio: name, source: source)) else { continue }

            if !copied.contains(name) {
                do { try fm.copyItem(at: entry.wav, to: audioFolder.appendingPathComponent(name)) }
                catch {
                    Log.write("corpus: \(name) non copiato — \(error.localizedDescription)")
                    continue
                }
            }

            let d = DictationIndex.details(of: entry.wav)
            lines.append(line(audio: "audio/\(name)",
                              verbatim: text,
                              heard: DictationArchive.section("GREZZO", in: entry.wav) ?? "",
                              language: d.language ?? "",
                              seconds: d.duration ?? 0,
                              started: entry.started,
                              source: source))
            written += 1
        }

        guard written > 0 else { return 0 }
        append(lines)
        UserDefaults.standard.set(exportableCount(), forKey: markKey)
        Log.write("corpus: \(written) coppie messe da parte in \(folder.path)")
        return written
    }

    /// What to train on for one recording, and where that text comes from.
    ///
    /// Nil until he has settled it by hand. The whole value of this corpus is
    /// that every target is a sentence a human approved; one guess in it, and a
    /// trainer downstream can no longer trust any line without checking the
    /// source field, which is exactly the state the field existed to avoid.
    static func trainable(_ entry: DictationEntry) -> (String, DictationArchive.TruthSource)? {
        guard let source = DictationArchive.truthSource(of: entry.wav),
              let truth = DictationArchive.section("VERITÀ", in: entry.wav),
              !truth.isEmpty
        else { return nil }
        return (truth, source)
    }

    private struct Pair: Hashable { let audio: String; let source: DictationArchive.TruthSource }

    /// What the manifest already holds, as audio-and-source pairs.
    private static func writtenPairs() -> Set<Pair> {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        var out: Set<Pair> = []
        for row in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                  let audio = obj["audio"] as? String else { continue }
            // Lines from before the field existed were all corrections: that was
            // the only way to settle a dictation when they were written.
            let source = (obj["source"] as? String)
                .flatMap(DictationArchive.TruthSource.init(rawValue:)) ?? .corrected
            out.insert(Pair(audio: (audio as NSString).lastPathComponent, source: source))
        }
        return out
    }

    /// Called on the tail of a correction. Does nothing until a batch is full.
    static func exportIfBatchFull() {
        let have = exportableCount()
        let exported = UserDefaults.standard.integer(forKey: markKey)
        guard shouldExport(have: have, exported: exported) else { return }
        export()
    }

    /// How many pairs the archive could hand over right now, of any source.
    static func exportableCount() -> Int {
        DictationIndex.stems().reduce(into: 0) { n, e in
            if trainable(e) != nil { n += 1 }
        }
    }

    /// How many are already out. Cheap: the folder is the record.
    static func exportedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" }.count ?? 0
    }

    /// One JSON object per line — the format every fine-tuning script for a
    /// speech model already reads, so nothing has to be converted later.
    ///
    /// `text` is the verbatim, because that is the target. `heard` is what the
    /// engine produced, kept alongside rather than thrown away: the pairs where
    /// the two differ are the whole reason this corpus is worth having.
    static func line(audio: String, verbatim: String, heard: String,
                     language: String, seconds: Double, started: Date,
                     source: DictationArchive.TruthSource) -> String {
        let f = ISO8601DateFormatter()
        let obj: [String: Any] = [
            "audio": audio,
            "text": verbatim,
            "heard": heard,
            "language": language,
            "duration": seconds,
            "recorded_at": f.string(from: started),
            // How much this line is worth: how he settled it, one at a time or
            // a screenful at once. Every line in the file is his word.
            "source": source.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private static func append(_ lines: [String]) {
        let block = lines.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        guard let data = block.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: manifest) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? block.write(to: manifest, atomically: true, encoding: .utf8)
        }
    }
}
