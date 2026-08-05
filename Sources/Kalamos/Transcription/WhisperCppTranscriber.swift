import Foundation
import os
import whisper

/// whisper.cpp-backed transcriber — the third engine, added 2026-08-05.
///
/// Same model as `WhisperKitTranscriber` (Whisper large-v3-turbo), different
/// machine carrying it: C and Metal against Core ML and MLX. It exists for two
/// measured reasons, both from the bench in
/// `03-Plans/kalamos-whispercpp/REFERTO.md`:
///
///   1. **The prompt works here.** WhisperKit's `promptTokens` return an empty
///      transcription 48 times out of 48 (re-measured 2026-08-05 on the user's
///      own clips) because of upstream issue #372, fixed in no released tag. Here
///      `initial_prompt` is public C API and it repairs what it is given:
///      `fork` went from 0/8 to 5/5, `Otium` from 0/8 to 5/5, on real dictations
///      where the mistake was already on record.
///   2. **It does not drift.** Two hundred passes over five long files produced
///      two hundred identical texts. WhisperKit, same files same afternoon,
///      swung by 11 and by 31 words.
///
/// The engine is NOT the default and does not become it here. Whoever does not
/// pick it in Preferences is running exactly the app they ran yesterday.
///
/// `@unchecked Sendable`: every piece of mutable state is inside a lock, and the
/// context pointer only ever crosses `decodeQueue`, which is serial. A
/// `whisper_context` is not thread-safe and a second `whisper_full` on the same
/// context is a crash, not a race you get to observe.
final class WhisperCppTranscriber: Transcriber, @unchecked Sendable {
    /// GGML weights, the same OpenAI large-v3-turbo that WhisperKit loads as
    /// `openai_whisper-large-v3-v20240930_turbo`.
    static let modelFile = "ggml-large-v3-turbo.bin"
    static let modelURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    /// 1,62 GB. Used to say the size out loud in Preferences and as the floor in
    /// the arrival check — an HTML error page saved as `.bin` is about 2 kB, and
    /// that is the failure this number catches.
    static let modelBytes: Int64 = 1_624_555_275

    /// Where the file lives. A folder of its own so it never collides with the
    /// Core ML tree WhisperKit maintains, and so `du -sh` answers the question
    /// "how much is whisper.cpp costing me on disk" without arithmetic.
    static var modelPath: URL {
        ModelStorage.base
            .appendingPathComponent("models/ggml", isDirectory: true)
            .appendingPathComponent(modelFile)
    }

    /// `OpaquePointer` is not `Sendable` in Swift 6, and it is right not to be.
    /// The box says why this one is safe instead of silencing the compiler
    /// somewhere it would not be read: the pointer is only ever dereferenced on
    /// `decodeQueue`, which is serial, and it is freed on that same queue.
    private struct Ctx: @unchecked Sendable { let raw: OpaquePointer }

    private let ctxBox = OSAllocatedUnfairLock<Ctx?>(initialState: nil)
    private let idleBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let promptBox = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let decodeQueue = DispatchQueue(label: "kalamos.whispercpp.decode")

    /// The vocabulary, as prior context handed to the decoder BEFORE it guesses.
    /// Settable rather than read from settings inside the transcriber, for the
    /// same reason the WhisperKit one is: a probe that reads the app's own
    /// defaults measures whichever domain the probe happens to run in, and that
    /// has cost this project three wrong answers.
    var initialPrompt: String? {
        get { promptBox.withLock { $0 } }
        set { promptBox.withLock { $0 = newValue } }
    }

    // MARK: - Model

    func prepare() async throws {
        if ctxBox.withLock({ $0 }) != nil { scheduleIdleUnload(); return }

        let path = Self.modelPath
        if !FileManager.default.fileExists(atPath: path.path) {
            try await Self.download(to: path)
        }
        try Self.assertModelArrived(at: path)

        Self.report(.loading(.speech))
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true       // Metal; the bench ran on it
        cparams.flash_attn = true
        guard let ctx = path.path.withCString({ whisper_init_from_file_with_params($0, cparams) })
        else { throw ModelDownloadError.nothingArrived(model: Self.modelFile, folder: path.path) }
        // Boxed BEFORE the lock: `withLock` takes a `@Sendable` closure, so
        // capturing the bare pointer inside it is exactly the thing `Ctx` exists
        // to avoid.
        let boxed = Ctx(raw: ctx)
        ctxBox.withLock { $0 = boxed }
        scheduleIdleUnload()
    }

    /// Trust the file, not the return value.
    ///
    /// The same rule the WhisperKit path learned the hard way on 2026-08-02, when
    /// two of the four models in Preferences could not be downloaded because an
    /// offline branch returned success having fetched nothing. A transfer that
    /// "succeeded" and left 2 kB behind is that failure wearing a different coat.
    static func assertModelArrived(at path: URL) throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int64) ?? 0
        guard size > modelBytes / 2 else {
            Log.write("modello whisper.cpp incompleto: \(size) byte in \(path.path)")
            try? FileManager.default.removeItem(at: path)   // never leave a half file to be trusted later
            throw ModelDownloadError.nothingArrived(model: modelFile, folder: path.path)
        }
    }

    /// Straight `URLSession` download with progress in the menu bar, written to a
    /// temporary neighbour and moved into place only once complete. The move is
    /// the point: a process killed mid-transfer leaves no file at all, rather
    /// than a short one that looks installed.
    private static func download(to path: URL) async throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        report(.downloading(.speech, fraction: nil))

        let (bytes, response) = try await URLSession.shared.bytes(from: modelURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelDownloadError.nothingArrived(model: modelFile, folder: path.path)
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : modelBytes

        let tmp = path.appendingPathExtension("parziale")
        try? FileManager.default.removeItem(at: tmp)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let fraction = Double(written) / Double(expected)
                // Reporting every megabyte would put ~1500 hops on the main actor.
                if fraction - lastReported > 0.01 {
                    lastReported = fraction
                    report(.downloading(.speech, fraction: min(fraction, 1)))
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: tmp, to: path)
        Log.write("modello whisper.cpp scaricato in \(path.path)")
    }

    func setVocabularyPrompt(_ text: String?) { initialPrompt = text }

    func setModel(_ name: String) async {
        // The variant picker belongs to WhisperKit — this engine ships one model,
        // exactly as Parakeet does. Answering it here would let the menu show a
        // model this engine has never heard of.
    }

    private func scheduleIdleUnload() {
        guard let seconds = Tuning.idleUnloadSeconds else {
            let old = idleBox.withLock { box -> Task<Void, Never>? in let p = box; box = nil; return p }
            old?.cancel()
            return
        }
        let newTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            self?.unload()
        }
        let old = idleBox.withLock { box -> Task<Void, Never>? in
            let previous = box; box = newTask; return previous
        }
        old?.cancel()
    }

    /// Libera il contesto ADESSO, e aspetta che sia libero.
    ///
    /// Serve prima di `exit`, e non è un vezzo: ggml tiene i Metal residency set
    /// in una collezione globale distrutta dai distruttori statici, e
    /// `ggml-metal-device.m:657` asserisce che a quel punto sia vuota. Con un
    /// contesto ancora vivo l'asserzione salta e il processo **aborta uscendo**,
    /// dopo aver fatto tutto il lavoro giusto: exit 134 su un binario che aveva
    /// già scritto il suo JSON. Da fuori sembra un crash dell'app, ed è il
    /// momento peggiore in cui sembrarlo.
    func shutdown() {
        let ctx = ctxBox.withLock { box -> Ctx? in let p = box; box = nil; return p }
        guard let ctx else { return }
        decodeQueue.sync { whisper_free(ctx.raw) }
        Log.write("whisper.cpp: contesto liberato prima dell'uscita")
    }

    private func unload() {
        let ctx = ctxBox.withLock { box -> Ctx? in let p = box; box = nil; return p }
        if let ctx { decodeQueue.async { whisper_free(ctx.raw) } }
        Log.write("whisper.cpp model unloaded (idle) — RAM freed")
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float],
                    allowedLanguages: Set<Language>,
                    forced: Language?) async throws -> TranscriptionResult {
        try await prepare()
        Self.report(.transcribing)
        guard let ctx = ctxBox.withLock({ $0 }) else {
            return TranscriptionResult(text: "", detectedLanguage: nil)
        }

        // The two audio gates are WhisperKit's, on purpose. They are shared code
        // and not a copy: `isSilent` was rewritten on 2026-08-04 after it threw
        // away whole dictations by averaging loudness over the entire recording,
        // and a second copy of that logic would be a second chance to get it
        // wrong.
        let trimmed = WhisperKitTranscriber.trimSilence(samples)
        if WhisperKitTranscriber.isSilent(samples) {
            Log.write("recording was silent — not transcribed")
            return TranscriptionResult(text: "", detectedLanguage: forced)
        }

        let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = forced?.rawValue
        let threads = Int32(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        return try await withCheckedThrowingContinuation { continuation in
            decodeQueue.async {
                do {
                    let result = try Self.run(ctx: ctx.raw, samples: trimmed, language: language,
                                              prompt: prompt, threads: threads)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One blocking `whisper_full`, on the serial decode queue.
    ///
    /// Everything the bench measured is set here and nowhere else, so the
    /// configuration under test is visible in one screen.
    private static func run(ctx: OpaquePointer, samples: [Float], language: String?,
                            prompt: String?, threads: Int32) throws -> TranscriptionResult {
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = threads
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.translate = false          // keep the words in the language spoken
        params.suppress_blank = true

        // `carry_initial_prompt` is not optional, and that is the single most
        // surprising number the bench produced. With the prompt set and this
        // flag OFF, audio longer than one 30-second window degenerates: 198 words
        // instead of 128 on an 82-second file, thirteen identical repetitions of
        // an invented sentence, eight times out of eight. With it ON the same
        // file comes back at 123 words and sane, and on a second file it recovers
        // an entire sentence that every other configuration loses 0/8.
        //
        // So: whoever removes this line must re-run
        // `bun Banco.ts --set lunghe --passate 8` before believing it is safe.
        params.carry_initial_prompt = true

        return try withExtendedLifetime(samples) {
            func decode(_ languageC: UnsafePointer<CChar>?, _ promptC: UnsafePointer<CChar>?)
                throws -> TranscriptionResult
            {
                var p = params
                if let languageC {
                    p.language = languageC
                    p.detect_language = false
                } else {
                    p.detect_language = true
                }
                p.initial_prompt = promptC

                let code = samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, p, buffer.baseAddress, Int32(buffer.count))
                }
                guard code == 0 else { throw TranscriptionError.decodeFailed(code: Int(code)) }

                var text = ""
                for i in 0..<whisper_full_n_segments(ctx) {
                    if let piece = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: piece)
                    }
                }
                let langId = whisper_full_lang_id(ctx)
                let detected = langId >= 0
                    ? whisper_lang_str(langId).flatMap { Language(rawValue: String(cString: $0)) }
                    : nil
                let finale = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // La guardia gira anche qui, non solo nei test. Se un giorno un
                // decode degenera lo si legge nel registro il giorno stesso,
                // invece di scoprirlo da una dettatura di 198 parole incollata
                // in una chat.
                let run = RepetitionGuard.longestRun(in: finale)
                if run.count >= RepetitionGuard.limit {
                    Log.write("whisper.cpp: decode in loop — \(run.count)× «\(run.sentence)»")
                }
                return TranscriptionResult(
                    text: finale,
                    detectedLanguage: detected ?? language.flatMap(Language.init(rawValue:)))
            }

            // The C strings have to outlive `whisper_full`, so the nesting is the
            // lifetime: `withCString` guarantees the pointer only inside its body.
            switch (language, prompt.flatMap { $0.isEmpty ? nil : $0 }) {
            case let (l?, p?):
                return try l.withCString { lc in try p.withCString { pc in try decode(lc, pc) } }
            case let (l?, nil):
                return try l.withCString { lc in try decode(lc, nil) }
            case let (nil, p?):
                return try p.withCString { pc in try decode(nil, pc) }
            case (nil, nil):
                return try decode(nil, nil)
            }
        }
    }

    private static func report(_ status: DictationStatus) {
        Task { @MainActor in AppState.shared.status = status }
    }
}

enum TranscriptionError: LocalizedError {
    case decodeFailed(code: Int)

    var errorDescription: String? {
        switch self {
        case let .decodeFailed(code):
            return "La trascrizione non è riuscita (codice \(code))."
        }
    }
}
