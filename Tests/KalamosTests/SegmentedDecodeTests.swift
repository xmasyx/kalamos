import Foundation
import Testing
@testable import Kalamos

/// The switch, and what it does to the audio an engine is handed.
///
/// This is the negative pole of the whole feature, and it is here rather than in
/// a bench because it is the one claim that has to be true byte for byte: with
/// the switch off, the engine receives the SAME buffer it received before this
/// file existed. A bench cannot prove that on WhisperKit — the decode is not
/// deterministic on long audio, 142 to 170 words on eight passes of the same
/// file, measured 2026-08-04 — so the claim is proved where determinism exists:
/// on what reaches the decoder, not on what comes back from it.
///
/// The suite is serialized because it moves a value in `UserDefaults`, which is
/// process-wide. It writes into the TEST process's own domain, never
/// `com.kalamos.app`, so running the suite cannot switch the feature on in his
/// installation.
@Suite(.serialized) struct SegmentedDecodeTests {
    /// Records every buffer handed to it and answers with its length, so a test
    /// can see both what was cut and what came back.
    private actor Spy {
        private(set) var calls: [(count: Int, forced: Language?)] = []
        func note(_ count: Int, _ forced: Language?) { calls.append((count, forced)) }
    }

    private func withSwitch(_ on: Bool?, _ body: () async throws -> Void) async rethrows {
        let key = "segmentLongAudio"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let on { UserDefaults.standard.set(on, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        try await body()
    }

    private func loud(seconds: Float) -> [Float] {
        var s = [Float](repeating: 0, count: Int(seconds * AudioSplit.sampleRate))
        for i in s.indices { s[i] = (i % 2 == 0) ? 0.2 : -0.2 }
        return s
    }

    private func run(_ samples: [Float], forced: Language? = .italian,
                     spy: Spy) async throws -> TranscriptionResult {
        try await SegmentedDecode.run(
            samples, allowedLanguages: [.italian, .english], forced: forced, engine: "prova"
        ) { buffer, _, lang in
            await spy.note(buffer.count, lang)
            return TranscriptionResult(text: "pezzo di \(buffer.count)", detectedLanguage: .italian)
        }
    }

    // MARK: - Off is off

    @Test func unsetMeansOffAndOffMeansUntouched() async throws {
        try await withSwitch(nil) {
            #expect(Tuning.segmentLongAudio == false)
            let spy = Spy()
            let audio = loud(seconds: 111)   // his longest archived dictation
            _ = try await run(audio, spy: spy)
            let calls = await spy.calls
            #expect(calls.count == 1)
            #expect(calls[0].count == audio.count)
        }
    }

    @Test func explicitlyOffIsAlsoUntouched() async throws {
        try await withSwitch(false) {
            let spy = Spy()
            let audio = loud(seconds: 82)
            _ = try await run(audio, spy: spy)
            let calls = await spy.calls
            #expect(calls.count == 1)
            #expect(calls[0].count == audio.count)
        }
    }

    /// The positive pole of the two above: the same 82 seconds, with the switch
    /// on, does NOT arrive in one piece. Without this the two tests above would
    /// pass just as well against a function that never cuts anything.
    @Test func onMeansTheSameAudioArrivesInPieces() async throws {
        try await withSwitch(true) {
            #expect(Tuning.segmentLongAudio == true)
            let spy = Spy()
            let audio = loud(seconds: 82)
            _ = try await run(audio, spy: spy)
            let calls = await spy.calls
            #expect(calls.count > 1)
            #expect(calls.allSatisfy { Float($0.count) / AudioSplit.sampleRate <= 29 })
        }
    }

    // MARK: - Short dictations pay nothing, switch or no switch

    @Test func aShortDictationIsWholeEvenWithTheSwitchOn() async throws {
        try await withSwitch(true) {
            let spy = Spy()
            let audio = loud(seconds: 20)   // nine dictations in ten look like this
            _ = try await run(audio, spy: spy)
            let calls = await spy.calls
            #expect(calls.count == 1)
            #expect(calls[0].count == audio.count)
        }
    }

    // MARK: - One recording, one language

    @Test func theFirstPieceSettlesTheLanguageForTheRest() async throws {
        try await withSwitch(true) {
            let spy = Spy()
            let out = try await run(loud(seconds: 82), forced: nil, spy: spy)
            let calls = await spy.calls
            #expect(calls.count > 1)
            // The first piece is asked to detect; every later one is told.
            #expect(calls[0].forced == nil)
            #expect(calls.dropFirst().allSatisfy { $0.forced == .italian })
            #expect(out.detectedLanguage == .italian)
        }
    }

    @Test func aForcedLanguageIsNeverSecondGuessed() async throws {
        try await withSwitch(true) {
            let spy = Spy()
            let out = try await run(loud(seconds: 82), forced: .english, spy: spy)
            let calls = await spy.calls
            #expect(calls.allSatisfy { $0.forced == .english })
            #expect(out.detectedLanguage == .english)
        }
    }

    // MARK: - What the cut must not create

    /// The trailing silence goes before the cut, so the last piece ends on
    /// speech and is not handed to the decoder on its own. Measured failure:
    /// `d-reale-77s`, where whisper.cpp invented something on the room tone in
    /// eight passes out of eight.
    @Test func theTrailingSilenceIsNotAPieceOfItsOwn() async throws {
        try await withSwitch(true) {
            var audio = loud(seconds: 40)
            audio += [Float](repeating: 0, count: Int(20 * AudioSplit.sampleRate))
            let spy = Spy()
            _ = try await run(audio, spy: spy)
            let calls = await spy.calls
            let totale = calls.reduce(0) { $0 + $1.count }
            // Sixty seconds went in; what reaches the decoder is the forty of
            // speech (plus the pad and the overlap), never the twenty of silence.
            #expect(Float(totale) / AudioSplit.sampleRate < 45)

            // The negative pole: without a silent tail nothing is thrown away.
            let spy2 = Spy()
            _ = try await run(loud(seconds: 60), spy: spy2)
            let totale2 = await spy2.calls.reduce(0) { $0 + $1.count }
            #expect(Float(totale2) / AudioSplit.sampleRate > 59)
        }
    }

    @Test func aPieceThatCameBackInALoopIsDropped() async throws {
        try await withSwitch(true) {
            let spy = Spy()
            let out = try await SegmentedDecode.run(
                loud(seconds: 82), allowedLanguages: [.italian], forced: .italian, engine: "prova"
            ) { buffer, _, lang in
                await spy.note(buffer.count, lang)
                let index = await spy.calls.count
                // Verbatim shape of the 2026-08-16 failure: one word, commas,
                // no full stop, so the sentence-level guard cannot see it.
                let loop = Array(repeating: "no", count: 40).joined(separator: ", ")
                return TranscriptionResult(text: index == 2 ? loop : "una frase vera numero \(index)",
                                           detectedLanguage: .italian)
            }
            #expect(!out.text.contains("no, no, no"))
            #expect(out.text.contains("numero 1"))
            #expect(out.text.contains("numero 3"))
        }
    }

    // MARK: - The text comes back joined, not listed

    @Test func anEmptyPieceContributesNothingToTheText() async throws {
        try await withSwitch(true) {
            let spy = Spy()
            let out = try await SegmentedDecode.run(
                loud(seconds: 82), allowedLanguages: [.italian], forced: .italian, engine: "prova"
            ) { buffer, _, lang in
                await spy.note(buffer.count, lang)
                // The SECOND piece comes back empty, which is what a stuck
                // pipeline looks like from here.
                let index = await spy.calls.count
                return TranscriptionResult(text: index == 2 ? "" : "una frase intera numero \(index)",
                                           detectedLanguage: .italian)
            }
            #expect(await spy.calls.count > 2)
            // No double space where the empty piece was, and no empty result.
            #expect(!out.text.contains("  "))
            #expect(out.text.hasPrefix("una frase intera numero 1 una frase intera numero 3"))
            #expect(!out.text.contains("numero 2"))
        }
    }
}
