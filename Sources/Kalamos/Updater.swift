import AppKit
import Combine
import Foundation

/// La rete e i processi dell'aggiornamento restano qui; ogni decisione viene da `Updates`.
@MainActor
final class Updater: ObservableObject {
    enum State {
        case idle
        case checking
        case upToDate(current: String)
        case available(version: String, action: Updates.Action)
        case upgrading(line: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let defaults = UserDefaults.standard
    private let environment = ProcessInfo.processInfo.environment
    private let benchMode = CommandLine.arguments.contains("--bench-updates")
    private var releasePage: URL?
    private var acceptsProcessLines = false

    /// Il click cambia stato subito; la rete prosegue senza fermare il menu o l'avviso.
    func checkNow() {
        guard !isBusy else { return }
        state = .checking
        Task { await check() }
    }

    /// Il controllo giornaliero è una sola lettura; fuori rete resta silenzioso nell'interfaccia.
    func checkIfDue() {
        let last = benchMode ? nil : defaults.object(forKey: "updates.lastCheck") as? Date
        guard Updates.isDue(lastCheck: last, now: Date()) else { return }
        checkNow()
    }

    func perform(_ action: Updates.Action) {
        switch action {
        case .openReleasePage(let url):
            open(url)
        case .upgradeAndRelaunch(let arguments):
            guard let brew = brewURL() else {
                state = .failed(UpdateCopy.brewMissing)
                printBenchState()
                if let releasePage { open(releasePage) }
                return
            }
            state = .upgrading(line: UpdateCopy.preparing)
            printBenchState()
            Task { await upgrade(with: brew, arguments: arguments) }
        }
    }

    /// Il banco usa lo stesso controllo e la stessa azione, aspettando solo che il processo finisca.
    func runBench() async -> Int32 {
        guard !isBusy else { return 2 }
        state = .checking
        printBenchState()
        await check()

        guard case .available(_, let action) = state else {
            printBenchState()
            return 3
        }
        perform(action)

        while case .upgrading = state {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return 0
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .upgrading: return true
        default: return false
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func check() async {
        defer {
            // Una misura non diventa l'ultimo controllo dell'app installata.
            if !benchMode { defaults.set(Date(), forKey: "updates.lastCheck") }
        }

        do {
            let data = try await releaseData()
            guard let tag = Updates.latestTag(fromReleaseJSON: data) else {
                throw UpdateError.releaseWithoutTag
            }

            guard let version = Updates.newerVersion(current: currentVersion, latestTag: tag) else {
                state = .upToDate(current: currentVersion)
                printBenchState()
                return
            }

            let roots = environment["KALAMOS_CASKROOM"].map { [$0] }
                ?? ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
            // La sonda dichiara il luogo che simula: il binario in `.build` non potrebbe
            // altrimenti coprire il polo Homebrew.
            let bundlePath = benchMode ? "/Applications/Kalamos.app" : Bundle.main.bundlePath
            let source = Updates.source(
                bundlePath: bundlePath,
                caskroomRoots: roots,
                homeDirectory: NSHomeDirectory(),
                fileExists: FileManager.default.fileExists(atPath:)
            )
            let action = Updates.action(for: source, version: version)
            if case .openReleasePage(let url) = Updates.action(for: .manual, version: version) {
                releasePage = url
            }
            state = .available(version: version, action: action)
            printBenchState()
        } catch {
            let reason = (error as? UpdateError)?.message ?? error.localizedDescription
            Log.write("controllo aggiornamenti non riuscito: \(reason)")
            state = .failed(reason)
            printBenchState()
        }
    }

    private func releaseData() async throws -> Data {
        let rawURL = environment["KALAMOS_UPDATES_API"]
            ?? "https://api.github.com/repos/\(Updates.repo)/releases/latest"
        guard let url = URL(string: rawURL) else { throw UpdateError.invalidURL }

        // `URLSession` non carica `file://`: questo è il rubinetto locale del banco.
        if url.isFileURL {
            return try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kalamos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw UpdateError.badResponse }
        return data
    }

    private func brewURL() -> URL? {
        let candidates: [String]
        if let selected = environment["KALAMOS_BREW"] {
            candidates = [selected]
        } else {
            candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func processEnvironment(autoUpdate: Bool) -> [String: String] {
        var result = environment
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["HOME"] = NSHomeDirectory()
        result["HOMEBREW_NO_ENV_HINTS"] = "1"
        result["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if autoUpdate {
            result.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        } else {
            result["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return result
    }

    private func upgrade(with brew: URL, arguments: [String]) async {
        let fastEnvironment = processEnvironment(autoUpdate: false)
        let repository = await UpdateProcessRunner.run(
            executable: brew,
            arguments: ["--repository", Updates.tap],
            environment: fastEnvironment
        )

        var tapIsFresh = false
        if repository.status == 0, let path = repository.lines.last, !path.isEmpty {
            let pull = await UpdateProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "pull", "--ff-only", "-q"],
                environment: fastEnvironment
            )
            tapIsFresh = pull.status == 0
        }

        acceptsProcessLines = true
        let result = await UpdateProcessRunner.run(
            executable: brew,
            arguments: arguments,
            environment: processEnvironment(autoUpdate: !tapIsFresh)
        ) { [weak self] line in
            Task { @MainActor in
                guard let self, self.acceptsProcessLines else { return }
                self.state = .upgrading(line: line)
                self.printBenchState()
            }
        }
        acceptsProcessLines = false

        guard result.status == 0 else {
            let reason = result.lines.suffix(2).joined(separator: " · ")
            let message = reason.isEmpty ? UpdateCopy.processFailed : reason
            Log.write("aggiornamento Homebrew non riuscito: \(message)")
            state = .failed(message)
            printBenchState()
            return
        }

        // Il banco non deve riaprire se stesso all'infinito.
        guard !benchMode else {
            state = .idle
            printBenchState()
            return
        }
        await clearQuarantine()
        relaunchAfterExit()
        NSApp.terminate(nil)
    }

    /// Homebrew 6 lascia il contrassegno sull'app appena installata. Si tocca SOLO il bundle
    /// di questo processo; un fallimento viene registrato ma non blocca il riavvio.
    private func clearQuarantine() async {
        let result = await UpdateProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", Bundle.main.bundlePath],
            environment: processEnvironment(autoUpdate: false)
        )
        if result.status != 0 {
            Log.write("aggiornata, ma la quarantena è rimasta: \(result.lines.last ?? "")")
        }
    }

    private func relaunchAfterExit() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -a \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func open(_ url: URL) {
        if benchMode {
            print("openReleasePage \(url.absoluteString)")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func printBenchState() {
        guard benchMode else { return }
        switch state {
        case .idle: print("idle")
        case .checking: print("checking")
        case .upToDate(let current): print("upToDate \(current)")
        case .available(let version, let action):
            switch action {
            case .upgradeAndRelaunch: print("available \(version) upgradeAndRelaunch")
            case .openReleasePage(let url):
                print("available \(version) openReleasePage \(url.absoluteString)")
            }
        case .upgrading(let line): print("upgrading \(line)")
        case .failed(let reason): print("failed \(reason)")
        }
        fflush(stdout)
    }
}

@MainActor
private enum UpdateCopy {
    static var preparing: String {
        L.t("Preparo Homebrew…", "Preparing Homebrew…", "Préparation de Homebrew…")
    }
    static var brewMissing: String {
        L.t("Homebrew non è disponibile; scarica invece la versione nuova.",
            "Homebrew is not available; download the release instead.",
            "Homebrew n’est pas disponible ; téléchargez plutôt la nouvelle version.")
    }
    static var processFailed: String {
        L.t("Homebrew si è fermato senza una ragione",
            "Homebrew stopped without a reason",
            "Homebrew s’est arrêté sans donner de raison")
    }
}

private enum UpdateError: Error {
    case invalidURL
    case badResponse
    case releaseWithoutTag

    @MainActor var message: String {
        switch self {
        case .invalidURL:
            return L.t("indirizzo degli aggiornamenti non valido",
                       "invalid update URL",
                       "adresse des mises à jour non valide")
        case .badResponse:
            return L.t("il servizio degli aggiornamenti ha restituito un errore",
                       "the update server returned an error",
                       "le service de mise à jour a renvoyé une erreur")
        case .releaseWithoutTag:
            return L.t("alla versione pubblicata manca il numero",
                       "the release has no version tag",
                       "la version publiée n’a pas de numéro")
        }
    }
}

private enum UpdateProcessRunner {
    struct Result {
        let status: Int32?
        let lines: [String]
    }

    static func run(executable: URL,
                    arguments: [String],
                    environment: [String: String],
                    line: (@Sendable (String) -> Void)? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let output = UpdateProcessOutput()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                output.append(data).forEach { line?($0) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile()).forEach { line?($0) }
                continuation.resume(returning: Result(status: finished.terminationStatus,
                                                       lines: output.finish()))
            }

            do {
                try process.run()
                pipe.fileHandleForWriting.closeFile()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                pipe.fileHandleForWriting.closeFile()
                continuation.resume(returning: Result(status: nil,
                                                       lines: [error.localizedDescription]))
            }
        }
    }
}

/// `FileHandle` consegna byte su code diverse; il lucchetto conserva righe e ordine e tiene
/// soltanto le ultime due righe, anche con un processo molto rumoroso.
private final class UpdateProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var latest: [String] = []

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var complete: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let bytes = pending[..<newline]
            pending.removeSubrange(...newline)
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            complete.append(text)
            latest.append(text)
            latest = Array(latest.suffix(2))
        }
        return complete
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            latest.append(text)
            latest = Array(latest.suffix(2))
        }
        pending.removeAll()
        return latest
    }
}
