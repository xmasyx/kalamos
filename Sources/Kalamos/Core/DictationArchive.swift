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
