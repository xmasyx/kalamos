import Foundation

/// Privacy-safe usage telemetry: appends only an ISO-8601 timestamp per
/// dictation (no transcript content). Used to analyze inter-use gaps and tune
/// the idle-unload timeout (see Scripts/analyze-idle.ts).
enum UsageLog {
    static let url = ModelStorage.base.appendingPathComponent("usage.log")

    static func record() {
        let line = ISO8601DateFormatter().string(from: Date()) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
