import Foundation
import Testing
@testable import Kalamos

/// The archive and the rewritten silence guard, 2026-08-04.
///
/// Both exist because of the same morning: a dictation lost part of what was
/// said, and nothing on disk could say what the microphone had heard.
struct DictationArchiveTests {

    // MARK: - The silence guard judges the loudest moment, not the average

    /// Speech surrounded by enough quiet used to be discarded whole.
    ///
    /// This is the failure that was measured on real audio: 11 seconds of normal
    /// speech inside a long recording averages under the floor, and the old
    /// guard returned "silent" for a recording with a sentence in it. The quiet
    /// is in the MIDDLE on purpose — `trimSilence` removed it at the ends, which
    /// is what hid this for so long. (Since 2026-08-16 it only removes it at the
    /// end; the middle is still where the guard has to do the work.)
    @Test func speechBuriedInQuietIsNotSilence() {
        let sr: Float = 16_000
        // 0.02 is not an arbitrary "quiet": it is the amplitude matching the
        // 0.014 RMS measured on his own recordings on 2026-08-04, so this is
        // normal speech at a normal level, not a whisper.
        var samples = [Float]()
        samples += tone(seconds: 2, amplitude: 0.02)          // he says something
        samples += [Float](repeating: 0, count: Int(sr * 120)) // he thinks for two minutes
        samples += tone(seconds: 2, amplitude: 0.02)          // he says something else

        // The average over the whole thing is far below the floor…
        var energy: Float = 0
        for v in samples { energy += v * v }
        let averageRMS = (energy / Float(samples.count)).squareRoot()
        #expect(averageRMS < 0.004)

        // …and the recording is still not silent, because someone spoke in it.
        #expect(!WhisperKitTranscriber.isSilent(samples))
    }

    /// The positive pole: a recording with nothing in it must still be rejected.
    /// Without this, "never say silent" would pass the test above and be wrong.
    @Test func genuinelyQuietRecordingIsStillSilence() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 200, amplitude: 0.001)))
        #expect(WhisperKitTranscriber.isSilent([Float](repeating: 0, count: 16_000 * 60)))
    }

    /// A burst shorter than the window cannot be rescued by landing on a seam.
    @Test func aClickIsNotSpeech() {
        #expect(WhisperKitTranscriber.isSilent(tone(seconds: 0.08, amplitude: 0.9)))
    }

    // MARK: - The archive

    @Test func wavIsReadableAndCarriesEverySample() throws {
        let samples = tone(seconds: 1, amplitude: 0.5)
        let data = try #require(DictationArchive.wavData(samples, sampleRate: 16_000))

        #expect(data.count == 44 + samples.count * 2)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: data[36..<40], encoding: .ascii) == "data")

        // Sample rate is little-endian at byte 24, and a wrong one plays back at
        // the wrong pitch — which would look like a transcription bug.
        let rate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
    }

    /// A sample above full scale must clamp, not wrap. Wrapping puts a click in
    /// the archive that was never in the room, and the archive is evidence.
    @Test func loudSamplesClampInsteadOfWrapping() throws {
        let data = try #require(DictationArchive.wavData([2.0, -2.0], sampleRate: 16_000))
        let pcm = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(pcm == [32767, -32767])
    }

    @Test func emptyAudioProducesNoFile() {
        #expect(DictationArchive.wavData([], sampleRate: 16_000) == nil)
    }

    // MARK: -

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { amplitude * sin(Float($0) * 0.05) }
    }
}
