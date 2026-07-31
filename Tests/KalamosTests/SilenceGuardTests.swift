import Foundation
import Testing
@testable import Kalamos

#if canImport(WhisperKit)
/// Silence must never reach Whisper (asked 2026-07-31).
///
/// Whisper was trained on captioned video and, given nothing, produces the
/// caption boilerplate it saw most: "thank you", "grazie", "sottotitoli e
/// revisione a cura di…". Stripping those phrases afterwards is pattern-matching
/// and only covers the ones you listed. The audio itself is the honest test.
@Suite struct SilenceGuardTests {
    private static let rate: Float = 16_000

    private func tone(seconds: Float, amplitude: Float) -> [Float] {
        let n = Int(seconds * Self.rate)
        return (0 ..< n).map { i in amplitude * sin(Float(i) * 0.05) }
    }

    @Test func digitalSilenceIsSilent() {
        #expect(WhisperKitTranscriber.isSilent([Float](repeating: 0, count: 32_000)))
    }

    @Test func emptyIsSilent() {
        #expect(WhisperKitTranscriber.isSilent([]))
    }

    /// Room tone with the mic open and nobody speaking.
    @Test func roomToneIsSilent() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 3, amplitude: 0.002)))
    }

    /// The failure that would matter: swallowing something actually said. A
    /// quiet, close-mic sentence must go through.
    @Test func quietSpeechIsNotSilent() {
        #expect(!WhisperKitTranscriber.isSilent(tone(seconds: 2, amplitude: 0.02)))
    }

    @Test func normalSpeechIsNotSilent() {
        #expect(!WhisperKitTranscriber.isSilent(tone(seconds: 4, amplitude: 0.2)))
    }

    /// A double-tap that caught the key click: loud, and far too short to be a word.
    @Test func aClickIsSilent() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 0.08, amplitude: 0.4)))
    }
}
#endif
