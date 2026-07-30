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

    init(modelID: String) { self.modelID = modelID }

    var isLoaded: Bool { container != nil }
    var currentModelID: String { modelID }

    /// Switch the cleanup/translation model. Frees the current one from RAM;
    /// the new model loads lazily on the next `generate`. No-op if unchanged.
    func setModel(_ newID: String) {
        guard newID != modelID else { return }
        unload()                 // drop the old model + return its buffers to the OS
        modelID = newID
        Log.write("MLX cleanup model set to \(newID) (loads on next use)")
    }

    private func load() async throws -> ModelContainer {
        if let container { return container }
        // Distinguish "downloading from network" from "loading the cached model
        // into memory" (the 4 GB load takes ~10-30 s on first use per launch).
        let onDisk = FileManager.default.fileExists(
            atPath: ModelStorage.base.appendingPathComponent("models/\(modelID)/config.json").path)
        report(onDisk ? "Loading AI model…" : "Downloading AI model…")
        let configuration = LLMModelFactory.shared.configuration(id: modelID)
        let hub = HubApi(downloadBase: ModelStorage.base)
        let loaded = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: configuration) { progress in
            let pct = Int((progress.fractionCompleted * 100).rounded())
            // progressHandler only fires for actual downloads.
            Task { @MainActor in AppState.shared.status = .loadingModel("Downloading AI model \(pct)%") }
        }
        container = loaded
        report("Loading AI model…")
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

    private func report(_ message: String) {
        Task { @MainActor in AppState.shared.status = .loadingModel(message) }
    }

    /// Run one system+user turn, returning the model's text output.
    func generate(system: String,
                  user: String,
                  maxTokens: Int = 512,
                  temperature: Float = 0.2) async throws -> String {
        let container = try await load()
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)

        let result = try await container.perform { (context: ModelContext) in
            // Build messages inside the @Sendable closure — [Chat.Message] is not Sendable.
            let messages: [Chat.Message] = [.system(system), .user(user)]
            let input = try await context.processor.prepare(input: UserInput(chat: messages))
            let stream: AsyncStream<Generation> = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context)
            var output = ""
            for await item in stream {
                if case .chunk(let text) = item { output += text }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        scheduleIdleUnload()   // reset the idle timer on every use
        return result
    }
}
#endif
