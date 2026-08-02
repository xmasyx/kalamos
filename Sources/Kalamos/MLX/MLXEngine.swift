import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX
import Hub

/// Shared on-device LLM. Loads one quantized instruct model into unified memory
/// and runs short prompt→completion turns for formatting and translation.
/// Lazy-loaded on first use (ISC-55) and shared by `MLXFormatter` + `MLXTranslator`
/// so the model is resident only once.
actor MLXEngine {
    /// Multilingual (IT/EN/FR), ~4.3 GB 4-bit — comfortable on 24 GB.
    static let defaultModelID = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    static let shared = MLXEngine(modelID: defaultModelID)

    private var modelID: String
    private var container: ModelContainer?
    private var idleTask: Task<Void, Never>?

    init(modelID: String) {
        self.modelID = modelID
        Self.capTheBufferCacheOnce()
    }

    /// Put a ceiling on MLX's Metal buffer cache, once, before anything allocates.
    ///
    /// Left alone, that cache's limit defaults to the memory limit — measured on
    /// this Mac: **35 020 MB**, i.e. 34 GB on a 36 GB machine. It is a pool of
    /// freed buffers kept for reuse, and dictations of different lengths keep
    /// asking for different sizes, so it only grows. A process left running all
    /// day reached a 13 GB footprint (12 GB in IOAccelerator across 2391 regions)
    /// while the same binary restarted two minutes earlier sat at 4.9 GB with
    /// 1007 regions — same models, same settings, 7.5 GB of pure accumulation.
    ///
    /// Nothing ever emptied it: the only `clearCache()` lives in `unload()`, and
    /// whoever sets the memory to "never free" — a legitimate choice, to avoid
    /// paying the reload — never reaches `unload()` at all.
    ///
    /// Measured cost of the cap, 2 replicates, arms alternated A,B,A,B, 8 rounds ×
    /// 5 dictations at temperature 0 so both arms generate identical tokens:
    /// **−0.44% and −0.72% on time, inside a 6.6%/13.6% intra-arm noise band** —
    /// no measurable cost. Memory: cache 1608 → 511 MB, footprint 5946 → 4844 MB
    /// after only 40 generations. (An earlier block design, A,A,B,B, reported
    /// "+15% slower"; that was thermal drift dumped entirely on the second arm.)
    ///
    /// Deliberately NOT `clearCache()` after each generation: that empties the
    /// pool every time, so every generation re-pays for every allocation. A cap
    /// self-regulates — MLX reclaims from its LRU queue on the first allocation
    /// past the threshold. And never 0, which disables the cache outright.
    ///
    /// The model weights are not in here — they live in `activeMemory`, as does
    /// the generation's KV cache. A cap shortens no context and costs no quality.
    private static func capTheBufferCacheOnce() {
        _ = capApplied
    }

    private static let capApplied: Bool = {
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        Log.write("MLX buffer cache capped at 512 MB")
        return true
    }()

    var isLoaded: Bool { container != nil }
    var currentModelID: String { modelID }

    /// What the last generation cost, split the way the model splits it.
    ///
    /// The same numbers already go to the log (`mlx: prompt N tok…`); this makes
    /// them readable by code, which is what a bench needs to answer "how many
    /// tokens does this prompt cost" without parsing a log line. One slot, read
    /// by whoever ran the generation immediately afterwards — with two callers in
    /// flight the second would overwrite the first, so nothing but a sequential
    /// bench should trust it.
    struct GenStats: Sendable {
        let promptTokens: Int
        let promptSeconds: Double
        let generatedTokens: Int
        let generateSeconds: Double
    }
    private(set) var lastStats: GenStats?

    /// Switch the cleanup/translation model. Frees the current one from RAM;
    /// the new model loads lazily on the next `generate`. No-op if unchanged.
    func setModel(_ newID: String) {
        guard newID != modelID else { return }
        unload()                 // drop the old model + return its buffers to the OS
        modelID = newID
        Log.write("MLX cleanup model set to \(newID) (loads on next use)")
    }

    private func load() async throws -> ModelContainer {
        if let container {
            // Stop the idle timer for the duration of the work that is about to
            // start. Without this, the timer armed at the end of the PREVIOUS
            // generation can expire in the middle of this one: `unload()` drops
            // the container and clears the GPU cache while the model is running,
            // so the next dictation pays a cold load nobody asked for — the very
            // wait the "never free the memory" setting exists to avoid. The timer
            // is re-armed when the work finishes. (Gemini audit, 2026-07-31.)
            idleTask?.cancel()
            idleTask = nil
            return container
        }
        // Distinguish "downloading from network" from "loading the cached model
        // into memory" (the 4 GB load takes ~10-30 s on first use per launch).
        let onDisk = FileManager.default.fileExists(
            atPath: ModelStorage.base.appendingPathComponent("models/\(modelID)/config.json").path)
        Self.report(onDisk ? .loading(.cleanup) : .downloading(.cleanup, fraction: nil))
        // An actor releases its lock at every `await`, so `setModel` can run while
        // this load is suspended. It would then find `container` still nil, unload
        // nothing, and write the new id — and this line would install the OLD
        // model under the new name: the engine runs one model while the settings
        // show another, for the rest of the session. Compare before installing.
        // (Gemini audit, 2026-07-31.)
        let requested = modelID
        let configuration = LLMModelFactory.shared.configuration(id: requested)
        let hub = HubApi(downloadBase: ModelStorage.base)
        let loaded = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { progress in
            // "progressHandler only fires for actual downloads" is what this line
            // used to say, and it is false: it fires while the cached model is
            // read off the disk as well. So every relaunch overrode the `.loading`
            // decided two lines above with `.downloading`, and the panel announced
            // a download of a model that had been on this Mac for weeks. Reported
            // 2026-08-02 — "it says it is downloading and nothing should be".
            //
            // `onDisk` was already computed and already right. Trust it.
            guard !onDisk else { return }
            Self.report(.downloading(.cleanup, fraction: progress.fractionCompleted))
        }
        guard modelID == requested else {
            Log.write("MLX: \(requested) finished loading but \(modelID) is now wanted — discarding")
            return try await load()
        }
        container = loaded
        // The bytes are here; what is left is reading them into memory. Saying
        // "downloading" past this point is the lie this whole split exists to end.
        Self.report(.loading(.cleanup))
        scheduleIdleUnload()
        return loaded
    }

    /// Preload the model into memory (call at launch so the first dictation
    /// doesn't pay the ~10-30 s load).
    func warmUp() async { _ = try? await load() }

    // MARK: Idle unload (RAM)
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard let seconds = Tuning.idleUnloadSeconds else { idleTask = nil; return }  // nil = never
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            await self?.unload()
        }
    }

    private func unload() {
        guard container != nil else { return }
        container = nil
        MLX.GPU.clearCache()   // return the freed buffers to the OS (~4 GB)
        Log.write("MLX model unloaded (idle) — RAM freed")
    }

    /// `nonisolated static` on purpose: the download progress handler is a
    /// `@Sendable` closure that runs off the actor, and it has to be able to say
    /// how far along it is.
    private nonisolated static func report(_ status: DictationStatus) {
        Task { @MainActor in AppState.shared.status = status }
    }

    /// Run one system+user turn, returning the model's text output.
    ///
    /// `purpose` is what the user is told while it runs. The model takes seconds
    /// on a long dictation, and "cleaning up" and "translating" are different
    /// enough that showing one for the other is worth avoiding.
    func generate(system: String,
                  user: String,
                  purpose: WorkKind,
                  maxTokens: Int = 512,
                  temperature: Float = 0.2) async throws -> String {
        let container = try await load()
        // `defer`, not a line at the end: `load()` cancelled the idle timer, and
        // if generation throws — cancellation, a context overflow — a plain
        // trailing call never runs and the model stays resident forever. The
        // "free the memory after N minutes" setting would then quietly stop
        // working, with no symptom but the RAM. (Gemini audit, 2026-07-31.)
        defer { scheduleIdleUnload() }
        Self.report(.working(purpose))
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)

        let result = try await container.perform { (context: ModelContext) -> (String, GenStats?) in
            // Build messages inside the @Sendable closure — [Chat.Message] is not Sendable.
            let messages: [Chat.Message] = [.system(system), .user(user)]
            let input = try await context.processor.prepare(input: UserInput(chat: messages))
            let stream: AsyncStream<Generation> = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context)
            var output = ""
            var stats: GenStats?
            for await item in stream {
                switch item {
                case .chunk(let text): output += text
                case .info(let info):
                    // The split between reading the prompt and writing the answer.
                    // Without it, "the cleanup takes two seconds" is one number
                    // hiding two very different jobs, and any optimisation is a
                    // guess about which half it lands on.
                    Log.write(String(
                        format: "mlx: prompt %d tok in %.2fs (%.0f t/s) · gen %d tok in %.2fs (%.0f t/s)",
                        info.promptTokenCount, info.promptTime, info.promptTokensPerSecond,
                        info.generationTokenCount, info.generateTime, info.tokensPerSecond))
                    stats = GenStats(
                        promptTokens: info.promptTokenCount, promptSeconds: info.promptTime,
                        generatedTokens: info.generationTokenCount, generateSeconds: info.generateTime)
                @unknown default: break
                }
            }
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), stats)
        }
        lastStats = result.1
        return result.0
    }
}
#endif
