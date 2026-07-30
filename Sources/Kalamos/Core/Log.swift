import Foundation

/// Minimal append-to-file logger so we can see what the GUI app does at runtime
/// (print() isn't captured for a launched .app). Writes to
/// ~/Library/Application Support/Kalamos/kalamos.log
enum Log {
    static let url = ModelStorage.base.appendingPathComponent("kalamos.log")

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
