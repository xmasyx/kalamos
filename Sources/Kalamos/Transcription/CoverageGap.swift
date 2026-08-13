import Foundation

/// Stretches of a recording that a decode never accounted for.
///
/// Whisper's encoder is not a streaming model: it takes exactly 30 seconds of
/// audio, because the weights themselves are that shape (`max_source_positions:
/// 1500`, 1500 positions of 20 ms, and the Core ML encoder input is literally a
/// 480 000-float vector). Longer audio is therefore decoded as a sequence of
/// windows, and WhisperKit walks them with a seek loop: decode 30 seconds, ask
/// where the last segment ended, seek there, repeat.
///
/// The failure this type exists for is what happens when one of those windows
/// comes back with **no segments at all**. The loop advances by the whole window
/// and that audio is never looked at again, by anybody. No error, no log line,
/// and a transcription that reads perfectly because the head and the tail have
/// been glued into one plausible sentence.
///
/// Measured on 2026-08-12, `20260812-225206.wav`, 67.1 s, five passes out of
/// five identical: window 1 good, window 2 skipped, window 3 good. The same clip
/// cut to `0-40s` and to `0-55s` both stop at the same 25th second, which is
/// what proves the length is not the trigger; the same clip cut to `20-47s`
/// decodes the lost middle perfectly, which is what proves the audio is fine.
///
/// The repair therefore does not need to know WHY a window came back empty. It
/// needs to notice that a stretch of audio produced no words and go back for it.
enum CoverageGap {
    /// A half-open stretch of a recording, in seconds from its start.
    struct Span: Equatable {
        var start: Float
        var end: Float
        var duration: Float { max(0, end - start) }
    }

    /// Stretches of `duration` that no segment claims, longer than `minimum`.
    ///
    /// `minimum` is not a tuning knob to shave down: below a few seconds the
    /// timestamps' own jitter starts producing phantom holes, and a real pause
    /// for breath is indistinguishable from a skipped window at that scale. The
    /// safety net for a genuine silence is not this threshold, it is that a
    /// silent stretch re-decodes to nothing and contributes nothing.
    ///
    /// A trailing hole counts. That is the shape of the `0-40s` failure, where
    /// the decode simply stopped and the rest of the recording was never read.
    static func gaps(covered: [Span], duration: Float, minimum: Float = 3) -> [Span] {
        guard duration > 0 else { return [] }
        let sorted = covered.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var holes: [Span] = []
        var cursor: Float = 0
        for span in sorted {
            if span.start - cursor >= minimum {
                holes.append(Span(start: cursor, end: span.start))
            }
            cursor = max(cursor, span.end)
        }
        if duration - cursor >= minimum {
            holes.append(Span(start: cursor, end: duration))
        }
        return holes
    }

    /// A stretch that produced far too few words for how long it lasted.
    ///
    /// This is the detector that matters, and the first version of this file got
    /// it wrong. The skipped window does **not** leave a hole in the timeline:
    /// WhisperKit hands back a segment that spans the whole 30 seconds and
    /// carries a handful of words, so a check that only looks for uncovered time
    /// sees a perfectly continuous decode and finds nothing. Measured on
    /// `20260812-225206.wav`, the map is
    /// `0.0-25.7(264) 25.7-55.7(62) 55.7-61.8(143) 61.8-67.1(63)`: thirty
    /// seconds of speech reduced to sixty-two characters, sitting between two
    /// stretches running at ten to twenty characters a second.
    ///
    /// So the signal is density, not coverage, and his reading of the
    /// symptom was the more accurate one: what comes back looks like a summary
    /// of the window rather than a transcription of it.
    ///
    /// The threshold is deliberately far below ordinary speech (Italian dictation
    /// measures around 10 to 20 characters a second) because it does not have to
    /// be precise: a stretch flagged here is only ever re-listened to, and the
    /// result is adopted only if it says materially more. A false positive costs
    /// a few seconds and changes no text.
    static func isThin(duration: Float, characters: Int,
                       minimumDuration: Float = 3,
                       charactersPerSecond: Float = 4) -> Bool {
        guard duration >= minimumDuration else { return false }
        return Float(characters) < duration * charactersPerSecond
    }

    /// Widen a hole slightly, without leaving the recording.
    ///
    /// A word straddling the edge of the hole would otherwise be decoded from
    /// its second half. The padding is deliberately small: it overlaps audio
    /// that was already transcribed, so every millisecond of it is a millisecond
    /// that can come back as a duplicated word.
    /// `notLongerThan` is what keeps the commonest repair seamless. A skipped
    /// window is exactly one window long, so padding it would push the clip past
    /// the encoder's ceiling and force it to be decoded in two pieces — and a
    /// piece that ends mid-sentence is where Whisper invents an ending. Given no
    /// room, the padding simply yields.
    static func padded(_ span: Span, by pad: Float, within duration: Float,
                       notLongerThan maximum: Float = .infinity) -> Span {
        let room = max(0, min(pad, (maximum - span.duration) / 2))
        return Span(start: max(0, span.start - room), end: min(duration, span.end + room))
    }

    /// Cut a hole into pieces that each fit inside one encoder window.
    ///
    /// This is the part that makes the repair trustworthy rather than hopeful:
    /// a piece shorter than the window is decoded in a single pass, so the seek
    /// loop never runs and the very failure being repaired cannot happen again
    /// inside the repair. The ceiling sits under 30 s to leave room for the
    /// padding.
    static func chunks(of span: Span, maximum: Float = 28, overlap: Float = 0.3) -> [Span] {
        guard span.duration > maximum, maximum > 0 else { return [span] }
        let step = max(0.1, maximum - max(0, overlap))
        var pieces: [Span] = []
        var start = span.start
        while start < span.end {
            let end = min(start + maximum, span.end)
            pieces.append(Span(start: start, end: end))
            if end >= span.end { break }
            start += step
        }
        return pieces
    }

    /// Sample indices for a span, clamped to what the buffer actually holds.
    static func range(of span: Span, sampleRate: Float, count: Int) -> Range<Int>? {
        let lower = max(0, min(count, Int(span.start * sampleRate)))
        let upper = max(0, min(count, Int(span.end * sampleRate)))
        guard upper > lower else { return nil }
        return lower ..< upper
    }
}
