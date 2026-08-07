import AppKit
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Wait for a headless command WITHOUT parking the main thread.
///
/// Every `--clean` / `--selftest-*` / `--cache-probe` run hung forever, and the
/// reason is one line in the cleanup path: `await MainActor.run { … }`, executed
/// on every successful cleanup. A main thread sitting in `sem.wait()` never
/// services the main actor, so that hop can never land and the whole process
/// deadlocks — silently, at 0% CPU, after printing its first line. The README
/// tells readers to reproduce its examples with `--clean`; that command could
/// not have worked. Pumping the run loop while waiting lets the hop through.
///
/// Probe: `Kalamos --selftest-punct` returned exit 124 under `timeout 180`
/// before this, and prints its cases after (2026-07-31).
func waitServicingMainActor(_ sem: DispatchSemaphore) {
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

// FIRST, before anything reads settings or touches Application Support: carry the
// user's settings and downloaded models over from the app's former identity
// (Parla). Runs once, then costs a single boolean read per launch.
Migration.runIfNeeded()

// User-facing diagnostic: `Kalamos --doctor` reports which of the things dictation
// depends on (permissions, models, Metal shaders, disk) is missing, and exits
// non-zero if any REQUIRED one is. The first thing to run when "it doesn't work".
if CommandLine.arguments.contains("--doctor") {
    exit(Doctor.run())
}

// `Kalamos --version` — so the installer and bug reports can state which build is
// on disk without opening the bundle.
// `Kalamos --footprint` prints the same number `/usr/bin/footprint` calls
// phys_footprint, read from inside the process. Exists so the two can be
// compared: a self-measurement nobody has checked against the system tool is an
// assertion, not a measurement.
if CommandLine.arguments.contains("--footprint") {
    if let mb = Footprint.megabytes { print("phys_footprint: \(mb) MB") ; exit(0) }
    FileHandle.standardError.write(Data("footprint unavailable\n".utf8))
    exit(2)
}

if CommandLine.arguments.contains("--version") {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    print("Kalamos \(v)")
    exit(0)
}

// `Kalamos --clean "text" [--lang it|en|fr]` runs the cleanup pass on one piece
// of text and prints the result. Two reasons it exists: every example in the
// README can be reproduced by the reader with one command, and you can judge the
// cleanup on your own sentences before letting it near a text field.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--clean") {
    let args = CommandLine.arguments
    let text = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !text.isEmpty, !text.hasPrefix("--") else {
        print("usage: Kalamos --clean \"your dictated text\" [--lang it|en|fr]")
        exit(2)
    }
    var language = Language.english
    if let l = args.firstIndex(of: "--lang"), l + 1 < args.count,
       let parsed = Language(rawValue: args[l + 1].lowercased()) {
        language = parsed
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        // --terminal exercises the verbatim path. Without it the context has no
        // frontmost app, so `isTerminal` is false and the general cleanup runs —
        // which made an earlier "verification" of the strict path measure the
        // wrong one entirely.
        let bundle = args.contains("--terminal") ? "com.googlecode.iterm2" : nil
        let out = await MLXFormatter(engine: .shared)
            .format(text, context: FormattingContext(language: language,
                                                     frontmostBundleID: bundle))
        print(out)
        #else
        print("ERROR: MLX not compiled in — rebuild with ./Scripts/build-app.sh")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --selftest-engine <file.wav> [--engine whisper|parakeet] [--lang it]`
//
// Runs a real audio file through the REAL transcriber, the one a dictation uses,
// and prints what came back with the seconds it took. It exists because every
// other check on a speech engine in this project has been a bench living outside
// the app: this is the only way to see that the engine wired INTO Kalamos says
// what the bench said it would.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-engine") {
    let args = CommandLine.arguments
    let path = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !path.isEmpty, !path.hasPrefix("--") else {
        print("usage: Kalamos --selftest-engine <file.wav> [--engine whisper|parakeet] [--lang it|en|fr] [--ripeti N] [--prompt \"…\"]")
        exit(2)
    }
    let engineName = args.firstIndex(of: "--engine").flatMap {
        $0 + 1 < args.count ? args[$0 + 1] : nil
    } ?? "parakeet"
    let forced = args.firstIndex(of: "--lang").flatMap {
        $0 + 1 < args.count ? Language(rawValue: args[$0 + 1].lowercased()) : nil
    }
    let repeats = args.firstIndex(of: "--ripeti").flatMap {
        $0 + 1 < args.count ? Int(args[$0 + 1]) : nil
    } ?? 1
    // The Whisper prompt under test, passed in as TEXT. It is not read from the
    // app's vocabulary on purpose: a probe that reads settings measures the
    // defaults domain it happens to run in, and the two domains have disagreed
    // three times in this project. What is measured has to be visible in the
    // command that measured it.
    let promptText = args.firstIndex(of: "--prompt").flatMap {
        $0 + 1 < args.count ? args[$0 + 1] : nil
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(FluidAudio) && canImport(WhisperKit)
        do {
            guard let engine = SpeechEngine(rawValue: engineName) else {
                print("motore sconosciuto: \(engineName)"); exit(2)
            }
            // A file or a whole directory. A directory in ONE process is the
            // point: Whisper pays ten to twenty seconds to load, and paying it
            // per clip would put the load into the per-clip seconds.
            var files: [URL] = []
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue {
                files = try FileManager.default
                    .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "wav" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files = [url]
            }
            // ONE decode per clip, handed to whichever engine is asked. A
            // per-engine decode path would put format differences into the
            // accuracy column.
            let converter = AudioConverter()
            var samplesByClip: [(name: String, samples: [Float])] = []
            for file in files {
                samplesByClip.append((file.lastPathComponent,
                                      try converter.resampleAudioFile(file)))
            }
            // Which speech model, said out loud rather than inherited from
            // whichever defaults domain this process happens to read.
            let modelloScelto = args.firstIndex(of: "--modello").flatMap {
                $0 + 1 < args.count ? args[$0 + 1] : nil
            }
            let modello: String
            if let m = modelloScelto { modello = m }
            else { modello = await AppState.shared.whisperModel }
            let whisper: WhisperKitTranscriber? = engine == .whisper
                ? WhisperKitTranscriber(modelName: modello)
                : nil
            let cpp: WhisperCppTranscriber? = engine == .whispercpp
                ? WhisperCppTranscriber()
                : nil
            whisper?.initialPrompt = promptText
            cpp?.initialPrompt = promptText
            // `--vocabolario` esercita il percorso VERO dell'app: le parole
            // dell'utente iniettate come lista, e il prompt costruito dopo la
            // prima decodifica su ciò che sembra sbagliato. `--prompt` invece è
            // un ordine: quel testo, una passata sola. Due strade diverse, e
            // misurarle con lo stesso flag le avrebbe confuse.
            if args.contains("--vocabolario") {
                let voci = args.firstIndex(of: "--vocabolario").flatMap {
                    $0 + 1 < args.count && !args[$0 + 1].hasPrefix("--")
                        ? args[$0 + 1].split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces) }
                        : nil
                } ?? Vocabulary.terms
                cpp?.setVocabulary(voci)
                FileHandle.standardError.write(Data("vocabolario iniettato: \(voci.count) voci\n".utf8))
            }
            if promptText != nil && engine == .parakeet {
                print("--prompt vale solo per i motori Whisper — ignorato")
            }
            // Scritto a mano e non con due `??`: i tre tipi non hanno un
            // antenato comune che l'inferenza possa trovare, e il compilatore su
            // quella riga non riusciva nemmeno a stampare l'errore.
            let transcriber: Transcriber
            switch engine {
            case .whisper: transcriber = whisper!
            case .whispercpp: transcriber = cpp!
            case .parakeet: transcriber = ParakeetTranscriber()
            }
            FileHandle.standardError.write(Data(
                "motore: \(engine.rawValue) · \(samplesByClip.count) clip · \(repeats) passate · lingua \(forced?.rawValue ?? "auto") · prompt \(promptText == nil ? "spento" : "acceso")\n".utf8))
            try await transcriber.prepare()
            // Warm-up discarded: the first CoreML call pays lazy compilation.
            if let first = samplesByClip.first {
                _ = try await transcriber.transcribe(
                    first.samples, allowedLanguages: [.italian, .english, .french], forced: forced)
            }
            struct EngineRow: Codable {
                let clip: String, engine: String, pass: Int
                let text: String, seconds: Double, language: String?
                // The gate metric. `vuota` is what the caller got; `vuotaPrimaDelRecupero`
                // is what the decoder produced before ISC-108 reloaded the model
                // and tried again. Only the second one measures the decode.
                let vuota: Bool, vuotaPrimaDelRecupero: Bool
                let lingua: String, prompt: Bool
            }
            var rows: [EngineRow] = []
            _ = whisper?.takeEmptyBeforeRecovery()   // discard the warm-up's
            for pass in 1...max(1, repeats) {
                for clip in samplesByClip {
                    let t0 = Date()
                    let out = try await transcriber.transcribe(
                        clip.samples, allowedLanguages: [.italian, .english, .french],
                        forced: forced)
                    let seconds = Date().timeIntervalSince(t0)
                    let empties = whisper?.takeEmptyBeforeRecovery() ?? 0
                    rows.append(EngineRow(clip: clip.name, engine: engine.rawValue, pass: pass,
                                          text: out.text, seconds: seconds,
                                          language: out.detectedLanguage?.rawValue,
                                          vuota: out.text.isEmpty,
                                          vuotaPrimaDelRecupero: empties > 0,
                                          lingua: forced?.rawValue ?? "auto",
                                          prompt: promptText != nil))
                    print(String(format: "[p%d %@] %.3fs lang=%@%@ %@", pass, clip.name, seconds,
                                 out.detectedLanguage?.rawValue ?? "?",
                                 empties > 0 ? " VUOTA-PRIMA-DEL-RECUPERO" : "",
                                 out.text.isEmpty ? "*** VUOTA ***" : out.text))
                }
            }
            // Prima di qualunque uscita: vedi `WhisperCppTranscriber.shutdown()`.
            cpp?.shutdown()
            if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(fileURLWithPath: args[i + 1]))
                print("scritto \(args[i + 1]) — \(rows.count) righe")
            }
        } catch {
            FileHandle.standardError.write(Data("selftest-engine: \(error)\n".utf8))
            exit(1)
        }
        #else
        print("ERROR: engines not compiled in — rebuild with ./Scripts/build-app.sh")
        exit(1)
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --selftest-vocab <corpus.json> [--terms a,b,c]`
//
// The negative pole for the vocabulary repair, and the reason it can ship. The
// failure it has to be measured against is not the missed name — it is the
// rescorer of 2026-07-31 that turned "nella sala grande" into "nella sala
// Claude". So the probe runs the repair over a whole corpus of ordinary
// dictations and PRINTS EVERY CHANGE, because a rate is not evidence: the only
// way to know a repair is right is to read the ones it made.
//
// No MLX, no model: pure text, so it runs in a second.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-vocab") {
    let args = CommandLine.arguments
    let path = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !path.isEmpty, !path.hasPrefix("--") else {
        print("usage: Kalamos --selftest-vocab <corpus.json> [--terms Kalamos,Claude,…]")
        exit(2)
    }
    let terms: [String]
    if let i = args.firstIndex(of: "--terms"), i + 1 < args.count {
        terms = args[i + 1].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    } else {
        terms = Vocabulary.terms
    }
    let minFuzzy = args.firstIndex(of: "--min-fuzzy").flatMap {
        $0 + 1 < args.count ? Int(args[$0 + 1]) : nil
    } ?? VocabularyRepair.minFuzzyLength
    struct Entry: Codable { let raw: String?; let text: String?; let clean: String? }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        print("vocabolario (\(terms.count)): \(terms.joined(separator: ", "))")
        print("corpus: \(entries.count) voci da \(path) · min-fuzzy=\(minFuzzy)\n")
        var changed = 0, seen = 0
        for entry in entries {
            for field in [entry.raw, entry.text, entry.clean].compactMap({ $0 }) where !field.isEmpty {
                seen += 1
                let out = VocabularyRepair.apply(to: field, terms: terms,
                                                 minFuzzyLength: minFuzzy)
                guard out != field else { continue }
                changed += 1
                print("PRIMA: \(field)")
                print("DOPO : \(out)\n")
            }
        }
        print("— \(changed) testi cambiati su \(seen) —")
        print("Ogni riga qui sopra va LETTA: un tasso non è una prova.")
        // `--out` writes every text, repaired or not, so a second measurement can
        // score the result instead of re-implementing the repair in another
        // language and measuring that one by mistake.
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
            struct Pair: Codable { let before: String; let after: String }
            let pairs = entries.flatMap { entry in
                [entry.raw, entry.text, entry.clean].compactMap { $0 }.filter { !$0.isEmpty }
                    .map { Pair(before: $0, after: VocabularyRepair.apply(
                        to: $0, terms: terms, minFuzzyLength: minFuzzy)) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(pairs).write(to: URL(fileURLWithPath: args[i + 1]))
            print("scritto \(args[i + 1]) — \(pairs.count) coppie")
        }
    } catch {
        FileHandle.standardError.write(Data("selftest-vocab: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// `Kalamos --selftest-combo <corpus.json>` — the negative pole for KeyCombos.
//
// Same shape as --selftest-vocab and for the same reason: the failure that costs
// something is not the missed shortcut, it is the ordinary sentence that gets a
// plus it never asked for. So the rule runs over a whole corpus of real
// dictations and prints EVERY change, to be read one by one.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-combo") {
    let args = CommandLine.arguments
    let path = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !path.isEmpty, !path.hasPrefix("--") else {
        print("usage: Kalamos --selftest-combo <corpus.json>")
        exit(2)
    }
    struct Entry: Codable { let raw: String?; let text: String?; let clean: String? }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var changed = 0, seen = 0
        for entry in entries {
            for field in [entry.raw, entry.text, entry.clean].compactMap({ $0 }) where !field.isEmpty {
                seen += 1
                let out = KeyCombos.apply(to: field)
                guard out != field else { continue }
                changed += 1
                print("PRIMA: \(field)")
                print("DOPO : \(out)\n")
            }
        }
        print("— \(changed) testi cambiati su \(seen) —")
        print("Ogni riga qui sopra va LETTA: un tasso non è una prova.")
    } catch {
        FileHandle.standardError.write(Data("selftest-combo: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// `Kalamos --bench-clean <input.json> --out <results.json> [--arm-b <prompt.txt>]
//          [--repeat N] [--terminal]`
//
// The measuring instrument for the cleanup prompt. One process, model loaded
// once, so a 200-dictation corpus is minutes instead of the ~20 s model load ×
// 200 that a loop over `--clean` would pay.
//
// Two design rules, both inherited from the engine bench that got them wrong
// first (03-Plans/kalamos-motori):
//   · ARMS ALTERNATE per item, never in blocks. A block design once reported
//     "+15% slower" that was thermal drift dumped entirely on the second arm.
//   · The warm-up result is DISCARDED, so lazy compilation is not charged to
//     whichever arm happened to go first.
//
// Both arms go through `MLXFormatter.format`, i.e. the real path with the real
// guards, and the only difference between them is the system string. The exact
// string each arm used is written into the results so the numbers can be
// reproduced without this binary.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--bench-clean") {
    let args = CommandLine.arguments
    let inputPath = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !inputPath.isEmpty, !inputPath.hasPrefix("--") else {
        print("usage: Kalamos --bench-clean <input.json> --out <results.json> [--arm-b <prompt.txt>] [--repeat N] [--terminal]")
        exit(2)
    }
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let outPath = value("--out") else {
        print("--out <results.json> is required")
        exit(2)
    }
    let repeats = Int(value("--repeat") ?? "1") ?? 1
    let armBPath = value("--arm-b")

    struct BenchItem: Codable { let id: String; let lang: String; let raw: String }
    struct BenchRow: Codable {
        let id: String, arm: String, rep: Int, raw: String, out: String
        let seconds: Double, fellBack: Bool, rejection: String?
        let promptTokens: Int?, promptSeconds: Double?
        let generatedTokens: Int?, generateSeconds: Double?
    }

    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            let items = try JSONDecoder().decode([BenchItem].self, from: data)
            // Arm B is a whole system prompt read from disk; arm A is whatever
            // the app ships today. Nothing else differs.
            let armB = armBPath.flatMap {
                try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let arms: [(name: String, prompt: String?)] =
                armB == nil ? [("current", nil)] : [("current", nil), ("candidate", armB)]

            let bundle = args.contains("--terminal") ? "com.googlecode.iterm2" : nil
            let formatter = MLXFormatter(engine: .shared)
            func context(_ lang: String, _ prompt: String?) -> FormattingContext {
                FormattingContext(language: Language(rawValue: lang) ?? .italian,
                                  frontmostBundleID: bundle, promptOverride: prompt)
            }

            // What every arm saw, verbatim, for the record. The vocabulary is
            // read from THIS process's defaults domain, which is not the app's —
            // so it is written down rather than assumed.
            let vocab = MLXFormatter.vocabularyLine
            // No frontmost app in a headless run, so the tone is the neutral one
            // — the same line a dictation into an app with no tone rule gets.
            let neutralTone = MLXFormatter.toneLine(for: .neutral)
            var systemStrings: [String: String] = [
                "current": MLXFormatter.builtInPrompt(
                    language: Language.italian.displayName, toneLine: neutralTone, vocabLine: vocab)
            ]
            if let armB {
                systemStrings["candidate"] = MLXFormatter.compose(override: armB, vocabLine: vocab)
            }

            FileHandle.standardError.write(Data(
                "bench: \(items.count) items × \(arms.count) arms × \(repeats) rep — vocabulary: \(Vocabulary.terms.count) terms\n".utf8))

            // Warm-up, discarded.
            if let first = items.first {
                _ = await formatter.format(first.raw, context: context(first.lang, nil))
                _ = await MainActor.run { CleanupReport.shared.take() }
                FileHandle.standardError.write(Data("warm-up done\n".utf8))
            }

            var rows: [BenchRow] = []
            for rep in 1...max(1, repeats) {
                for (i, item) in items.enumerated() {
                    // Rotate the running order per item so no arm sits in the
                    // same thermal slot twice.
                    let shift = (i + rep) % arms.count
                    for arm in Array(arms[shift...] + arms[..<shift]) {
                        let t0 = Date()
                        let out = await formatter.format(
                            item.raw, context: context(item.lang, arm.prompt))
                        let seconds = Date().timeIntervalSince(t0)
                        let rejection = await MainActor.run { CleanupReport.shared.take() }
                        let stats = await MLXEngine.shared.lastStats
                        rows.append(BenchRow(
                            id: item.id, arm: arm.name, rep: rep, raw: item.raw, out: out,
                            seconds: seconds, fellBack: rejection != nil, rejection: rejection,
                            promptTokens: stats?.promptTokens, promptSeconds: stats?.promptSeconds,
                            generatedTokens: stats?.generatedTokens,
                            generateSeconds: stats?.generateSeconds))
                    }
                    if (i + 1) % 10 == 0 {
                        FileHandle.standardError.write(Data("  \(i + 1)/\(items.count) (rep \(rep))\n".utf8))
                    }
                }
            }

            struct BenchFile: Codable {
                let systemPrompts: [String: String]
                let vocabularyTerms: [String]
                let rows: [BenchRow]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(BenchFile(systemPrompts: systemStrings,
                                         vocabularyTerms: Vocabulary.terms,
                                         rows: rows))
                .write(to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath) — \(rows.count) rows")
        } catch {
            FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8))
            exit(1)
        }
        #else
        print("ERROR: MLX not compiled in — rebuild with ./Scripts/build-app.sh")
        exit(1)
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --edit "instruction" --on "text" [--lang it|en|fr]` runs Edit Mode on
// one piece of text. Same reasoning as --clean, plus one more: Edit Mode normally
// needs Accessibility to read your selection, so this is the only way to judge it
// before granting a permission.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--edit") {
    let args = CommandLine.arguments
    let instruction = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    let onIndex = args.firstIndex(of: "--on")
    let selection = onIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    guard !instruction.isEmpty, !instruction.hasPrefix("--"), !selection.isEmpty else {
        print("usage: Kalamos --edit \"make it shorter\" --on \"the text to rewrite\" [--lang it|en|fr]")
        exit(2)
    }
    var language = Language.english
    if let l = args.firstIndex(of: "--lang"), l + 1 < args.count,
       let parsed = Language(rawValue: args[l + 1].lowercased()) {
        language = parsed
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        print(await MLXEditor(engine: .shared)
            .transform(instruction: instruction, selection: selection, language: language))
        #else
        print("ERROR: MLX not compiled in — rebuild with ./Scripts/build-app.sh")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// Headless diagnostic: `Kalamos --selftest-translate` loads the local LLM and
// translates a fixed Italian sentence to English, printing the result or error.
// Used to isolate translation failures from the GUI/permissions layer.
if CommandLine.arguments.contains("--selftest-translate") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        do {
            FileHandle.standardError.write(Data("Loading Qwen + translating…\n".utf8))
            let translator = MLXTranslator(engine: .shared)
            let out = try await translator.translate(
                "Ciao, come stai oggi? Spero che tu stia bene.", from: .italian, to: .english)
            print("RESULT: \(out)")
        } catch {
            print("ERROR: \(error)")
        }
        #else
        print("ERROR: MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --selftest-archive` — prove the dictation archive writes real files.
//
// ISC-161. It exists because the only other way to watch the archive work is to
// speak into the app, and the person who needed to see it was away from the Mac.
// It goes through the SAME functions a dictation uses, into the SAME folder,
// reads back what landed, and cleans up after itself.
if CommandLine.arguments.contains("--selftest-archive") {
    let sr = 16_000.0
    let tone = (0..<Int(sr * 2)).map { 0.02 * sin(Float($0) * 0.05) }
    print("cartella: \(DictationArchive.directory.path)")
    print("tetto configurato: \(Tuning.keepLastDictations)")

    // Fixed past dates, one second apart, so the pruning has something to sort
    // and this probe can never collide with a real dictation's filename.
    var written: [URL] = []
    for i in 0..<25 {
        let when = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
        guard let url = DictationArchive.keep(tone, startedAt: when, sampleRate: sr) else {
            print("✗ keep ha restituito nil alla \(i)-esima"); exit(1)
        }
        DictationArchive.annotate(url, lines: ["prova \(i)", "GREZZO:", "ciao", "CONSEGNATO:", "Ciao."])
        written.append(url)
    }

    let fm = FileManager.default
    let survivors = written.filter { fm.fileExists(atPath: $0.path) }
    let sidecars = written.filter {
        fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("txt").path)
    }
    print("scritte 25 · sopravvissute al taglio: \(survivors.count) wav, \(sidecars.count) txt")

    // The NEWEST must survive and the OLDEST must not. A cap that kept the wrong
    // twenty would pass a count check and be useless.
    let newestKept = fm.fileExists(atPath: written.last!.path)
    let oldestGone = !fm.fileExists(atPath: written.first!.path)
    print(newestKept ? "✓ la più recente è rimasta" : "✗ la più recente è stata cancellata")
    print(oldestGone ? "✓ la più vecchia è stata tolta" : "✗ la più vecchia è ancora lì")
    if let sample = survivors.last { print("da controllare fuori da qui: \(sample.path)") }

    let ok = survivors.count == Tuning.keepLastDictations && newestKept && oldestGone
    if CommandLine.arguments.contains("--tieni") {
        print("⚠ file di prova LASCIATI sul disco (--tieni)")
    } else {
        for url in written {
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("txt"))
        }
        print("✓ file di prova rimossi")
    }
    exit(ok ? 0 : 1)
}

// Headless diagnostic for the cleanup prompt (#1 corrections, #3 lists, no-reply).
if CommandLine.arguments.contains("--selftest-cleanup") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        let f = MLXFormatter(engine: .shared)
        let ctx = FormattingContext(language: .english, frontmostBundleID: nil)
        for t in ["let's meet at 2, actually 3",
                  "shopping list one apples two bananas three oranges",
                  "i invited marco lucia and tom to dinner",
                  "what time is it in tokyo"] {
            let out = await f.format(t, context: ctx)
            print("IN:  \(t)\nOUT: \(out)\n")
        }
        #else
        print("MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// Headless diagnostic for punctuation restoration on long run-on dictations:
// `Kalamos --selftest-punct [--model <mlx-id>]`. Runs the LLM cleanup on the exact
// real-world run-ons that came out unpunctuated (kalamos.log 2026-07-15) and prints
// IN/OUT plus a punctuation-mark count, flagging when the model ECHOES the input
// unchanged. Lets us measure whether a given model / prompt actually restores
// internal commas & periods before wiring a model picker into the UI.
if CommandLine.arguments.contains("--selftest-punct") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        let args = CommandLine.arguments
        let engine: MLXEngine
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
            engine = MLXEngine(modelID: args[i + 1])
            FileHandle.standardError.write(Data("Model: \(args[i + 1])\n".utf8))
        } else {
            engine = .shared
            FileHandle.standardError.write(Data("Model: default (\(MLXEngine.defaultModelID))\n".utf8))
        }
        let f = MLXFormatter(engine: engine)
        let ctx = FormattingContext(language: .italian, frontmostBundleID: nil)
        let cases = [
            "il tool kalamos che abbiamo sviluppato non inserisce correttamente la pinteggiatura dobbiamo trovare una soluzione",
            // The hard case: a long run-on with no internal punctuation at all.
            // Whisper returns speech like this whenever the speaker does not pause.
            "allora per l'organizzazione di sabato pensavo che potremmo trovarci tutti al parcheggio verso le nove e mezza così chi arriva prima aspetta gli altri e poi partiamo insieme con due macchine invece di quattro se qualcuno non riesce ad arrivare in tempo ci avvisa il giorno prima e vediamo se conviene spostare tutto al pomeriggio tenendo conto che il posto chiude alle sette e che l'ultimo ingresso è mezz'ora prima quindi non ha senso arrivare dopo le sei",
            // Context-disambiguation probes: the SAME token "costa" must be
            // capitalized when context makes it a surname (a recipient) and left
            // lowercase when it is the ordinary verb. Expected: "…a Costa." vs
            // "…quanto costa…".
            "per il turno di domani sera il messaggio va inviato a costa e poi si aspetta la conferma",
            "sinceramente non ho idea di quanto costa una cosa del genere di questi tempi",
            // Self-correction: "anzi" RETRACTS → drop the abandoned clause.
            "ho praticamente letto il testo che mi hai dato e questa è la risposta anzi questo è l'output",
            // Self-correction with "cioè no" → keep only the restated value.
            "allora ci vediamo domani alle due cioè no facciamo alle tre davanti al bar",
            // GUARD: "anzi" only REINFORCES here → both clauses must stay.
            "il risultato non è male anzi è decisamente ottimo per essere il primo tentativo",
        ]
        func marks(_ s: String) -> Int { s.filter { ",.;:!?".contains($0) }.count }
        for t in cases {
            let out = await f.format(t, context: ctx)
            let echo = out.trimmingCharacters(in: .whitespacesAndNewlines)
                == t.trimmingCharacters(in: .whitespacesAndNewlines)
            print("IN  (\(marks(t)) marks): \(t)")
            print("OUT (\(marks(out)) marks)\(echo ? " [ECHO — UNCHANGED]" : ""): \(out)\n")
        }
        #else
        print("MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --cache-probe` — where does the cleanup second actually go?
//
// The system prompt is identical on every dictation, so caching it is an obvious
// idea. Whether it is worth the complexity depends on one number nobody had
// measured: what fraction of the time is spent READING the prompt versus WRITING
// the answer. A prompt cache removes the first and cannot touch the second.
//
// Real dictations of increasing length through the real cleanup path, warm model,
// first result discarded. The `mlx:` line in the log carries the split.
if CommandLine.arguments.contains("--cache-probe") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        let f = MLXFormatter(engine: .shared)
        let ctx = FormattingContext(language: .italian, frontmostBundleID: nil)
        let cases = [
            "confermo",
            "allora senti facciamo così domani mattina ci vediamo alle nove e mezza in ufficio",
            "una cosa che mi piacerebbe fare è che gli esercizi che necessitano di un tempo ad esempio la plank come tu dici quarantacinque secondi di plank e quel quarantacinque anzi no vorrei che venga aggiunto un tempo legato all'esercizio che si veda in quel caso",
            "allora per l'organizzazione di sabato pensavo che potremmo trovarci tutti al parcheggio verso le nove e mezza così chi arriva prima aspetta gli altri e poi partiamo insieme con due macchine invece di quattro se qualcuno non riesce ad arrivare in tempo ci avvisa il giorno prima e vediamo se conviene spostare tutto al pomeriggio tenendo conto che il posto chiude alle sette e che l'ultimo ingresso è mezz'ora prima quindi non ha senso arrivare dopo le sei",
        ]
        FileHandle.standardError.write(Data("warm-up (scartato)…\n".utf8))
        _ = await f.format(cases[0], context: ctx)
        for t in cases {
            let t0 = Date()
            _ = await f.format(t, context: ctx)
            print(String(format: "%3d parole dettate → %.2fs totali",
                         t.split(separator: " ").count, Date().timeIntervalSince(t0)))
        }
        print("\nLa spaccatura prompt/generazione è nelle righe `mlx:` di kalamos.log")
        #else
        print("MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// Headless diagnostic for Edit Mode: `Kalamos --selftest-edit`. Runs the on-device
// transformer on sample (instruction, selection) pairs and prints the result, so
// the transform path is verifiable without the GUI / Accessibility selection read.
if CommandLine.arguments.contains("--selftest-edit") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        let editor = MLXEditor(engine: .shared)
        let cases: [(instr: String, sel: String)] = [
            ("rendilo più formale", "ciao senti ti volevo dire che il turno di domani non riesco a farlo"),
            ("traducilo in inglese", "il messaggio va inviato a Costa e poi si aspetta la conferma"),
            ("fallo più corto", "volevo semplicemente chiederti se per caso avresti un momento libero nel pomeriggio di domani per fare due chiacchiere"),
        ]
        for c in cases {
            let out = await editor.transform(instruction: c.instr, selection: c.sel, language: .italian)
            print("INSTR: \(c.instr)")
            print("SEL  : \(c.sel)")
            print("OUT  : \(out)\n")
        }
        #else
        print("MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// Headless diagnostic for the rule-based formatter (no model needed):
// `Kalamos --selftest-format`. Verifies context-aware spoken punctuation —
// "punto" as a full stop vs. "punto" the word.
if CommandLine.arguments.contains("--selftest-format") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let f = RuleBasedFormatter()
        let it = FormattingContext(language: .italian, frontmostBundleID: nil)
        // (input, must-contain [case-insensitive], must-NOT-contain)
        let cases: [(String, String, String?)] = [
            ("il punto 4 è importante", "punto 4", nil),          // word before digit kept
            ("vediamo il punto di vista", "punto di vista", nil), // fixed phrase kept
            ("ho finito il lavoro punto", "lavoro.", "punto"),    // real full stop
            ("prendi il latte punto poi torna", "latte. poi", "punto poi"), // mid full stop
            ("al punto in cui siamo", "al punto", nil),           // determiner → word kept
        ]
        var fails = 0
        for (input, must, forbidden) in cases {
            let out = await f.format(input, context: it)
            let lower = out.lowercased()
            let ok = lower.contains(must.lowercased())
                && (forbidden == nil || !lower.contains(forbidden!.lowercased()))
            if !ok { fails += 1 }
            print("\(ok ? "✅" : "❌") IN:  \(input)\n    OUT: \(out)")
        }
        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED")
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// Headless diagnostic for replacement rules: `Kalamos --selftest-corrections`.
// Non-destructive — adds a uniquely-named test rule and removes it after.
if CommandLine.arguments.contains("--selftest-corrections") {
    let w = "rosi"
    Corrections.add(wrong: w, correct: "Rossi")
    let cases: [(String, String)] = [
        ("ho visto rosi oggi", "ho visto Rossi oggi"),  // whole word + casing
        ("ROSI corre veloce", "Rossi corre veloce"),    // case-insensitive match
        ("la rosicchiata", "la rosicchiata"),           // word boundary: no partial hit
    ]
    var fails = 0
    for (input, expected) in cases {
        let out = Corrections.apply(to: input)
        let ok = out == expected
        if !ok { fails += 1 }
        print("\(ok ? "✅" : "❌") IN:  \(input)\n    OUT: \(out)\n    EXP: \(expected)")
    }
    Corrections.remove(wrong: w)   // clean up — never touches the user's real rules
    print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED")
    exit(0)
}

// `--scatta=<file.png>` — photograph a window of this app and quit.
//
// It exists because the livery now has two faces, and "it looks fine" is not a
// claim anyone can check afterwards. Two rules paid for elsewhere are built in:
// it renders in a REAL window (an offscreen host draws no system material — a
// sidebar comes out white and empty), and it takes the picture with
// `screencapture`, because what a view draws for itself is not what the window
// server composites on screen.
//
// It deliberately does NOT start the app: no event tap, no hotkey, no model
// warm-up, nothing that would fight the running Kalamos. It builds the window and
// nothing else. `--dark` and `--light` force the appearance, so the night face can
// be looked at in the afternoon.
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--scatta=") }),
   let path = flag.split(separator: "=", maxSplits: 1).last.map(String.init) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if CommandLine.arguments.contains("--dark") {
        app.appearance = NSAppearance(named: .darkAqua)
    } else if CommandLine.arguments.contains("--light") {
        app.appearance = NSAppearance(named: .aqua)
    }

    // `--correzione[=parola]` — the ⌃⌥K panel, with or without its prefill. Both
    // states have to be looked at: the whole point of the prefill is what the
    // window looks like the instant it opens.
    // `--menu [--stato=<idle|ascolto|scrivo|errore>]` — il pannello in testa al menu della barra.
    //
    // Un `NSMenu` aperto non è una finestra di questa app, quindi `screencapture -l` non lo vede e
    // l'unico modo di guardarlo sarebbe cliccarci sopra a mano. La sonda disegna la stessa vista in
    // una finestra vera, con la carta sotto: nel menu il pannello sta invece sul materiale del
    // menu, ma la cosa da giudicare è la relazione fra il titolo, lo stato e la riga di sotto, e
    // quella è identica. `--stato` esiste perché a riposo l'accento non si vede mai, ed è proprio
    // l'unico colore del pannello.
    if CommandLine.arguments.contains("--menu") {
        let status: DictationStatus
        switch CommandLine.arguments.first(where: { $0.hasPrefix("--stato=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init) {
        case "ascolto":  status = .listening
        case "scrivo":   status = .transcribing
        case "errore":   status = .error(L.t("microfono occupato", "microphone busy",
                                             "micro occupé"))
        default:         status = .idle
        }
        let state = AppState.shared
        let language = state.autoDetectLanguage
            ? L.t("lingua automatica", "language detected", "langue automatique")
            : state.defaultLanguage.displayName
        // Il conteggio arriva dalla cronologia vera, così la sonda mostra la riga che vedrebbe LUI
        // aprendo il menu, non quella del primo giorno.
        let content = MenuPanel.Content(
            status: status,
            phrase: L.statusPhrase(status),
            detail: MenuPanel.Content.detail(
                dictationCount: TranscriptHistory.shared.entries.count,
                hint: MenuPanel.Content.triggerHint(
                    key: HotkeyManager.displayName(for: state.hotKeyCode),
                    mode: state.triggerMode),
                engine: state.speechEngine.title,
                language: language))
        // La stessa vista e la stessa misura del menu vero, non una copia: `MenuPanel.host` è dove
        // sta la regola sull'ordine fra larghezza e altezza, e una sonda che se la riscrivesse
        // finirebbe per fotografare un pannello che nell'app non esiste.
        let sheet = MenuPanel.host(content)
        // **Niente zona di sicurezza qui.** Con `.fullSizeContentView` la finestra dichiara i trenta
        // punti della barra del titolo come area da evitare, e SwiftUI spinge il pannello sotto:
        // nella fotografia era una fascia vuota in cima che nel menu non esiste — un difetto della
        // sonda, scambiato per un difetto del pannello finché non l'ho misurato.
        sheet.safeAreaRegions = []
        let size = sheet.frame.size
        sheet.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: sheet.frame,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = sheet
        // La misura si impone DOPO aver messo il contenuto: passata al costruttore vale per la
        // finestra intera, la barra del titolo se ne prende trenta punti, e la fotografia esce con
        // una fascia vuota in cima che nel menu non esiste. Una sonda che aggiunge un difetto suo è
        // peggio di nessuna sonda.
        window.setContentSize(size)
        // La carta la mette la finestra, non il pannello: nel menu vero sotto c'è il materiale del
        // menu, e dipingerla dentro la vista significherebbe fotografare qualcosa che nel menu non
        // c'è.
        window.backgroundColor = Theme.paperNS
        window.setFrameOrigin(NSPoint(x: 240, y: 420))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    } else if let flag = CommandLine.arguments.first(where: { $0 == "--correzione" || $0.hasPrefix("--correzione=") }) {
        let value = flag.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let halves = value.split(separator: ">", maxSplits: 1).map(String.init)
        CorrectionWindow.shared.show(heard: halves.first ?? "",
                                     written: halves.count > 1 ? halves[1] : "") { _, _ in }
    } else if CommandLine.arguments.contains("--onboarding") {
        // The one screen that has no second chance: whoever installs the app sees it
        // once. Its actions are all no-ops here — nothing asks for a permission and
        // nothing is written down, so the probe can neither pop a system prompt at
        // somebody's desk nor move the settings of the Kalamos they are using.
        //
        // `--passo=<n>` opens it at a given page. Without it the probe could only
        // ever photograph the first one, which is how a page ends up checked by
        // reading its source instead of by looking at it.
        if let n = CommandLine.arguments.first(where: { $0.hasPrefix("--passo=") })?
            .split(separator: "=", maxSplits: 1).last.flatMap({ Int($0) }) {
            OnboardingView.probeStep = n
        }
        OnboardingWindow.shared.show(state: AppState.shared, actions: OnboardingActions(
            applyTriggerKey: { _ in }, applyTriggerMode: { _ in },
            applyRecommendation: { _ in },
            requestMicrophone: { _ in }, requestAccessibility: {},
            openMicrophoneSettings: {}, finish: {}))
    } else {
        // `--sezione=words` (dictation | cleanup | words | advanced). Without it
        // the probe could only ever photograph the FIRST screen, which is why
        // ISC-112 — a list running off the bottom of the third one — stayed a
        // diagnosis read out of the source instead of something anybody saw.
        if let h = CommandLine.arguments.first(where: { $0.hasPrefix("--altezza=") })?
            .split(separator: "=", maxSplits: 1).last.flatMap({ Double($0) }) {
            PreferencesView.probeHeight = CGFloat(h)
        }
        let sezione = CommandLine.arguments
            .first { $0.hasPrefix("--sezione=") }
            .flatMap { $0.split(separator: "=", maxSplits: 1).last.map(String.init) }
            .flatMap(PreferencesView.Section.init(rawValue:)) ?? .dictation
        PreferencesWindow.shared.show(state: AppState.shared, actions: PreferencesActions(
            apply: { _ in }, isLaunchAtLogin: { false },
            showDiagnostics: {}, rerunOnboarding: {}), openAt: sezione)
    }

    // Il rettangolo della finestra in coordinate schermo, pronto da passare a
    // `screencapture -R`.
    //
    // Serve perché il permesso Registrazione dello schermo segue l'IDENTITÀ del codice: una
    // ricompilazione cambia il binario e il diritto decade in silenzio, quindi la sonda si trova a
    // non poter scattare la propria finestra mentre il terminale che l'ha lanciata può benissimo.
    // Stampato qui, chi ha il diritto scatta esattamente questa area senza indovinare le coordinate
    // e senza che nessuno debba concedere un permesso nuovo.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let screen = w.screen ?? NSScreen.main else { return }
        let f = w.frame
        let top = screen.frame.maxY - f.maxY
        FileHandle.standardError.write(Data("""
            scatta -R: \(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))
            scatta -l: \(w.windowNumber)

            """.utf8))
    }

    // `--attesa=<secondi>` holds the window open before the shutter. Two seconds
    // is enough to photograph a screen that just sits there, and not enough to
    // photograph one you have to OPERATE first — a list only proves it scrolls
    // once somebody has scrolled it.
    let attesa = CommandLine.arguments
        .first { $0.hasPrefix("--attesa=") }
        .flatMap { $0.split(separator: "=", maxSplits: 1).last.map(String.init) }
        .flatMap(Double.init) ?? 2.0

    DispatchQueue.main.asyncAfter(deadline: .now() + attesa) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.styleMask.contains(.titled)
        }) else {
            FileHandle.standardError.write("scatta: no window\n".data(using: .utf8)!)
            exit(2)
        }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        try? shot.run()
        shot.waitUntilExit()

        // Print the path only if there IS a picture at it.
        //
        // `screencapture` writes nothing and still exits 0 when this bundle lacks
        // Screen Recording — which is what a freshly downloaded copy of the app
        // always lacks, since the grant follows the code identity. The probe then
        // printed a filename that did not exist and returned success: a
        // verification tool reporting evidence it never produced, which is worse
        // than one that fails. Found on 2026-08-02, checking a release artifact.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard bytes > 0 else {
            FileHandle.standardError.write(Data("""
                scatta: no file written to \(path)
                   screencapture exited \(shot.terminationStatus) — the usual cause is that THIS
                   bundle has no Screen Recording permission (the grant follows the code
                   identity, so a downloaded or rebuilt copy starts without it).
                   System Settings ▸ Privacy & Security ▸ Screen Recording.

                """.utf8))
            exit(3)
        }
        print(path)
        exit(0)
    }
    app.run()
}

// One Kalamos. Never two.
//
// The build script assembles into `build/Kalamos.app` and then copies that into
// `/Applications`, and for months it left the staging copy behind. Spotlight
// indexes both, so "Kalamos" offered two results, and both got run without
// knowing: two global event taps on the same key, one dictation typed TWICE.
// Nothing about that looks like two apps — it looks like a broken app.
//
// The script no longer leaves the second bundle, but a copy can come back a
// dozen ways: a stale build, a Downloads copy, a Time Machine restore. So the
// second instance refuses to run, and says where the first one is — which is the
// one fact that would have explained the double text immediately.
//
// The check runs ONLY from inside a bundle: the plain SwiftPM binary has no
// bundle identifier, and the `--scatta` probe is meant to run alongside the live
// app. Both paths exit above this line anyway.
if let bundleID = Bundle.main.bundleIdentifier {
    let mine = ProcessInfo.processInfo.processIdentifier
    func otherInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != mine }
    }
    // Wait a moment first: `Scripts/build-app.sh` kills the old copy and opens
    // the new one immediately, and a process that has been asked to quit is
    // still in the list for a beat. Refusing to start there would break every
    // rebuild.
    var other = otherInstance()
    var waited = 0.0
    while other != nil, waited < 3.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        waited += 0.15
        other = otherInstance()
    }
    if let other {
        let where_ = other.bundleURL?.path ?? "?"
        Log.write("second instance refused — already running from \(where_)")
        let alert = NSAlert()
        alert.messageText = L.t("Kalamos è già in funzione",
                                "Kalamos is already running",
                                "Kalamos est déjà en cours")
        alert.informativeText = L.t(
            "Ne sta girando una copia da:\n\(where_)\n\nDue copie insieme scrivono ogni dettatura due volte, quindi questa si chiude. Cercala nella barra dei menu.",
            "A copy is running from:\n\(where_)\n\nTwo copies at once type every dictation twice, so this one is closing. Look for it in the menu bar.",
            "Une copie est en cours depuis :\n\(where_)\n\nDeux copies écrivent chaque dictée deux fois ; celle-ci se ferme. Cherchez-la dans la barre des menus.")
        alert.addButton(withTitle: "OK")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        other.activate()
        exit(0)
    }
}

// Kalamos entry point.
// A menu-bar-only app: `.accessory` keeps it out of the Dock and app switcher.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
