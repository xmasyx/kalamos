import Foundation

/// Keeps the audio and the text of the last few dictations, on this Mac only.
///
/// Written on 2026-08-04, after a morning spent unable to answer "what did the
/// microphone actually hear?" about a dictation that had lost part of what he
/// said. The log recorded the words that came out and nothing about the sound
/// that went in, so every hypothesis had to be tested against synthetic audio
/// that could not reproduce the failure. A dictation that goes wrong is worth
/// nothing as a bug report unless the audio survives it.
///
/// Local by construction: the files sit next to the log in Application Support,
/// they are capped by count, and nothing sends them anywhere. Dictation audio is
/// as private as data gets — the cap and the location are the privacy design,
/// and `keepLastDictations 0` turns the whole thing off.
enum DictationArchive {

    /// **Una registrazione è entrata nell'archivio, o è cambiata.** L'URL del
    /// `.wav` viaggia in `object`.
    ///
    /// Esiste perché il pannello delle dettature leggeva la cartella una volta
    /// sola, all'apertura, e nessuno gli diceva più niente: dettando col pannello
    /// aperto la riga nuova non compariva finché non lo si richiudeva. Non era un
    /// ritardo, era che l'informazione non partiva.
    ///
    /// **Si annuncia a file chiuso, e non è una precauzione teorica**: sia il
    /// `.wav` sia il suo `.txt` sono scritti atomicamente, e l'annuncio parte
    /// DOPO. La notte del 17/08 una corsa di prova è morta esattamente lì, con un
    /// lettore che apriva un file che chi lo scriveva non aveva ancora chiuso.
    ///
    /// Chi ascolta deve essere **idempotente**: lo stesso URL può arrivare più di
    /// una volta (una dettatura marcata dopo essere stata ridetta è già in lista,
    /// e quel secondo annuncio è giusto — significa che la riga è cambiata).
    static let didArchive = Notification.Name("kalamos.didArchive")

    /// Dillo a chi sta guardando la lista. Sempre dal main thread, perché chi
    /// ascolta è l'interfaccia.
    private static func announce(_ wav: URL) {
        Task { @MainActor in
            NotificationCenter.default.post(name: didArchive, object: wav)
        }
    }

    /// Where the kept dictations live. Beside the log, on purpose: someone
    /// looking for one will look for the other.
    static var directory: URL {
        let dir = ModelStorage.base.appendingPathComponent("dictations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Save this recording and drop the oldest ones past the cap.
    ///
    /// Returns the stem shared by the `.wav` and its `.txt` sidecar so the caller
    /// can come back and write the transcription next to the sound it came from.
    /// `nil` when archiving is off or the write failed — never throws into a
    /// dictation, because losing the archive must not cost the user their words.
    @discardableResult
    static func keep(_ samples: [Float], startedAt: Date, sampleRate: Double) -> URL? {
        let cap = Tuning.keepLastDictations
        guard cap > 0, !samples.isEmpty else { return nil }

        let stamp = Self.stamp(startedAt)
        let wav = directory.appendingPathComponent("\(stamp).wav")
        guard let data = wavData(samples, sampleRate: sampleRate) else { return nil }
        do { try data.write(to: wav) } catch {
            Log.write("archive: could not keep the audio — \(error.localizedDescription)")
            return nil
        }
        prune(keeping: cap)
        return wav
    }

    /// Write what the words turned out to be, beside the audio they came from.
    ///
    /// Separate from `keep` because it happens seconds later, after the decode:
    /// holding the audio hostage until the text exists would mean losing the
    /// audio precisely when the decode is the thing that failed.
    static func annotate(_ wav: URL?, lines: [String]) {
        guard let wav else { return }
        let sidecar = wav.deletingPathExtension().appendingPathExtension("txt")
        try? lines.joined(separator: "\n").appending("\n").write(
            to: sidecar, atomically: true, encoding: .utf8)
        // Qui, e non in `keep`: adesso la riga ha sia il suono sia le parole.
        // Annunciata alla `keep` comparirebbe muta, e andrebbe aggiornata subito
        // dopo — due eventi per una cosa sola.
        announce(wav)
    }

    /// Throw a recording away, sound and sidecar together.
    ///
    /// For the one case that is not a dictation at all: the microphone opened
    /// and nothing was said. Those were being kept, listed, and offered to him
    /// to correct, which is asking what he had said about a moment when he had
    /// said nothing.
    static func discard(_ wav: URL?) {
        guard let wav else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: wav)
        try? fm.removeItem(at: sidecar(of: wav))
        Log.write("archivio: \(wav.lastPathComponent) buttata, registrazione vuota")
    }

    /// Sweep away the recordings that never got any text beside them.
    ///
    /// **This is what he was actually seeing** (2026-08-16): rows in the panel
    /// with a time, a duration and nothing to read. Not an empty transcript — no
    /// sidecar at all, because the decode returned nothing and the code that
    /// writes the text never ran. Twelve of them on his machine.
    ///
    /// `youngerThan` protects the one in flight: a recording is written before
    /// its transcription exists, so for a few seconds every dictation looks like
    /// an orphan. Five minutes is longer than the slowest decode measured on this
    /// Mac, which was a cold model load at 2m15s.
    @discardableResult
    static func discardOrphans(olderThan age: TimeInterval = 300, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return 0 }
        var gone = 0
        for wav in all where wav.pathExtension == "wav" {
            guard !fm.fileExists(atPath: sidecar(of: wav).path) else { continue }
            let stem = wav.deletingPathExtension().lastPathComponent
            guard let started = DictationIndex.date(fromStem: stem),
                  now.timeIntervalSince(started) > age else { continue }
            try? fm.removeItem(at: wav)
            gone += 1
        }
        if gone > 0 { Log.write("archivio: buttate \(gone) registrazioni vuote senza testo") }
        return gone
    }

    /// The sidecar that belongs to a recording.
    static func sidecar(of wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("txt")
    }

    /// Add lines to a sidecar that already exists, leaving what is there alone.
    ///
    /// Append and never rewrite: everything added after the fact — a suspicion,
    /// a verbatim typed by hand — is worth more than what the machine wrote, and
    /// a rewrite is one bug away from replacing the second with the first.
    static func append(_ wav: URL, lines: [String]) {
        let file = sidecar(of: wav)
        let block = "\n" + lines.joined(separator: "\n") + "\n"
        guard let data = block.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? block.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Flag a recording as one that probably went wrong, with the reason that
    /// made it look that way. Written into the sidecar rather than a database
    /// because the sidecar is what survives being copied somewhere else.
    /// Annuncia anche questa, e i due casi che copre sono diversi ma la stessa
    /// riparazione: una dettatura vuota CON voce dentro non passa mai da
    /// `annotate`, quindi senza l'annuncio qui non comparirebbe mai a caldo; e una
    /// marcata perché ridetta è già in lista, quindi chi ascolta la aggiorna
    /// invece di inserirla, ed è così che il ⚠ compare mentre lui guarda.
    ///
    /// A file chiuso anche qui: `append` chiude la maniglia prima di tornare.
    static func mark(_ wav: URL, reason: String) {
        append(wav, lines: ["SOSPETTA: \(reason)"])
        Log.write("archive: marked \(wav.lastPathComponent) — \(reason)")
        announce(wav)
    }

    /// Write down what was actually said. The one line in the whole file that is
    /// not a guess.
    ///
    /// **How it was settled is written down with it**, because the two ways are
    /// not equally strong evidence and a corpus that cannot tell them apart
    /// cannot weigh them later. `corrected` means he retyped the words that were
    /// wrong. `confirmed` means he read it and it was already right, which is
    /// what most dictations are — and until 2026-08-15 the app had no way for him
    /// to say so, so an untouched recording looked exactly like one nobody had
    /// ever looked at.
    static func recordTruth(_ wav: URL, verbatim: String, how: TruthSource = .corrected) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        append(wav, lines: ["", "VERITÀ (\(f.string(from: Date()))\(how.note)):", verbatim])
        Log.write("archive: verbatim \(how.rawValue) for \(wav.lastPathComponent)")
    }

    /// How a verbatim came to be settled.
    enum TruthSource: String, Sendable {
        /// He fixed the words that were wrong.
        case corrected
        /// He read it and confirmed it was already right.
        case confirmed
        /// He confirmed a whole screenful at once. Weaker than one at a time and
        /// recorded as such: a sweep is a claim about a list, and whoever trains
        /// on this later is entitled to know which lines came from a glance.
        case confirmedInBulk = "confirmed_bulk"

        /// Nobody said anything, and that is the point: he used the dictation and
        /// never went back to it, while the ones he DID go back to are marked.
        /// The weakest of the four, inferred by the app rather than stated by
        /// him, and it never gets written into a sidecar — it is computed at
        /// export time, so the day he corrects one the stronger source wins.
        case presumed

        /// **Capitals, and not for emphasis.** `isHeading` recognises a block by
        /// a line of capitals ending in a colon, so a lower-case note inside the
        /// parentheses would stop the line from being a heading at all: the
        /// verbatim would be filed as the tail of the previous block and the
        /// recording would read back as never settled. Written in lower case
        /// first, caught by the test below, and it would never have shown up in
        /// the app — the file looks perfectly reasonable to a human eye.
        var note: String {
            switch self {
            case .corrected: return ""
            case .confirmed: return ", CONFERMATA"
            case .confirmedInBulk: return ", CONFERMATA IN BLOCCO"
            // Never written to a sidecar: a presumption is not something the
            // archive should record as if he had said it. It is derived at
            // export time and lives only in the corpus line.
            case .presumed: return ""
            }
        }
    }

    /// Has this recording been settled, one way or the other?
    static func isSettled(_ wav: URL) -> Bool {
        section("VERITÀ", in: wav)?.isEmpty == false
    }

    /// How it was settled, read back off the file. Nil when it never was.
    ///
    /// Read by the marker in the heading rather than by parsing the date beside
    /// it: the markers are unique upper-case strings this type writes and
    /// nothing else does, so the check cannot be fooled by a transcript that
    /// happens to contain the word.
    static func truthSource(of wav: URL) -> TruthSource? {
        guard isSettled(wav),
              let text = try? String(contentsOf: sidecar(of: wav), encoding: .utf8)
        else { return nil }
        if text.contains("CONFERMATA IN BLOCCO") { return .confirmedInBulk }
        if text.contains("CONFERMATA") { return .confirmed }
        return .corrected
    }

    /// Read back one labelled block of a sidecar — "GREZZO", "CONSEGNATO".
    ///
    /// A block runs from its own heading to the next heading or the end of the
    /// file. Headings are the lines this type writes, all-caps and colon-ended,
    /// so a transcript that happens to contain a colon cannot end its own block.
    static func section(_ name: String, in wav: URL) -> String? {
        guard let text = try? String(contentsOf: sidecar(of: wav), encoding: .utf8)
        else { return nil }
        var collecting = false
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if isHeading(line) {
                if collecting { break }
                collecting = line.hasPrefix(name)
                continue
            }
            if collecting { out.append(line) }
        }
        guard collecting else { return nil }
        let body = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// A heading is a whole line of capitals ending in a colon, optionally with a
    /// parenthesised note — "GREZZO:", "VERITÀ (2026-08-12 15:40):".
    private static func isHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(":"), let first = t.first, first.isUppercase else { return false }
        return !t.dropLast().contains { $0.isLowercase }
    }

    /// The most recent recording still on disk, by name rather than by file date
    /// for the same reason pruning sorts by name.
    static var latest: URL? {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil) else { return nil }
        return all.filter { $0.pathExtension == "wav" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Sortable and human-readable, and the same string a person would type when
    /// looking for "the one from just after one o'clock".
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Keep the newest `cap` recordings; delete the rest, sidecars with them.
    ///
    /// Sorted by NAME, not by file date: the name carries the moment the
    /// recording started, and a file date can be rewritten by a backup or a copy
    /// while the name cannot.
    private static func prune(keeping cap: Int) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil) else { return }
        let wavs = all.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
        guard wavs.count > cap else { return }
        for old in wavs.dropFirst(cap) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("txt"))
        }
    }

    /// 16-bit PCM mono. Written by hand rather than through AVFoundation because
    /// this runs on the tail of a dictation: a format negotiation that can fail
    /// or block has no business there, and the header is fourteen fields.
    static func wavData(_ samples: [Float], sampleRate: Double) -> Data? {
        guard !samples.isEmpty else { return nil }
        let rate = UInt32(sampleRate)
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample

        var out = Data(capacity: 44 + dataBytes)
        func ascii(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)                       // PCM, mono
        u32(rate); u32(rate * UInt32(bytesPerSample))                // byte rate
        u16(UInt16(bytesPerSample)); u16(16)                         // block align, bit depth
        ascii("data"); u32(UInt32(dataBytes))

        var pcm = [Int16](); pcm.reserveCapacity(samples.count)
        for v in samples {
            // Clamp before scaling: a sample above 1.0 would wrap to a loud
            // negative and put a click in the archive that was never in the room.
            let clamped = max(-1.0, min(1.0, v))
            pcm.append(Int16(clamped * 32767))
        }
        pcm.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        return out
    }
}
