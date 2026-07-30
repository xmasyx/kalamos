import AVFoundation

/// Captures microphone audio with AVAudioEngine and resamples it to the
/// 16 kHz mono Float32 format WhisperKit expects. Accumulates samples for
/// the duration of a gesture; `stop()` returns the full clip.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// WhisperKit input format.
    static let targetSampleRate: Double = 16_000

    enum RecorderError: Error { case formatUnavailable, converterUnavailable }

    /// Start capturing. Throws if the audio graph can't be configured.
    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

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
        return out
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
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: frames))
        lock.unlock()
    }
}
