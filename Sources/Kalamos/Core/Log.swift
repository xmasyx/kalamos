import Foundation

/// Minimal append-to-file logger so we can see what the GUI app does at runtime
/// (print() isn't captured for a launched .app). Writes to
/// ~/Library/Application Support/Kalamos/kalamos.log
enum Log {
    /// Where the lines go: the app's own file, unless a probe asked for its own.
    ///
    /// The redirect exists because of a measurement that could not be made. The
    /// scissors bench of 2026-08-17 ran with logging OFF on purpose — `Log.write`
    /// appends to the field log, and another team was counting `trimSilence` cuts
    /// in that same file the same night — so when the bench found an English
    /// sentence damaged, the one line that says which piece produced which words
    /// had never been written. The report guessed at the cause instead, and the
    /// guess was wrong.
    ///
    /// A bench that must not pollute the field log now has somewhere else to
    /// write instead of a reason to stay blind:
    /// `Kalamos … -debugLogging YES -debugLogPath /path/to/banco.log`.
    /// A value passed on the command line lands in `NSArgumentDomain` and dies
    /// with the process, so nothing is left behind in the app's own defaults.
    static var url: URL {
        if let path = UserDefaults.standard.string(forKey: "debugLogPath"),
           !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: path)
        }
        return ModelStorage.base.appendingPathComponent("kalamos.log")
    }

    /// Off by default (privacy: transcripts/translations would otherwise hit
    /// disk). Enable for debugging: `defaults write com.kalamos.app debugLogging -bool true`.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugLogging") }

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(Self.stamp())  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
