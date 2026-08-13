import Foundation
import Testing
@testable import Kalamos

/// The arithmetic behind ISC-174.
///
/// These are the cheap half of the claim: they prove the hole is found and cut
/// correctly. The expensive half — that the recovered audio actually says the
/// missing words — is `--selftest-engine` on the real recording, because no
/// synthetic fixture reproduces a skipped encoder window.
@Suite struct CoverageGapTests {
    private typealias Span = CoverageGap.Span

    // MARK: finding the hole

    @Test func aFullyCoveredRecordingHasNoHole() {
        let covered = [Span(start: 0, end: 30), Span(start: 30, end: 67)]
        #expect(CoverageGap.gaps(covered: covered, duration: 67).isEmpty)
    }

    @Test func theSkippedWindowIsFound() {
        // The shape measured on 20260812-225206.wav: window 1 good, window 2
        // skipped, window 3 good.
        let covered = [Span(start: 0, end: 25), Span(start: 57, end: 67)]
        let holes = CoverageGap.gaps(covered: covered, duration: 67)
        #expect(holes == [Span(start: 25, end: 57)])
    }

    @Test func aDecodeThatSimplyStoppedLeavesATrailingHole() {
        // The `0-40s` and `0-55s` cuts: the decode ends at 25 s and the rest of
        // the recording is never read. A gap finder that only looks between
        // segments misses exactly this, which is the commonest shape.
        let holes = CoverageGap.gaps(covered: [Span(start: 0, end: 25)], duration: 55)
        #expect(holes == [Span(start: 25, end: 55)])
    }

    @Test func aBreathIsNotAHole() {
        // Two seconds of thinking between sentences must not summon a decode.
        let covered = [Span(start: 0, end: 20), Span(start: 22, end: 40)]
        #expect(CoverageGap.gaps(covered: covered, duration: 40).isEmpty)
    }

    @Test func overlappingAndUnorderedSegmentsStillCover() {
        // Word timestamps can hand back segments that overlap or arrive out of
        // order; neither is a hole.
        let covered = [Span(start: 20, end: 40), Span(start: 0, end: 25)]
        #expect(CoverageGap.gaps(covered: covered, duration: 40).isEmpty)
    }

    @Test func nothingDecodedIsOneHoleOverEverything() {
        #expect(CoverageGap.gaps(covered: [], duration: 12) == [Span(start: 0, end: 12)])
    }

    @Test func anEmptyRecordingHasNoHole() {
        #expect(CoverageGap.gaps(covered: [], duration: 0).isEmpty)
    }

    // MARK: the collapsed window

    @Test func theCollapsedWindowIsThin() {
        // The measured map of 20260812-225206.wav: thirty seconds that produced
        // sixty-two characters.
        #expect(CoverageGap.isThin(duration: 30, characters: 62))
    }

    @Test func ordinarySpeechIsNotThin() {
        // The three healthy stretches of the same recording.
        #expect(!CoverageGap.isThin(duration: 25.7, characters: 264))
        #expect(!CoverageGap.isThin(duration: 6.1, characters: 143))
        #expect(!CoverageGap.isThin(duration: 5.3, characters: 63))
    }

    @Test func aShortSegmentIsNeverThin() {
        // "Sì." is two seconds and three characters and is exactly right. Below
        // the minimum duration the density says nothing.
        #expect(!CoverageGap.isThin(duration: 2, characters: 3))
    }

    @Test func aStretchThatSaidNothingIsThin() {
        #expect(CoverageGap.isThin(duration: 30, characters: 0))
    }

    // MARK: cutting it up

    @Test func aHoleShorterThanAWindowIsDecodedWhole() {
        let pieces = CoverageGap.chunks(of: Span(start: 25, end: 45))
        #expect(pieces == [Span(start: 25, end: 45)])
    }

    @Test func everyPieceFitsInsideOneEncoderWindow() {
        // This is the property that matters: 30 s is the model's own ceiling, so
        // a piece at or under it is decoded in a single pass and the seek loop —
        // the thing that lost the words — never runs.
        let pieces = CoverageGap.chunks(of: Span(start: 0, end: 300))
        #expect(!pieces.isEmpty)
        for piece in pieces { #expect(piece.duration <= 30) }
    }

    @Test func thePiecesCoverTheWholeHole() {
        let hole = Span(start: 10, end: 130)
        let pieces = CoverageGap.chunks(of: hole)
        #expect(pieces.first?.start == hole.start)
        #expect(pieces.last?.end == hole.end)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            #expect(b.start <= a.end)   // no unread sliver between two pieces
        }
    }

    @Test func anAbsurdOverlapCannotStall() {
        // A step of zero would spin forever on a long hole. The guard is inside
        // `chunks`, and this is the test that would hang without it.
        let pieces = CoverageGap.chunks(of: Span(start: 0, end: 200), maximum: 28, overlap: 999)
        #expect(pieces.count < 4000)
        #expect(pieces.last?.end == 200)
    }

    // MARK: padding and indexing

    @Test func paddingStaysInsideTheRecording() {
        let padded = CoverageGap.padded(Span(start: 0, end: 10), by: 0.3, within: 10)
        #expect(padded == Span(start: 0, end: 10))
    }

    @Test func paddingWidensAnInteriorHole() {
        let padded = CoverageGap.padded(Span(start: 25, end: 57), by: 0.3, within: 67)
        #expect(padded.start < 25)
        #expect(padded.end > 57)
    }

    @Test func rangesAreClampedToTheBuffer() {
        let r = CoverageGap.range(of: Span(start: 0, end: 99), sampleRate: 16_000, count: 16_000)
        #expect(r == 0 ..< 16_000)
    }

    @Test func anEmptyRangeIsNil() {
        #expect(CoverageGap.range(of: Span(start: 5, end: 5), sampleRate: 16_000, count: 16_000) == nil)
    }
}

#if canImport(WhisperKit)
/// The raw segment text is not the finished text.
@Suite struct SpecialTokenStrippingTests {
    @Test func controlTokensGo() {
        let raw = "<|startoftranscript|><|it|><|transcribe|><|0.00|> Io direi che<|25.68|>"
        #expect(WhisperKitTranscriber.withoutSpecialTokens(raw) == "Io direi che")
    }

    @Test func ordinaryTextIsUntouched() {
        #expect(WhisperKitTranscriber.withoutSpecialTokens("Ciao, come stai?") == "Ciao, come stai?")
    }

    @Test func strippingChangesTheLengthTheDensityIsMeasuredOn() {
        // The point of doing this before measuring: forty characters of control
        // tokens on a thirty-second stretch is the difference between "collapsed"
        // and "fine".
        // A long segment carries a timestamp token per phrase, so the control
        // characters alone can outweigh the words several times over.
        let raw = "<|startoftranscript|><|it|><|transcribe|>"
            + (0 ..< 12).map { "<|\($0).00|> ehm<|\($0).50|>" }.joined()
        let clean = WhisperKitTranscriber.withoutSpecialTokens(raw)
        // Both poles: measured on the words the stretch is collapsed, measured
        // on the raw string it looks like ordinary speech.
        #expect(CoverageGap.isThin(duration: 30, characters: clean.count))
        #expect(!CoverageGap.isThin(duration: 30, characters: raw.count))
    }
}
#endif

/// The padding must never turn a one-window repair into a two-piece splice.
@Suite struct PaddingCeilingTests {
    @Test func aFullWindowGetsNoPadding() {
        // The 12 August failure: exactly thirty seconds skipped. Padded, it
        // would need two decodes and a seam; capped, it stays one.
        let clip = CoverageGap.padded(CoverageGap.Span(start: 25.7, end: 55.7),
                                      by: 0.3, within: 67.1, notLongerThan: 30)
        #expect(clip == CoverageGap.Span(start: 25.7, end: 55.7))
        #expect(CoverageGap.chunks(of: clip, maximum: 30).count == 1)
    }

    @Test func aShortHoleStillGetsItsPadding() {
        let clip = CoverageGap.padded(CoverageGap.Span(start: 10, end: 20),
                                      by: 0.3, within: 67, notLongerThan: 30)
        #expect(clip == CoverageGap.Span(start: 9.7, end: 20.3))
    }

    @Test func aHoleLongerThanAWindowIsNotPaddedEither() {
        let clip = CoverageGap.padded(CoverageGap.Span(start: 0, end: 90),
                                      by: 0.3, within: 90, notLongerThan: 30)
        #expect(clip == CoverageGap.Span(start: 0, end: 90))
    }
}
