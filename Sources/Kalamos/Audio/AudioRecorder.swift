import AVFoundation

/// Captures microphone audio with AVAudioEngine and resamples it to the
/// 16 kHz mono Float32 format WhisperKit expects. Accumulates samples for
/// the duration of a gesture; `stop()` returns the full clip.
final class AudioRecorder {
    /// Not a `let`. ISC-109: the graph has to be throwable away and rebuilt.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    private var watchdog = MicWatchdog()
    /// Set when the last recording ran into the ceiling instead of ending.
    private(set) var hitCeiling = false

    /// WhisperKit input format.
    static let targetSampleRate: Double = 16_000

    /// Nothing anyone dictates lasts ten minutes.
    ///
    /// On 2026-08-01 a phone call took the microphone and Kalamos stayed in
    /// hands-free mode recording **forty minutes of zeros**, then did it three
    /// more times. Nothing stopped it because nothing was watching the clock:
    /// the gesture says when to start and when to stop, and if the gesture never
    /// comes back the recording never ends. A ceiling turns an unbounded failure
    /// into a bounded one.
    static let maxSeconds: Double = 600

    enum RecorderError: Error { case formatUnavailable, converterUnavailable }

    /// Start capturing. Throws if the audio graph can't be configured.
    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        hitCeiling = false

        // A graph that has had its input stolen never re-attaches on its own: it
        // keeps running and keeps delivering zeros, which is indistinguishable
        // from a very quiet room until you look at the samples. The only thing
        // that brought it back by hand was toggling the permission, i.e. a new
        // graph — so after two dead recordings we build one.
        if watchdog.needsRebuild {
            Log.write("mic: rebuilding the audio graph after \(MicWatchdog.deadLimit) dead recordings")
            engine.stop()
            engine = AVAudioEngine()
            watchdog.rebuilt()
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw RecorderError.formatUnavailable }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw RecorderError.formatUnavailable }

        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: conv, target: target)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop capturing and return the recorded 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        watchdog.record(dead: Self.isDead(out))
        return out
    }

    /// Digital silence — not "quiet", zero.
    ///
    /// The distinction is the whole point. `isSilent` in the transcriber asks
    /// whether there is speech worth decoding, and a quiet room answers yes to
    /// that a dozen times a day. This asks whether the microphone delivered
    /// anything AT ALL, which is what a stolen input device looks like: a room
    /// has noise floor, a dead tap has exactly nothing.
    static func isDead(_ s: [Float], peakFloor: Float = 1e-6) -> Bool {
        guard !s.isEmpty else { return false }   // nothing recorded is not a dead mic
        var peak: Float = 0
        for v in s {
            let a = abs(v)
            if a > peak { peak = a }
            if peak >= peakFloor { return false }
        }
        return true
    }

    func cancel() { _ = stop() }

    /// Snapshot of the audio captured so far, WITHOUT stopping — for live
    /// (streaming) partial transcription.
    func currentSamples() -> [Float] {
        lock.lock(); let out = samples; lock.unlock()
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer, using conv: AVAudioConverter, target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return }
        let frames = Int(out.frameLength)
        lock.lock()
        let ceiling = Int(Self.maxSeconds * Self.targetSampleRate)
        if samples.count < ceiling {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: frames))
            if samples.count >= ceiling { hitCeiling = true }
        }
        lock.unlock()
    }
}

/// Counts dead recordings and says when the capture graph must be rebuilt.
///
/// Split out of `AudioRecorder` because it is the only part of ISC-109 that can
/// be tested: an `AVAudioEngine` cannot be made to lose its input on demand, but
/// the rule "two dead ones in a row, then rebuild" is four lines of arithmetic
/// and is exactly what was missing. The app already KNEW the recording was
/// silent — it wrote it in the log, four times — and did nothing with it.
struct MicWatchdog {
    /// One dead recording is a fumbled gesture; two in a row is the microphone.
    static let deadLimit = 2

    private(set) var consecutiveDead = 0
    var needsRebuild: Bool { consecutiveDead >= Self.deadLimit }

    mutating func record(dead: Bool) {
        consecutiveDead = dead ? consecutiveDead + 1 : 0
    }

    /// Called once the graph has actually been replaced.
    mutating func rebuilt() { consecutiveDead = 0 }
}
