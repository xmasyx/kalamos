import AVFoundation
import CoreAudio

/// Captures microphone audio with AVAudioEngine and resamples it to the
/// 16 kHz mono Float32 format WhisperKit expects. Accumulates samples for
/// the duration of a gesture; `stop()` returns the full clip.
///
/// `@unchecked Sendable` states the discipline the class already lives by
/// rather than adding one: `samples`/`_heardSpeech`/`mismatchLogged` are
/// lock-protected because the tap writes them from the audio thread, and
/// everything else (engine, converter, observer, flags) is touched from the
/// main thread only — `start()`/`stop()` by the controller, the route-change
/// handler because it hops to main before doing anything.
final class AudioRecorder: @unchecked Sendable {
    /// Nil between recordings, and that is a fix, not a style choice.
    ///
    /// The engine used to live as long as the app: built once, stopped after
    /// each dictation, never released. A stopped `AVAudioEngine` is still a
    /// CoreAudio client, configured against the device it last prepared on.
    /// Both crash reports of 2026-08-14 (SIGSEGV on the main thread, the same
    /// garbage pointer `0xc2000000` twice) fired while the app was IDLE, at the
    /// exact moment wired EarPods were plugged in or pulled out — the device
    /// change calling back into a client whose device was gone. With no engine
    /// alive between recordings there is nothing for the change to call into.
    ///
    /// The same decision fixes the quieter half of the bug: a fresh engine per
    /// `start()` binds to the CURRENT default input, so a microphone plugged in
    /// after launch records instead of delivering the old device's silence.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    /// Watches `.AVAudioEngineConfigurationChange` for the LIVE engine only —
    /// registered in `activate()`, removed in `teardown()`.
    private var configObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    private var watchdog = MicWatchdog()
    /// Set when the last recording ran into the ceiling instead of ending.
    private(set) var hitCeiling = false
    /// Whether anything above the speech floor has arrived since `start()`.
    ///
    /// Kept as a running flag rather than measured at the end, because the
    /// hands-free silence guard has to answer "was anything ever said?" WITHOUT
    /// scanning ten minutes of audio once a second.
    private var _heardSpeech = false
    var heardSpeech: Bool { lock.lock(); defer { lock.unlock() }; return _heardSpeech }
    /// One log line per recording for dropped buffers, not one per buffer —
    /// the tap fires ~16 times a second and the log is a file.
    private var mismatchLogged = false
    /// The loudest buffer since somebody last asked. See `takeLevelPeak()`.
    private var levelPeak: Float = 0

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
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _heardSpeech = false
        mismatchLogged = false
        levelPeak = 0
        lock.unlock()
        hitCeiling = false

        // The two-dead-recordings ledger predates the fresh-graph-per-start
        // rule and stays as the record of WHY a graph was suspect; the remedy
        // it used to trigger now happens on every start by construction.
        if watchdog.needsRebuild {
            Log.write("mic: fresh graph after \(MicWatchdog.deadLimit) dead recordings")
            watchdog.rebuilt()
        }

        try activate()
        isRecording = true
    }

    /// Build the whole capture graph — engine, converter, tap, route watch —
    /// against the CURRENT default input device. Called by `start()` and again
    /// mid-recording when the device changes under us; accumulated samples are
    /// deliberately untouched, so a dictation survives the swap.
    private func activate() throws {
        teardown()

        let engine = AVAudioEngine()
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

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            // A buffer in a format the converter was not built for is what a
            // device change in mid-teardown looks like from inside the tap.
            // Feeding it through anyway asks the converter to misread memory;
            // dropping it costs at most 64 ms of a transition that is already
            // being rebuilt.
            guard Self.formatMatches(buffer.format, converterInput: conv.inputFormat) else {
                self?.noteMismatchedBuffer(buffer.format, expected: conv.inputFormat)
                return
            }
            self?.append(buffer, using: conv, target: target)
        }

        // The unplug case, 2026-08-14: "avvio la dettatura, tolgo le cuffie, va
        // in crash". When the input device changes AVAudioEngine stops and posts
        // this; a client that does not rebuild is left with a dead graph (the
        // silent half of the bug) or worse. We rebuild against the new default
        // device and the dictation carries on across the swap.
        // The engine itself is not Sendable, so the closure carries its
        // identity instead — enough to tell a live engine's notification from
        // a torn-down one's.
        let engineID = ObjectIdentifier(engine)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Posted on an internal thread; policy runs on main, like the rest
            // of this class's callers.
            DispatchQueue.main.async { self?.handleRouteChange(of: engineID) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
            throw error
        }
        self.engine = engine
        self.converter = conv
    }

    /// Tear the capture graph down completely — tap, engine, observer, converter.
    /// After this the app holds no live audio client, which is the idle state
    /// a device can be plugged into or pulled from without anyone to crash.
    private func teardown() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
            engine = nil
        }
        converter = nil
    }

    /// The input device changed while we were listening. Rebuild on the new one.
    private func handleRouteChange(of changedID: ObjectIdentifier) {
        // Notifications from an engine we already tore down describe the past.
        guard isRecording, let live = engine, ObjectIdentifier(live) == changedID else { return }
        Log.write("mic: input device changed mid-recording — rebuilding on the new device")
        do {
            try activate()
            Log.write("mic: reattached, the dictation continues")
        } catch {
            // No device to reattach to (or a transient failure): keep what was
            // heard and let the gesture end the dictation normally. Samples
            // stop growing, which the hands-free silence guard also understands.
            teardown()
            Log.write("mic: could not reattach (\(error)) — the dictation will end with what was heard")
        }
    }

    /// Does a tap buffer belong to this converter? Pure, so the two-pole test
    /// can hold the door: 44.1 kHz EarPods against a 48 kHz built-in graph is
    /// exactly the 2026-08-14 transition.
    static func formatMatches(_ buffer: AVAudioFormat, converterInput: AVAudioFormat) -> Bool {
        buffer.sampleRate == converterInput.sampleRate
            && buffer.channelCount == converterInput.channelCount
    }

    private func noteMismatchedBuffer(_ got: AVAudioFormat, expected: AVAudioFormat) {
        lock.lock()
        let first = !mismatchLogged
        mismatchLogged = true
        lock.unlock()
        guard first else { return }
        Log.write("mic: dropped buffer(s) in the wrong format — got \(Int(got.sampleRate)) Hz/"
                  + "\(got.channelCount)ch, converter expects \(Int(expected.sampleRate)) Hz/"
                  + "\(expected.channelCount)ch")
    }

    /// Stop capturing and return the recorded 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        teardown()
        isRecording = false
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        watchdog.record(dead: Self.isDead(out))
        return out
    }

    /// Did the microphone actually turn up when the key was pressed?
    ///
    /// The user's own design, and better than the one it replaces. The first
    /// version waited for the END of a recording to notice the microphone was
    /// dead — which still meant recording nothing, for as long as the gesture
    /// lasted. Asking half a second in costs nothing and answers the question
    /// that matters: *is this dictation going to work at all?* If not, the app
    /// says so and goes back to idle rather than pretending to listen.
    ///
    /// It also does not need to know anything about phone calls. Whatever took
    /// the microphone — a call, another app, a permission revoked mid-session —
    /// looks the same from here.
    static let startupProbeSeconds: Double = 0.6

    /// The loudness at which a buffer counts as somebody speaking. Deliberately
    /// the SAME number the transcriber uses to decide a recording was silent —
    /// two definitions of silence in one app is how the guard and the transcriber
    /// end up disagreeing about the same audio.
    static let speechFloor: Float = 0.004

    enum MicHealth {
        case alive
        /// Buffers arriving, every sample exactly zero: the tap is attached to
        /// a device that is giving nothing.
        case silentTap
        /// No buffers at all. A working graph delivers one every ~64 ms, so
        /// after the probe window this means the tap never started.
        case noBuffers
    }

    /// The decision, as a function of what arrived. Pure, so it can be tested —
    /// an `AVAudioEngine` cannot be made to lose its input on demand.
    static func health(of samples: [Float]) -> MicHealth {
        if samples.isEmpty { return .noBuffers }
        return isDead(samples) ? .silentTap : .alive
    }

    /// Health since `start()`, for the probe the controller schedules.
    func healthSoFar() -> MicHealth { Self.health(of: currentSamples()) }

    /// Was somebody else already holding the input device when we pressed the key?
    ///
    /// **This does not gate anything, and must not.** A list of call apps was the
    /// obvious idea and is the wrong one twice over: a Google Meet call inside a
    /// browser tab has no identity of its own to match, so the list is born
    /// incomplete; and a microphone on macOS is often SHARED, so "Zoom is in a
    /// call" does not mean this dictation would have failed. Blocking on it would
    /// cost real dictations to prevent an imagined failure.
    ///
    /// What it is good for is the sentence the user reads. "The microphone is not
    /// available" does not tell anybody to hang up; "another app is using it"
    /// does. So this runs BEFORE we open the device — afterwards the device is
    /// running because of US and the answer means nothing — and it is consulted
    /// only once the arrival probe has already decided the dictation is dead.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` asks CoreAudio, not a list
    /// of vendors, so nothing here rots when a new calling app appears.
    static func inputDeviceBusyElsewhere() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // A query that fails returns the same `false` as "nobody has it", so the
        // failure has to say so out loud — otherwise a broken check is
        // indistinguishable from a working one that found nothing.
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard deviceStatus == noErr, device != kAudioObjectUnknown else {
            Log.write("mic: cannot read the default input device (status \(deviceStatus))")
            return false
        }

        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let runningStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        guard runningStatus == noErr else {
            Log.write("mic: cannot read whether the input device is in use (status \(runningStatus))")
            return false
        }
        return running != 0
    }

    /// Note that the last start was dead so the ledger stays honest.
    ///
    /// Historically this demanded a graph rebuild; since 2026-08-14 every
    /// `start()` builds a fresh graph anyway, so what survives is the record —
    /// the log line in `start()` that says how many dead recordings preceded it.
    func markForRebuild() { watchdog.demandRebuild() }

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

    /// How loud the microphone has been since the last time anybody asked, as the
    /// RMS of the loudest buffer — for the wave, and for nothing else.
    ///
    /// **It costs no audio resource, which is the entire point.** The RMS is
    /// already computed in `append()` for the speech flag, so drawing the wave
    /// reads a number that exists rather than opening a second tap on the
    /// microphone — a second CoreAudio client, held only to draw a picture, is
    /// what the crashes of 2026-08-14 were made of.
    ///
    /// Consumed on read, and PEAK rather than latest, for two reasons that are the
    /// same reason: a reader at 30 Hz sees one or two buffers per tick and the
    /// loudest of them is the honest answer for that window, and a value that
    /// clears itself means a microphone that has stopped delivering reads as
    /// silence instead of freezing the wave at whatever it last heard. One reader
    /// only — a second one would see zeros the first one has already taken.
    func takeLevelPeak() -> Double {
        lock.lock(); let peak = levelPeak; levelPeak = 0; lock.unlock()
        return Double(peak)
    }

    /// The last `seconds` of audio, and nothing else.
    ///
    /// `currentSamples()` copies the entire recording, which at ten minutes is
    /// 9.6 million floats — fine once at the end, ruinous once a second.
    func tail(seconds: Double) -> [Float] {
        let wanted = Int(seconds * Self.targetSampleRate)
        lock.lock(); defer { lock.unlock() }
        guard samples.count > wanted else { return samples }
        return Array(samples[(samples.count - wanted)...])
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
        // One pass over the buffer that just arrived (~1024 frames), never over
        // what has accumulated.
        var sum: Float = 0
        for i in 0..<frames { let v = ch[0][i]; sum += v * v }
        let rms = frames > 0 ? (sum / Float(frames)).squareRoot() : 0
        lock.lock()
        if rms >= Self.speechFloor { _heardSpeech = true }
        if rms > levelPeak { levelPeak = rms }
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
///
/// Since 2026-08-14 every `start()` builds a fresh graph, so the watchdog no
/// longer decides WHETHER to rebuild — it remains the honest count of dead
/// recordings, surfaced in the log when a run of them ends.
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

    /// Ask for a rebuild outright, without waiting for the count.
    ///
    /// Used by the start-up probe: a tap that delivers zeros half a second after
    /// being told to listen has already proved the point that two whole dead
    /// recordings would prove more slowly.
    mutating func demandRebuild() { consecutiveDead = Self.deadLimit }
}
