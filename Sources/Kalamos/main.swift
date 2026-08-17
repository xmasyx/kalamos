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

// `Kalamos --selftest-mic [seconds]` — watch the capture graph live, once a second.
//
// Built for the 2026-08-14 EarPods case: start it, then plug or unplug the
// headphones (or flip the default input device) and read what happens. On the
// broken build samples stopped growing after the swap — or the app died; on the
// fixed one the log says the graph was rebuilt and the counter keeps climbing.
// The run loop is pumped between reads because the route-change handler lands
// on the main queue — a sleeping main thread would be the deadlock this file
// already documents at the top.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-mic") {
    let args = CommandLine.arguments
    let seconds = flagIndex + 1 < args.count ? Int(args[flagIndex + 1]) ?? 10 : 10
    let recorder = AudioRecorder()
    do { try recorder.start() } catch {
        print("✗ start: \(error)")
        exit(1)
    }
    print("in ascolto per \(seconds)s — stacca/attacca le cuffie adesso")
    var last = 0
    var everFroze = false
    for i in 1...seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let n = recorder.currentSamples().count
        let grew = n > last
        if !grew { everFroze = true }
        print(String(format: "%3ds  campioni=%9d  %@", i, n, grew ? "cresce" : "FERMO"))
        last = n
    }
    let out = recorder.stop()
    let dur = Double(out.count) / AudioRecorder.targetSampleRate
    print(String(format: "totale: %d campioni (%.1fs) · dead=%@ · heardSpeech=%@",
                 out.count, dur,
                 AudioRecorder.isDead(out) ? "sì" : "no",
                 recorder.heardSpeech ? "sì" : "no"))
    exit(everFroze ? 1 : 0)
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
    // Le due manopole del taglio di coda, per rispondere alla domanda che il
    // registro non può: le parole perse le ha tolte il taglio, oppure non le ha
    // mai dette il decodificatore?
    if let f = args.first(where: { $0.hasPrefix("--cuscino=") }),
       let secondi = Double(f.dropFirst("--cuscino=".count)) {
        WhisperKitTranscriber.probeTrimPad = Int(secondi * 16_000)
        FileHandle.standardError.write(Data("  · cuscino \(secondi) s\n".utf8))
    }
    if args.contains("--senza-taglio") {
        WhisperKitTranscriber.probeTrimOff = true
        FileHandle.standardError.write(Data("  · taglio di coda SPENTO\n".utf8))
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
            // `--senza-copertura` spegne la riparazione ISC-174 per la durata di
            // questo banco. Serve a misurare il TAGLIO da solo: con le forbici
            // accese quella riparazione si riaccende dentro ogni pezzo, e i due
            // effetti finivano sommati in una colonna sola (referto del 16/08,
            // rilievo del principale dopo la consegna).
            if args.contains("--senza-copertura") {
                whisper?.repairsCoverage = false
                FileHandle.standardError.write(Data("ISC-174 spenta per questo banco\n".utf8))
            }
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
                // Dal 2026-08-08 anche WhisperKit ha questo canale, quindi il
                // banco deve poterlo esercitare: senza questa riga il confronto
                // fra i due motori misurerebbe uno col vocabolario e uno senza.
                whisper?.setVocabulary(voci)
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
// `--bench-archivio <N>` — quanto costa aprire il pannello con N registrazioni.
//
// L'archivio oggi ne tiene 138 e il tetto è 100000, quindi la domanda «l'elenco
// regge?» non si può rispondere sul disco vero: si risponde su un archivio finto
// della taglia che quel tetto permette. Misura le DUE metà separatamente, perché
// hanno destini diversi — l'elenco dei nomi blocca l'apertura della finestra, la
// lettura dei contenuti no, e confonderle porterebbe a ottimizzare quella che non
// si vede.
//
// Chiama le funzioni VERE su una cartella temporanea. Un banco che riscrive
// l'elencazione misura la propria copia (2026-08-05, gli elenchi del compendio).
// `--corpus` — mette da parte adesso le coppie corrette, e dice dove sono.
//
// Lo stesso codice del bottone nel pannello, raggiungibile senza aprire niente:
// serve il giorno che il fine-tuning parte da uno script e non dalle sue mani.
if CommandLine.arguments.contains("--corpus") {
    let written = TrainingCorpus.export()
    print("coppie messe da parte adesso: \(written)")
    print("totale nella cartella: \(TrainingCorpus.exportedCount())")
    print("cartella: \(TrainingCorpus.folder.path)")
    exit(0)
}

// `--sonda-taglio [<file.wav>]` — il taglio di coda sui suoi file veri.
//
// Senza un file prende l'archivio delle dettature e ordina per taglio decrescente,
// che è il modo in cui si trova un difetto che compare in cinque file su
// venticinque. Con un file solo stampa anche il profilo d'energia intorno al punto
// di taglio, che è dove si vede PERCHÉ.
if CommandLine.arguments.contains("--sonda-taglio") {
    let args = CommandLine.arguments
    let esplicito = args.first { $0.hasSuffix(".wav") }
    let cartella = DictationArchive.directory
    let files: [URL] = esplicito.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] }
        ?? ((try? FileManager.default.contentsOfDirectory(at: cartella,
                                                          includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.path > $1.path }

    guard !files.isEmpty else {
        FileHandle.standardError.write(Data("sonda-taglio: nessun wav in \(cartella.path)\n".utf8))
        exit(2)
    }
    let limite = args.first { $0.hasPrefix("--ultimi=") }
        .flatMap { Int($0.dropFirst("--ultimi=".count)) } ?? 120
    var referti: [SondaTaglio.Referto] = []
    for f in files.prefix(esplicito == nil ? limite : 1) {
        if let r = ((try? SondaTaglio.misura(f)) ?? nil) { referti.append(r) }
    }
    print("file esaminati: \(referti.count) · soglia di guardia \(WhisperKitTranscriber.trimSospetto) s")
    print("speechFloor \(AudioRecorder.speechFloor) · silenceRMS \(AudioSplit.silenceRMS) · frazione \(WhisperKitTranscriber.trimFraction)\n")
    for r in referti.sorted(by: { $0.tagliato > $1.tagliato }).prefix(esplicito == nil ? 25 : 1) {
        print(SondaTaglio.Referto.riga(r))
    }

    let tagli = referti.map(\.tagliato).sorted()
    if tagli.count > 1 {
        print(String(format: "\nmediana %.2f s · massimo %.2f s · sopra %.1f s: %d su %d",
                     tagli[tagli.count / 2], tagli.last ?? 0, WhisperKitTranscriber.trimSospetto,
                     tagli.filter { $0 >= WhisperKitTranscriber.trimSospetto }.count, tagli.count))
        var conteggio: [String: Int] = [:]
        for r in referti { conteggio[r.termine, default: 0] += 1 }
        print("termine che ha comandato la soglia: " +
              conteggio.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: " · "))
    }
    // Il profilo intorno al taglio, per il file singolo: è lì che si vede se sotto
    // la soglia ci fosse parlato o rumore di stanza.
    if esplicito != nil, let url = files.first, let s = try? SondaTaglio.campioni(di: url) {
        let e = SondaTaglio.energie(s)
        let picco = e.map(\.valore).max() ?? 0
        let soglia = WhisperKitTranscriber.trimSoglia(picco)
        let ultima = e.last(where: { $0.valore >= soglia })?.start ?? 0
        print("\nprofilo d'energia attorno al taglio — una riga ogni 100 ms")
        print("  t(s)     rms   sopra soglia")
        for f in e where f.start % (WhisperKitTranscriber.trimHop * 10) == 0 {
            let t = Double(f.start) / 16_000
            guard t >= Double(ultima) / 16_000 - 3.0 else { continue }
            print(String(format: "  %5.2f  %.5f   %@%@", t, f.valore,
                         f.valore >= soglia ? "sì" : "no",
                         f.start == ultima ? "   ← ultima sopra soglia" : ""))
        }
    }
    exit(0)
}

// `--sonda-guadagno [<file.wav>]` — il volume oltre l'originale, misurato.
//
// Due numeri per ognuna delle cinque quote: il **picco in uscita** (mai sopra
// 0 dBFS, che è il vincolo del brief) e la **distorsione armonica**, misurata
// facendo passare un seno puro dalla stessa `Guadagno.applica` che suona nel
// pannello — non da una copia della formula.
//
// Senza un file usa il PIÙ FORTE dell'archivio, che è il caso duro: su una
// registrazione già alta è lì che un guadagno mal fatto satura.
if CommandLine.arguments.contains("--sonda-guadagno") {
    let esplicito = CommandLine.arguments.first { $0.hasSuffix(".wav") }
    let cartella = DictationArchive.directory
    var url: URL?
    var campioni: [Float] = []
    if let e = esplicito {
        url = URL(fileURLWithPath: (e as NSString).expandingTildeInPath)
        campioni = (try? SondaTaglio.campioni(di: url!)) ?? []
    } else {
        // Il più forte, cercato sul disco invece che scelto a mano.
        let wav = ((try? FileManager.default.contentsOfDirectory(at: cartella,
                                                                 includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.path > $1.path }.prefix(120)
        var migliorePicco: Float = 0
        for f in wav {
            guard let s = try? SondaTaglio.campioni(di: f), !s.isEmpty else { continue }
            let p = s.map { abs($0) }.max() ?? 0
            if p > migliorePicco { migliorePicco = p; url = f; campioni = s }
        }
    }
    guard let url, !campioni.isEmpty else {
        FileHandle.standardError.write(Data("sonda-guadagno: nessun audio leggibile\n".utf8))
        exit(2)
    }
    func dBFS(_ x: Float) -> Double { x <= 0 ? -.infinity : 20 * log10(Double(x)) }

    /// La distorsione armonica totale, su un seno a 1 kHz al livello di picco del
    /// file. Un DFT su undici righe basta e avanza: le frequenze si conoscono
    /// esatte, quindi cercarle una per una è più preciso di una FFT su una
    /// finestra che nessuna delle due sceglie bene.
    func thd(picco: Float, dB: Float) -> Double {
        let sr = 16_000.0, f0 = 1_000.0, n = 16_000        // un secondo esatto
        let seno = (0 ..< n).map { picco * Float(sin(2 * .pi * f0 * Double($0) / sr)) }
        let out = Guadagno.applica(seno, dB: dB)
        func ampiezza(_ k: Int) -> Double {
            var re = 0.0, im = 0.0
            for i in 0 ..< n {
                let t = 2 * Double.pi * f0 * Double(k) * Double(i) / sr
                re += Double(out[i]) * cos(t); im -= Double(out[i]) * sin(t)
            }
            return (re * re + im * im).squareRoot() * 2 / Double(n)
        }
        let fondamentale = ampiezza(1)
        guard fondamentale > 0 else { return 0 }
        let armoniche = (2...10).map { ampiezza($0) * ampiezza($0) }.reduce(0, +)
        return armoniche.squareRoot() / fondamentale * 100
    }

    let piccoIn = campioni.map { abs($0) }.max() ?? 0
    print("file: \(url.lastPathComponent) · \(campioni.count) campioni · picco d'ingresso \(String(format: "%.4f (%.1f dBFS)", piccoIn, dBFS(piccoIn)))")
    print("ginocchio del limitatore \(Guadagno.ginocchio) · massimo \(Guadagno.massimoDB) dB\n")
    let spazio = Guadagno.spazio(picco: piccoIn)
    print(String(format: "spazio di questo file: %+.1f dB (bersaglio %.2f)\n", spazio, Guadagno.bersaglio))
    print("  quota   dB    ×ampiezza   picco uscita      THD su seno al picco")
    var passa = true
    for q in Guadagno.quote {
        let dB = Guadagno.dB(perQuota: q, spazio: spazio)
        let out = Guadagno.applica(campioni, dB: dB)
        let picco = out.map { abs($0) }.max() ?? 0
        let d = thd(picco: piccoIn, dB: dB)
        if picco > 1.0 { passa = false }
        print(String(format: "  %4d%%  %+5.1f   ×%6.2f   %.4f (%+6.2f dBFS)   %6.3f%%",
                     q, dB, Guadagno.lineare(dB: dB), picco, dBFS(picco), d))
    }
    // **Il polo negativo, e dice una cosa precisa: è la SCALA a evitare la
    // distorsione, non il limitatore.** Lo zero per cento di THD qui sopra
    // significa che il limitatore non entra mai in funzione, il che è il disegno
    // giusto — la distorsione si previene scegliendo un guadagno che il file
    // regge — ma andrebbe letto come «il limitatore funziona», che è falso. Questa
    // riga mostra cosa succederebbe col guadagno fisso di prima: lo stesso file
    // sfonda, e di quanto.
    let fisso = campioni.map { $0 * Guadagno.lineare(dB: Guadagno.massimoDB) }
    let piccoFisso = fisso.map { abs($0) }.max() ?? 0
    let limitato = Guadagno.applica(campioni, dB: Guadagno.massimoDB)
    let piccoLimitato = limitato.map { abs($0) }.max() ?? 0
    print(String(format: """

                 polo negativo — col guadagno FISSO di prima (%.0f dB, uguale per tutti):
                   senza limitatore  picco %7.3f (%+7.2f dBFS) %@
                   col limitatore    picco %7.3f (%+7.2f dBFS) → mai sopra 0, ma è lì che nasceva la distorsione
                 """,
                 Guadagno.massimoDB, piccoFisso, dBFS(piccoFisso),
                 piccoFisso > 1 ? "→ sfonda" : "→ non sfonda: file troppo piano per il confronto",
                 piccoLimitato, dBFS(piccoLimitato)))
    exit(passa && piccoLimitato <= 1.0 ? 0 : 6)
}

if let i = CommandLine.arguments.firstIndex(of: "--bench-archivio") {
    let n = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 20000 : 20000
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("kalamos-bench-\(n)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let body = """
    durata audio: 20.6s · microfono aperto: 20.7s
    lingua: it

    GREZZO:
    per lifeos da vedere i gestionali che avevamo sviluppato e dimmi se possiamo integrarlo con questo

    CONSEGNATO:
    Per LifeOS da vedere i gestionali che avevamo sviluppato e dimmi se possiamo integrarlo con questo.
    """
    // Un nome per secondo a partire da una data fissa: i nomi devono essere veri
    // timbri, altrimenti `stems` li scarta tutti e il banco misura una cartella
    // vuota dichiarandosi velocissimo.
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    for k in 0..<n {
        let stamp = fmt.string(from: base.addingTimeInterval(Double(k)))
        let wav = dir.appendingPathComponent("\(stamp).wav")
        FileManager.default.createFile(atPath: wav.path, contents: Data())
        try? body.write(to: dir.appendingPathComponent("\(stamp).txt"),
                        atomically: true, encoding: .utf8)
    }

    var t = Date()
    let rows = DictationIndex.stems(in: dir)
    let listing = Date().timeIntervalSince(t)

    t = Date()
    for r in rows { _ = DictationIndex.details(of: r.wav) }
    let hydration = Date().timeIntervalSince(t)

    print(String(format: "archivio finto: %d file · elenco nomi %.0f ms · lettura contenuti %.0f ms (%.2f ms/file)",
                 rows.count, listing * 1000, hydration * 1000,
                 rows.isEmpty ? 0 : hydration * 1000 / Double(rows.count)))
    try? FileManager.default.removeItem(at: dir)
    exit(0)
}

// `Kalamos --punct-status` — il modello di punteggiatura è sul disco, integro?
// Stampa percorso e verdetto della verifica di taglia, esce 0 se pronto, 1 se no.
// `Kalamos --punct-download` — lo scarica (pinnato alla revisione verificata).
if CommandLine.arguments.contains("--punct-status") {
    print("percorso: \(PunctuationModel.modelDir.path)")
    print(PunctuationModel.isDownloaded
        ? "punteggiatura veloce: sul disco e integro (taglie verificate)"
        : "punteggiatura veloce: NON scaricato (o incompleto)")
    exit(PunctuationModel.isDownloaded ? 0 : 1)
}
if CommandLine.arguments.contains("--punct-download") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            try await PunctuationModel.download { f in
                FileHandle.standardError.write(Data(String(format: "\r%.0f%%", f * 100).utf8))
            }
            print("\nscaricato e verificato: \(PunctuationModel.modelDir.path)")
        } catch {
            FileHandle.standardError.write(Data("\nscaricamento fallito: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

// `Kalamos --bench-l1 <items.json> --out <out.json> [--model <mlmodelc>] [--tokenizer <dir>]`
// — le sole etichette del modello, sugli item del banco: il gate di equivalenza
// con `risultati/l1c.json` (i campi `out` devono coincidere parola per parola).
//
// `Kalamos --bench-i5w <items.json> <metro.jsonl> --out <out.json> [--model …] [--tokenizer …]`
// — l'intera politica I5W sugli stessi item: il gate di parità coi numeri del
// banco (85,9/78,4/91,2 · 91,5% sul metro d'autore). I due comandi esistono
// perché l'innesto si prova PRIMA contro il banco e POI si consegna: un
// innesto non equivalente è un altro modello, non quello misurato.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--bench-l1")
    ?? CommandLine.arguments.firstIndex(of: "--bench-i5w") {
    let args = CommandLine.arguments
    let vuoleI5W = args[flagIndex] == "--bench-i5w"
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let itemsPath = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    let metroPath = vuoleI5W && flagIndex + 2 < args.count ? args[flagIndex + 2] : ""
    guard !itemsPath.isEmpty, !itemsPath.hasPrefix("--"),
          let outPath = value("--out"), !(vuoleI5W && metroPath.isEmpty) else {
        print("usage: Kalamos --bench-l1 <items.json> --out <out.json> [--model <mlmodelc>] [--tokenizer <dir>]")
        print("       Kalamos --bench-i5w <items.json> <metro.jsonl> --out <out.json> [--model <mlmodelc>] [--tokenizer <dir>]")
        exit(2)
    }

    struct L1Item: Codable { let id: String; let spoglio: String }
    struct L1Row: Codable { let id: String; let out: String; let seconds: Double }

    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let items = try JSONDecoder().decode(
                [L1Item].self, from: Data(contentsOf: URL(fileURLWithPath: itemsPath)))
            // `originale` = il testo di Whisper, da cui I5W eredita segni e maiuscole.
            var grezzoDi: [String: String] = [:]
            if vuoleI5W {
                for riga in try String(contentsOf: URL(fileURLWithPath: metroPath), encoding: .utf8)
                    .split(separator: "\n") where !riga.isEmpty {
                    if let obj = try JSONSerialization.jsonObject(with: Data(riga.utf8)) as? [String: Any],
                       let id = obj["id"] as? String, let orig = obj["originale"] as? String {
                        grezzoDi[id] = orig
                    }
                }
            }
            try await PunctuationModel.shared.prepare(
                modelURL: value("--model").map { URL(fileURLWithPath: $0) },
                tokenizerDir: value("--tokenizer").map { URL(fileURLWithPath: $0) })

            var rows: [L1Row] = []
            for it in items {
                let parole = it.spoglio.split(separator: " ").map(String.init)
                let t0 = Date()
                let etichette = try await PunctuationModel.shared.etichette(perParole: parole)
                let out: String
                if vuoleI5W {
                    guard let grezzo = grezzoDi[it.id] else {
                        FileHandle.standardError.write(Data("manca l'originale di \(it.id)\n".utf8))
                        exit(4)
                    }
                    out = PunctuationHybrid.i5w(parole: parole, etichette: etichette, grezzo: grezzo)
                } else {
                    out = zip(parole, etichette)
                        .map { p, l in p + (l != "0" ? l : "") }
                        .joined(separator: " ")
                }
                rows.append(L1Row(id: it.id, out: out, seconds: Date().timeIntervalSince(t0)))
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(rows).write(to: URL(fileURLWithPath: outPath))
            print("scritte \(rows.count) righe in \(outPath)")
        } catch {
            FileHandle.standardError.write(Data("bench-l1: \(error)\n".utf8))
            exit(3)
        }
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
}

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

// `Kalamos --selftest-terminale <corpus.json> --out <results.json>`
//
// The terminal cleanup path, run over a corpus of REAL dictations with the
// frontmost app forced to iTerm. It exists because the question it answers has
// two poles and only one of them is interesting to look at: a handful of spoken
// self-corrections must be resolved, and every other dictation must come back
// word-identical. Measuring the first pole alone would call a prompt that
// rewrites everything a success.
//
// Nothing here re-implements the cleanup: it calls `MLXFormatter.format` on the
// real context, so the guard, the fallback and the prompt under test are the
// ones the app runs.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-terminale") {
    let args = CommandLine.arguments
    let path = flagIndex + 1 < args.count ? args[flagIndex + 1] : ""
    guard !path.isEmpty, !path.hasPrefix("--") else {
        print("usage: Kalamos --selftest-terminale <corpus.json> [--out results.json] [--solo-marcatori] [--generale]")
        exit(2)
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        #if canImport(MLXLLM)
        struct CorpusRow: Codable { let id: String, lang: String, raw: String; let marker: Bool }
        struct ResultRow: Codable {
            let id: String, lang: String, raw: String, out: String
            let marker: Bool, seconds: Double
        }
        do {
            var corpus = try JSONDecoder().decode(
                [CorpusRow].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            if args.contains("--solo-marcatori") { corpus = corpus.filter { $0.marker } }
            let f = MLXFormatter(engine: .shared)
            FileHandle.standardError.write(Data("corpus: \(corpus.count) dettature\n".utf8))
            var rows: [ResultRow] = []
            // `--generale` swaps the terminal for no app at all, which is how the
            // ordinary path is reached: not a terminal, not a code editor, neutral
            // tone. The same corpus can then be run through both prompts and the
            // difference is the prompt, not the material.
            let bundle: String? = args.contains("--generale") ? nil : "com.googlecode.iterm2"
            FileHandle.standardError.write(Data(
                "percorso: \(bundle == nil ? "generale" : "terminale")\n".utf8))
            for (i, c) in corpus.enumerated() {
                let ctx = FormattingContext(
                    language: Language(rawValue: c.lang) ?? .italian,
                    frontmostBundleID: bundle)
                let t0 = Date()
                let out = await f.format(c.raw, context: ctx)
                rows.append(ResultRow(id: c.id, lang: c.lang, raw: c.raw, out: out,
                                      marker: c.marker,
                                      seconds: Date().timeIntervalSince(t0)))
                if i % 25 == 0 {
                    FileHandle.standardError.write(Data("… \(i)/\(corpus.count)\n".utf8))
                }
            }
            if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(fileURLWithPath: args[i + 1]))
                print("scritto \(args[i + 1]) — \(rows.count) righe")
            }
        } catch {
            FileHandle.standardError.write(Data("selftest-terminale: \(error)\n".utf8))
            exit(1)
        }
        #else
        print("MLX not compiled in")
        #endif
        sem.signal()
    }
    waitServicingMainActor(sem)
    exit(0)
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
            // "virgola" has the same two lives, and it cost real dictations on
            // 2026-08-11: talking ABOUT commas, the word was eaten twice in one
            // minute. Both of these are his verbatim transcripts.
            ("arriva senza una sola virgola Ma in realtà", "sola virgola", nil),
            ("è uscito senza virgola l'audio di prima", "senza virgola", nil),
            ("questa è una virgola mobile", "virgola mobile", nil),  // fixed phrase kept
            // The positive pole: the command still has to work, or the "fix"
            // is just a deletion wearing a guard's clothes.
            ("questo è un test virgola poi vediamo", "test, poi", "virgola"),
        ]
        let en = FormattingContext(language: .english, frontmostBundleID: nil)
        let fr = FormattingContext(language: .french, frontmostBundleID: nil)
        // Same defect, other languages — enumerated because a class does not
        // stop at the language you happened to hit it in.
        let siblings: [(FormattingContext, String, String, String?)] = [
            (en, "there is not a single comma here", "single comma", nil),
            (en, "add milk comma bread and eggs", "milk, bread", "comma"),
            (fr, "il arrive sans une seule virgule ici", "seule virgule", nil),
            (fr, "prends le lait virgule puis reviens", "lait, puis", "virgule"),
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
        for (ctx, input, must, forbidden) in siblings {
            let out = await f.format(input, context: ctx)
            let lower = out.lowercased()
            let ok = lower.contains(must.lowercased())
                && (forbidden == nil || !lower.contains(forbidden!.lowercased()))
            if !ok { fails += 1 }
            print("\(ok ? "✅" : "❌") [\(ctx.language.rawValue)] IN:  \(input)\n    OUT: \(out)")
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

// `--isola[=notch|bolla]` e `--livello=0…1`, letti in un posto solo.
//
// Le due sonde dell'isola — la fotografia e il filmato — devono inquadrare la
// STESSA isola, altrimenti il fermo immagine e il movimento parlano di due cose
// diverse e nessuno se ne accorge.
func sondaIsola() -> (posizione: WavePosition, livello: Double) {
    let posizione = CommandLine.arguments
        .first { $0.hasPrefix("--isola=") }?
        .split(separator: "=", maxSplits: 1).last
        .flatMap { WavePosition(rawValue: $0 == "bolla" ? "bubble" : String($0)) } ?? .notch
    let livello = CommandLine.arguments
        .first { $0.hasPrefix("--livello=") }
        .flatMap { $0.split(separator: "=", maxSplits: 1).last.flatMap { Double($0) } } ?? 0.7
    // `--senza-bolla` fotografa l'isoletta con l'interruttore del guscio spento,
    // che è l'unico stato in cui dietro l'onda non c'è niente di disegnato. Passa
    // da `probeShell` e non dalle impostazioni, come la posizione: una sonda che
    // per fotografare uno stato deve METTERCI l'app lascia l'app com'era nella
    // fotografia.
    if CommandLine.arguments.contains("--senza-bolla") { WaveIsland.probeShell = false }
    return (posizione, livello)
}

/// La cornice di carta sotto l'isola, e il rettangolo da passare a `screencapture`.
///
/// Vale per la fotografia e per il filmato: la finestra va TENUTA VIVA da chi
/// chiama (alla prima prova era una `let` locale, ARC l'ha liberata e la
/// fotografia ha catturato il desktop di chi sviluppa).
///
/// La cornice si misura SULL'ISOLA e non su un numero fisso: il notch è 400×128,
/// l'isoletta è un cerchio di 112, e una cornice buona per il primo lascerebbe il
/// secondo come un puntino in mezzo a un foglio. Ottanta punti di carta per lato,
/// sempre, così le due fotografie si giudicano con lo stesso respiro intorno.
///
/// Le due misure escono su stderr perché chi misura i fotogrammi deve sapere dove
/// sta l'isola dentro l'immagine, e ricavarlo di nuovo nello script sarebbe la
/// sonda che riscrive la logica che deve misurare.
@MainActor
func cornicePerIsola(isola: CGSize) -> (fondo: NSWindow, rettangolo: String) {
    let cornice = NSRect(x: 0, y: 0, width: isola.width + 160, height: isola.height + 160)
    // **La carta è fatta come l'ISOLA, non come una finestra qualunque, e questo
    // è il pezzo che è costato mezza mattina il 2026-08-16.**
    //
    // Un livello alto vince sulle finestre, non sulle SCRIVANIE. Se davanti c'è
    // un'app a tutto schermo — un terminale, un browser — quella si prende una
    // scrivania sua, e una `NSWindow` normale a livello `.floating` resta
    // indietro: la si vede solo tornando alla scrivania di prima. Il filmato è
    // uscito così, con l'isola disegnata sopra il terminale di chi sviluppa, cioè
    // esattamente il difetto contro cui il fondo esiste — e la fotografia era
    // uscita pulita solo perché in quel momento davanti c'era la scrivania.
    //
    // Un pannello `.nonactivatingPanel` che sa raggiungere tutte le scrivanie ci
    // arriva, e lo sappiamo perché l'isola — che è fatta così — nel filmato
    // sbagliato si vedeva benissimo. Il livello sta UN GRADINO sotto quello
    // dell'isola invece di appoggiarsi all'ordine in cui si chiama
    // `orderFront`: fra due finestre dello stesso livello vince l'ultima
    // ordinata, che è una regola vera e invisibile, cioè la cosa che si rompe
    // il giorno che qualcuno inverte due righe.
    let fondo = NSPanel(contentRect: cornice, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    fondo.isFloatingPanel = true
    fondo.becomesKeyOnlyIfNeeded = true
    fondo.hidesOnDeactivate = false
    fondo.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    fondo.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    fondo.backgroundColor = Theme.paperNS
    fondo.isOpaque = true
    if let schermo = NSScreen.main {
        fondo.setFrameOrigin(NSPoint(x: schermo.visibleFrame.midX - cornice.width / 2,
                                     y: schermo.visibleFrame.midY - cornice.height / 2))
    }
    fondo.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    let f = fondo.frame
    let alto = (NSScreen.main?.frame.maxY ?? f.maxY) - f.maxY
    FileHandle.standardError.write(Data(
        "isola: \(Int(isola.width))x\(Int(isola.height)) punti · cornice: \(Int(cornice.width))x\(Int(cornice.height)) punti\n".utf8))
    return (fondo, "\(Int(f.origin.x)),\(Int(alto)),\(Int(f.width)),\(Int(f.height))")
}

// `--misura-onda` — quanto l'onda risponde alla voce, in numeri.
//
// Il difetto del 2026-08-16 («si muove poco quando parlo») è un difetto di
// RAPPORTO, e un rapporto non si vede in una fotografia né si risolve
// discutendo. Questa sonda stampa la banda verticale occupata a livelli
// crescenti, dentro il contenitore vero, e il rapporto fra un livello basso e
// uno alto. Il banco che conta è in `WaveIslandTests`; questa è la stessa misura
// da leggere a occhio quando si tocca la matematica.
if CommandLine.arguments.contains("--misura-onda") {
    let guscio = BubbleGeometry.size
    let riquadro = BubbleGeometry.waveSize(in: guscio)
    let profilo = BubbleGeometry.profile(box: riquadro, in: guscio)
    print("banda verticale dell'onda, dentro la pillola \(Int(guscio.width))×\(Int(guscio.height))")
    print("  livello   banda")
    var misure: [Double: Double] = [:]
    for livello in [0.0, 0.1, 0.2, 0.3, 0.5, 0.7, 1.0] {
        let banda = MisuraMoto.banda(livello: livello, profilo: profilo)
        misure[livello] = banda
        print(String(format: "  %5.2f    %.3f", livello, banda))
    }
    let basso = misure[0.1] ?? 0, alto = misure[0.7] ?? 0
    print(String(format: "\nrapporto 0,7 / 0,1 = %.2f× (serve ≥ 2,00×)", basso > 0 ? alto / basso : 0))
    exit(basso > 0 && alto >= basso * 2 ? 0 : 1)
}

// `--misura-filo=<file.png>` — il filo dell'onda tocca i due bordi del guscio?
//
// Sonda nata da una sua fotografia (2026-08-16): «le estremità dovrebbero essere
// connesse ai bordi». È il difetto che nessuna prova sul modello prende, perché
// la matematica dell'onda era già giusta e sbagliata era la larghezza della tela.
// Esce 0 se il filo arriva a tutt'e due i capi, 5 se si ferma prima.
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--misura-filo=") }),
   let path = flag.split(separator: "=", maxSplits: 1).last.map(String.init) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let sorgente = CGImageSourceCreateWithURL(url as CFURL, nil),
          let immagine = CGImageSourceCreateImageAtIndex(sorgente, 0, nil) else {
        FileHandle.standardError.write(Data("misura-filo: non si legge \(url.path)\n".utf8))
        exit(2)
    }
    guard let filo = MisuraMoto.filoAiBordi(di: immagine) else {
        FileHandle.standardError.write(Data("misura-filo: nessun guscio nell'immagine\n".utf8))
        exit(3)
    }
    print(String(format: "filo alla riga %d · vuoto a sinistra %d px · vuoto a destra %d px",
                 filo.riga, filo.vuotoSinistra, filo.vuotoDestra))
    print(filo.tocca ? "il filo tocca i due bordi" : "il filo NON tocca i bordi")
    exit(filo.tocca ? 0 : 5)
}

// `--misura-filmato=<file.mov>` — l'isola misurata fotogramma per fotogramma.
//
// La colonna `largh` è quella con cui si giudica la discesa della goccia: la
// firma attesa è la larghezza quasi ferma nella prima metà, poi un'apertura
// rapida che passa oltre la misura a regime. Senza questa sonda quel giudizio
// resta «sembra una goccia», che è un'opinione su un file che nessuno riapre.
//
// Non apre finestre e non registra niente: legge un filmato già girato. Sta
// prima delle sonde che disegnano proprio per questo — si può misurare il
// filmato di ieri senza far comparire niente sullo schermo di nessuno.
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--misura-filmato=") }),
   let path = flag.split(separator: "=", maxSplits: 1).last.map(String.init) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("misura-filmato: non c'è \(url.path)\n".utf8))
        exit(2)
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let righe = try await MisuraMoto.misura(filmato: url)
            guard !righe.isEmpty else {
                FileHandle.standardError.write(Data("misura-filmato: nessun fotogramma leggibile\n".utf8))
                exit(3)
            }
            print(MisuraMoto.tabella(righe))
            print(MisuraMoto.firmaDellaDiscesa(righe))
            // Un fotogramma in cui non si distingue niente dallo sfondo è un
            // fotogramma in cui l'isola non c'è: normale prima dell'entrata e
            // dopo l'uscita, sospetto in mezzo. Il conto va stampato perché una
            // tabella tutta a zeri, senza questa riga, si legge come «misurato».
            let vuoti = righe.filter { $0.larghezza == 0 }.count
            print("fotogrammi senza isola: \(vuoti) su \(righe.count)")
            sem.signal()
            // `--goccia` trasforma la firma in un cancello: la stampa qui sopra
            // si legge, questo si conta. Senza il flag la sonda misura e basta,
            // perché l'entrata della pillola NON è una goccia e non deve esserlo.
            if CommandLine.arguments.contains("--goccia") {
                let goccia = MisuraMoto.discesaÈUnaGoccia(righe)
                print(goccia ? "la discesa è una goccia" : "la discesa NON è una goccia")
                exit(goccia ? 0 : 4)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("misura-filmato: \(error)\n".utf8))
            exit(1)
        }
    }
    sem.wait()
}

// `--sonda-pannello` — l'isola resta al suo posto quando cambia schermata?
//
// Il secondo difetto del 2026-08-16: «quando passo da una schermata all'altra, il
// notch resti persistente con l'onda che va, e non che compaia e scompaia...
// soprattutto con lo schermo intero dà problemi».
//
// **Non apre nessuna finestra**: costruisce il pannello vero e ne rilegge i
// permessi senza ordinarlo a schermo, così può girare mentre lui sta usando il
// Mac (MacAppRules §7 — le finestre di prova compaiono sullo Space attivo, cioè
// sotto le mani di chi lavora).
//
// **Due poli, e il negativo si fa sulla finestra viva invece che con un
// interruttore nel codice di produzione.** Prima si verifica il pannello com'è;
// poi gli si toglie `stationary` e si riverifica, e la seconda DEVE risultare
// rossa. Un codice che porta dentro di sé la leva per rompersi è una leva che un
// giorno resta tirata; togliere un flag a una finestra già costruita non lascia
// niente dietro di sé.
if CommandLine.arguments.contains("--sonda-pannello") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // `onDrag` iniettato a vuoto: il pannello vero, costruito senza che il solo
    // atto di costruirlo possa scrivere nelle sue impostazioni.
    let pannello = IslandPanel(island: WaveIsland.shared, state: AppState.shared, onDrag: { _ in })
    let vivo = SondaPannello.esamina(pannello)
    print("— il pannello com'è —")
    print(vivo.descrizione)
    print(vivo.passa ? "\n✓ l'isola sta su tutte le scrivanie, sopra il pieno schermo, e non scivola"
                     : "\n✗ mancano: \(vivo.mancanti.joined(separator: ", "))")

    // Il polo negativo: senza `stationary` la sonda deve accorgersene.
    pannello.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let rotto = SondaPannello.esamina(pannello)
    print("\n— polo negativo, tolto stationary —")
    print(rotto.passa ? "✗ la sonda dice ancora verde: non sta guardando i flag"
                      : "✓ rossa, e per il motivo giusto: mancante \(rotto.mancanti.joined(separator: ", "))")
    // Rimesso com'era: la sonda non lascia dietro di sé la finestra che ha rotto.
    pannello.collectionBehavior = IslandPanel.comportamentoPersistente
    exit(vivo.passa && !rotto.passa ? 0 : 8)
}

// `--misura-inviluppo` — il parlato scritto, fatto passare per l'inviluppo vero.
//
// La metà ARITMETICA del banco del pompaggio: nessuna finestra, nessun filmato,
// nessun permesso di registrazione dello schermo. Stampa campione per campione
// l'RMS del profilo, l'altezza dell'onda e lo scarto sillabico, e alla fine il
// rapporto fra minimo e massimo dentro il parlato — che è il criterio 1.
//
// **È la sonda da guardare quando il filmato dice rosso**, perché distingue le
// due cause che il filmato confonde: l'inviluppo che collassa davvero, e la
// misura sui pixel che non sta vedendo l'onda. Con `--taratura=prima` stampa il
// polo negativo, cioè il pompaggio della mattina del 16/08.
if CommandLine.arguments.contains("--misura-inviluppo") {
    var taratura: Taratura = CommandLine.arguments.contains("--taratura=prima") ? .diPrima : .viva
    // `--rilascio=<x>` — la manopola della coda, per la spazzata e per il
    // prima/dopo. Sostituisce SOLO il rilascio: cambiare anche tenuta o attacco
    // renderebbe illeggibile il confronto fra due giri.
    if let f = CommandLine.arguments.first(where: { $0.hasPrefix("--rilascio=") }),
       let x = Double(f.dropFirst("--rilascio=".count)) {
        taratura = taratura.con(rilascio: x)
    }
    let profilo = MisuraPompaggio.ProfiloParlato.self
    let muto = CommandLine.arguments.contains("--solo-coda")
    var lento = Inviluppo(), veloce = Inviluppo()
    var altezze: [Double] = []
    // La coda, contata sui campioni e non presa dalla formula. `Taratura.coda` è
    // la forma chiusa, questa è la stessa cosa misurata sul profilo vero: se le
    // due divergono, a sbagliare è la formula. È il confronto fra due misure
    // indipendenti che scopre il pezzo scritto due volte (2026-08-05).
    var ultimoAttacco = 0.0, altezzaAllUltimoAttacco = 0.0
    var scesoSotto: [Double: Double] = [:]
    let quote = [0.25, 0.05]
    var codaLivelli: [Double] = [], parlatoLivelli: [Double] = []

    if !muto { print("campione  t(s)     rms  obiettivo  altezza  dettaglio") }
    for n in 0..<Int(profilo.durata * WaveIsland.samplesPerSecond) {
        let t = Double(n) / WaveIsland.samplesPerSecond
        let rms = profilo.rms(campione: n)
        let obiettivo = WaveIsland.normalize(rms: rms, con: taratura)
        let precedente = lento.obiettivoPrecedente
        lento = lento.avanzato(verso: obiettivo, con: taratura)
        veloce = veloce.avanzato(verso: obiettivo, con: .sillabica)
        // Un attacco è l'obiettivo che sale: la stessa definizione che ri-arma la
        // tenuta dentro `Inviluppo`, letta da fuori invece che ricopiata.
        if obiettivo > precedente {
            ultimoAttacco = t
            altezzaAllUltimoAttacco = lento.livello
            scesoSotto = [:]
        }
        for q in quote where scesoSotto[q] == nil && altezzaAllUltimoAttacco > 0
            && lento.livello < altezzaAllUltimoAttacco * q {
            scesoSotto[q] = t - ultimoAttacco
        }
        let dentro = profilo.finestraParlata.contains(t)
        if dentro { altezze.append(lento.livello); parlatoLivelli.append(lento.livello) }
        if profilo.finestraCoda.contains(t) { codaLivelli.append(lento.livello) }
        if !muto {
            print(String(format: "  %5d  %5.2f  %6.4f     %6.3f   %6.3f     %+6.3f%@",
                         n, t, rms, obiettivo, lento.livello, veloce.livello - lento.livello,
                         dentro ? "  ←parlato" : ""))
        }
    }
    let minimo = altezze.min() ?? 0, massimo = altezze.max() ?? 1
    let tenuta = massimo > 0 ? minimo / massimo : 0
    print(String(format: "\ntaratura %@ · rilascio %.3f · tenuta %d campioni (%.2f s)",
                 taratura == .diPrima ? "DI PRIMA" : "viva",
                 taratura.rilascio, taratura.tenuta, taratura.secondiDiTenuta))
    print(String(format: "dentro il parlato: min %.3f · max %.3f · min/max %.3f (serve ≥ %.2f)",
                 minimo, massimo, tenuta, MisuraPompaggio.Soglia.tenuta))

    // La coda: il numero che lui guarda quando dice «si appiattisce troppo
    // rapidamente quando smetto di parlare».
    print("\ncoda dall'ultimo attacco — formula chiusa · misurata sul profilo")
    for q in quote {
        let previsto = taratura.coda(fino: q)
        let misurato = scesoSotto[q]
        print(String(format: "  sotto il %2.0f%%   %5.2f s   %@",
                     q * 100, previsto,
                     misurato.map { String(format: "%5.2f s  (scarto %+.2f s)", $0, $0 - previsto) }
                        ?? "mai raggiunto dentro il filmato"))
    }

    // La banda è quello che l'occhio vede: l'altezza è un numero interno, la
    // banda sono pixel. Passa dalla matematica dell'app (`MisuraMoto.banda`),
    // non da una copia di essa.
    let guscio = BubbleGeometry.size
    let riquadro = BubbleGeometry.waveSize(in: guscio)
    let sagoma = BubbleGeometry.profile(box: riquadro, in: guscio)
    func banda(_ livello: Double) -> Double { MisuraMoto.banda(livello: livello, profilo: sagoma) }
    let bandaParlata = parlatoLivelli.map(banda).reduce(0, +) / Double(max(1, parlatoLivelli.count))
    let bandaCoda = codaLivelli.map(banda).reduce(0, +) / Double(max(1, codaLivelli.count))
    print(String(format: """

                 banda nella coda del filmato (%.2f–%.2f s): %.3f · nel parlato assestato: %.3f
                 rapporto coda/parlato %.3f — il criterio 2 del banco misura il muto INIZIALE e
                 non questo, quindi qui la coda è RIFERITA e non giudicata (≤ %.2f per leggersi linea)
                 """,
                 profilo.finestraCoda.lowerBound, profilo.finestraCoda.upperBound,
                 bandaCoda, bandaParlata,
                 bandaParlata > 0 ? bandaCoda / bandaParlata : 1, MisuraPompaggio.Soglia.quiete))
    exit(tenuta >= MisuraPompaggio.Soglia.tenuta ? 0 : 7)
}

// `--misura-pompaggio=<file.mov>` — l'onda pompa su e giù mentre parla?
//
// La sonda del difetto del 2026-08-16: «si muove troppo troppo troppo, vibra
// tanto ed è fastidioso a vedersi». **La misura del filmato che c'era non poteva
// vederlo**, e non per un difetto suo: segue l'INGOMBRO dell'isola, che è il
// guscio, e il guscio è una pillola opaca di dimensione fissa. Un'onda piena e
// un'onda collassata a una riga danno lo stesso ingombro al pixel. Questa guarda
// dentro il guscio e misura la banda occupata dalla LUCE dell'onda.
//
// Si legge insieme a `--isola-filmato --profilo-parlato`, che gira il filmato con
// un parlato scritto: il difetto esiste solo mentre il volume si muove, quindi un
// livello costante non potrebbe mostrarlo.
//
// Esce 0 se i quattro criteri passano, 6 se almeno uno è rosso.
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--misura-pompaggio=") }),
   let path = flag.split(separator: "=", maxSplits: 1).last.map(String.init) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("misura-pompaggio: non c'è \(url.path)\n".utf8))
        exit(2)
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let righe = try await MisuraPompaggio.misura(filmato: url)
            guard !righe.isEmpty else {
                FileHandle.standardError.write(Data("misura-pompaggio: nessun fotogramma leggibile\n".utf8))
                exit(3)
            }
            if CommandLine.arguments.contains("--tabella") {
                print(MisuraPompaggio.tabella(righe))
            }
            guard let referto = MisuraPompaggio.referto(righe) else {
                // Distinto da «un criterio è rosso», e la differenza conta: qui
                // il filmato non contiene ciò che si voleva misurare — l'isola
                // non è mai arrivata, o è arrivata troppo tardi perché le
                // finestre del profilo cadano dentro la ripresa.
                // **Due cause diverse, e vanno separate qui**, o chi legge cerca
                // il guasto dalla parte sbagliata. Un filmato con pochi
                // fotogrammi è una RIPRESA morta — successo il 16/08 alle 19:05,
                // 82 fotogrammi su 330, con una spazzata lasciata girare in
                // sfondo e lo schermo che si è spento sotto. Un filmato lungo il
                // giusto ma senza onda è invece un problema di soggetto.
                let attesi = Int(MisuraPompaggio.ProfiloParlato.durata * 30)
                FileHandle.standardError.write(Data("""
                    misura-pompaggio: il filmato non contiene un parlato misurabile
                       \(righe.filter { $0.banda > 0 }.count) fotogrammi con onda su \(righe.count), attesi almeno \(attesi)
                       \(righe.count < attesi
                         ? "la RIPRESA è morta a metà: schermo spento, sessione bloccata o screencapture interrotto"
                         : "il filmato è lungo il giusto ma non contiene l'isola — girato con --profilo-parlato?")

                    """.utf8))
                exit(4)
            }
            print(referto.testo)
            sem.signal()
            exit(referto.passa ? 0 : 6)
        } catch {
            FileHandle.standardError.write(Data("misura-pompaggio: \(error)\n".utf8))
            exit(1)
        }
    }
    sem.wait()
}

/// La carta del filmato, tenuta in una variabile globale perché nessuna chiusura
/// la nomina e ARC non ha motivo di conservarla.
var filmFondo: NSWindow?

/// La scena della sonda degli spazi, tenuta viva per lo stesso motivo di
/// `filmFondo`: è la finestra che va a tutto schermo e produce la transizione.
var scenaSpazi: NSWindow?

// `--sonda-spazi` — «il notch resta fermo quando cambio pagina?»
//
// Vedi `Onda/SondaSpazi.swift` per il perché delle due misure. La transizione la
// produce `toggleFullScreen` su una finestra vera: è API pubblica, non chiede
// l'Accessibilità, e — cosa che i tasti sintetici NON fanno — genera davvero un
// `activeSpaceDidChange`.
//
//   --livello-isola=<n>   sonda l'isola a un livello diverso (25 = statusBar,
//                         1000 = screenSaver). È la manopola della spazzata.
//   --diagnosi            aggiunge il polo negativo: prova PRIMA i tasti
//                         sintetici, che devono NON produrre nessun cambio, poi
//                         il tutto schermo, che deve produrne. Senza i due poli
//                         «zero cambi» e «la sonda è rotta» sono lo stesso vuoto.
if CommandLine.arguments.contains("--sonda-spazi") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if let f = CommandLine.arguments.first(where: { $0.hasPrefix("--livello-isola=") }),
       let n = Int(f.dropFirst("--livello-isola=".count)) {
        WaveIsland.probeLivello = NSWindow.Level(rawValue: n)
    }
    let diagnosi = CommandLine.arguments.contains("--diagnosi")

    // `--variante=<n>` — le ipotesi sul perché il notch non resta fermo, una per
    // numero. La 0 è com'è l'app oggi, ed è il riferimento contro cui le altre si
    // leggono; la 3 è il controllo A/A che dice se `.stationary` stia facendo
    // qualcosa.
    var nomeVariante = "0 · com'è oggi"
    if let f = CommandLine.arguments.first(where: { $0.hasPrefix("--variante=") }),
       let n = Int(f.dropFirst("--variante=".count)) {
        switch n {
        case 1:
            nomeVariante = "1 · + animationBehavior = .none"
            WaveIsland.probeAnimazione = NSWindow.AnimationBehavior.none
        case 2:
            nomeVariante = "2 · senza fullScreenAuxiliary"
            WaveIsland.probeComportamento = [.canJoinAllSpaces, .stationary]
        case 3:
            nomeVariante = "3 · senza stationary (controllo A/A)"
            WaveIsland.probeComportamento = [.canJoinAllSpaces, .fullScreenAuxiliary]
        case 4:
            nomeVariante = "4 · moveToActiveSpace invece di canJoinAllSpaces"
            WaveIsland.probeComportamento = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        case 5:
            nomeVariante = "5 · tutto: niente animazione, non fluttuante, + ignoresCycle"
            WaveIsland.probeAnimazione = NSWindow.AnimationBehavior.none
            WaveIsland.probeFluttuante = false
            WaveIsland.probeComportamento = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                             .stationary, .ignoresCycle]
        default: break
        }
    }
    FileHandle.standardError.write(Data("  · variante \(nomeVariante)\n".utf8))

    var istanti: [SondaSpazi.Istante] = []
    SondaSpazi.cambiOsservati = 0
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { SondaSpazi.cambiOsservati += 1 } }

    // La scena: una finestra vera, grande, di carta, che va a tutto schermo. È il
    // motore della transizione E il fondo su cui l'isola si vede nel filmato.
    let scena = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
    scena.title = "sonda-spazi"
    scena.backgroundColor = Theme.paperNS
    scena.center()
    scena.makeKeyAndOrderFront(nil)
    scenaSpazi = scena
    app.activate(ignoringOtherApps: true)

    let misura = IslandPanel.size(for: .notch)
    let schermo = NSScreen.main ?? NSScreen.screens[0]
    let origine = NSPoint(x: schermo.frame.midX - misura.width / 2,
                          y: schermo.frame.maxY - misura.height)
    let avvio = Date()

    // Il registro, a 60 Hz. `Timer` e non un ciclo stretto: durante una
    // transizione di spazio il run loop è la cosa che deve continuare a girare, e
    // un ciclo che lo blocca misurerebbe una macchina ferma per colpa sua.
    let orologio = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard let pannello = WaveIsland.shared.pannelloVivo else { return }
            istanti.append(SondaSpazi.Istante(
                secondi: Date().timeIntervalSince(avvio),
                cornice: pannello.frame,
                compositore: SondaSpazi.compositore(numero: CGWindowID(pannello.windowNumber)),
                sullaScrivaniaAttiva: pannello.isOnActiveSpace,
                cambi: SondaSpazi.cambiOsservati))
        }
    }
    RunLoop.main.add(orologio, forMode: .common)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        WaveIsland.shared.showForProbe(level: 0.7, position: .notch, origin: origine, animated: true)
    }

    // Il POLO NEGATIVO, e viene prima apposta: se i tasti sintetici funzionassero,
    // il conteggio salirebbe qui e tutto il resto della sonda sarebbe da rileggere.
    if diagnosi {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let src = CGEventSource(stateID: .hidSystemState)
            for giù in [true, false] {
                if let e = CGEvent(keyboardEventSource: src, virtualKey: 124, keyDown: giù) {
                    e.flags = .maskControl
                    e.post(tap: .cghidEventTap)
                }
            }
            FileHandle.standardError.write(Data("  · ctrl-destra sintetico postato\n".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            FileHandle.standardError.write(Data("""
                  · cambi dopo i tasti sintetici: \(SondaSpazi.cambiOsservati) \
                \(SondaSpazi.cambiOsservati == 0 ? "(atteso 0 — il WindowServer li ignora)" : "(INATTESO: adesso funzionano)")\n
                """.utf8))
        }
    }

    // La finestra di assestamento dev'essere INTERA prima che succeda qualcosa: è
    // da lì che esce il riferimento, e un riferimento preso mentre la scena sta
    // già cambiando è il riferimento sbagliato.
    let assestamento = 2.0
    let quandoEntra = (diagnosi ? 4.0 : 2.0) + assestamento
    // `--tasti` — la transizione fra due SCRIVANIE, che è il caso delle sue
    // parole («quando cambio pagina»), invece del tutto schermo. Vive dietro un
    // flag e non è il default perché dipende da due cose che il tutto schermo non
    // chiede: l'Accessibilità concessa a questo binario, e che il WindowServer
    // accetti tasti sintetici per quella scorciatoia — che NON è garantito. Il
    // conteggio dei cambi è il cancello: zero cambi significa che la sonda non ha
    // misurato niente, e il referto lo dice invece di uscire verde.
    let conTasti = CommandLine.arguments.contains("--tasti")
    func premiSpazio(_ tasto: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let f = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: true) {
            f.type = .flagsChanged; f.flags = .maskControl; f.post(tap: .cghidEventTap)
        }
        for giù in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: tasto, keyDown: giù) {
                e.flags = .maskControl; e.post(tap: .cghidEventTap)
            }
        }
        if let f = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: false) {
            f.type = .flagsChanged; f.flags = []; f.post(tap: .cghidEventTap)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quandoEntra) {
        FileHandle.standardError.write(Data("  · \(conTasti ? "ctrl-destra" : "tutto schermo") →\n".utf8))
        if conTasti { premiSpazio(124) } else { scena.toggleFullScreen(nil) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quandoEntra + 3.5) {
        FileHandle.standardError.write(Data("  · \(conTasti ? "ctrl-sinistra" : "tutto schermo") ←\n".utf8))
        if conTasti { premiSpazio(123) } else { scena.toggleFullScreen(nil) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quandoEntra + 7.0) {
        orologio.invalidate()
        WaveIsland.shared.hideForProbe()
        let pannelloLivello = WaveIsland.probeLivello?.rawValue ?? IslandPanel.livelloPersistente.rawValue
        let referto = SondaSpazi.Referto(istanti: istanti, cambiDiSpazio: SondaSpazi.cambiOsservati,
                                         livello: pannelloLivello, assestamento: assestamento)
        print(referto.testo)
        // Le righe grezze, per chi vuole guardare l'istante della transizione.
        if CommandLine.arguments.contains("--tabella") {
            print("\n  t(s)   appkit-x  appkit-y   ws-x   ws-y  attiva  cambi")
            for i in istanti {
                print(String(format: "  %5.2f  %8.1f  %8.1f  %5@  %5@  %6@  %5d",
                             i.secondi, i.cornice.minX, i.cornice.minY,
                             i.compositore.map { String(format: "%.0f", $0.minX) } ?? "—",
                             i.compositore.map { String(format: "%.0f", $0.minY) } ?? "—",
                             i.sullaScrivaniaAttiva ? "sì" : "NO", i.cambi))
            }
        }
        exit(referto.passa ? 0 : 6)
    }
    app.run()
}

// `--isola-filmato=<file.mov>` — l'isola che ENTRA e che ESCE, filmata.
//
// **Un movimento non si verifica su un fotogramma.** `--scatta --isola` fotografa
// lo stato ASSESTATO, cioè l'unico istante in cui un'entrata a scatto e un'entrata
// fluida sono identiche: la fotografia non può dire niente sul difetto che
// l'animazione esiste per riparare. Il filmato è la sonda che risponde alla
// domanda giusta — la posizione e l'opacità avanzano un fotogramma per volta o in
// un salto solo? — e i fotogrammi si estraggono e si MISURANO, perché «sembra
// fluido» è un giudizio e non un dato.
//
// La scaletta è fissa, e la stampa su stderr insieme al rettangolo: chi estrae i
// fotogrammi sa dove guardare senza indovinare, e un cambio di tempi non lascia
// indietro uno script che cerca l'entrata dove non c'è più.
//
// Il ciclo è INTERO — entrata, un paio di secondi d'onda viva, uscita — perché il
// filmato non è solo la prova dell'animazione: è anche l'unico artefatto in cui si
// vede l'isola comportarsi. Il livello è sintetico e arriva dal flag, quindi
// l'onda si muove senza che nessun microfono si apra.
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--isola-filmato=") }),
   let path = flag.split(separator: "=", maxSplits: 1).last.map(String.init) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    if CommandLine.arguments.contains("--dark") {
        app.appearance = NSAppearance(named: .darkAqua)
    } else if CommandLine.arguments.contains("--light") {
        app.appearance = NSAppearance(named: .aqua)
    }
    let (posizione, livello) = sondaIsola()
    let misura = IslandPanel.size(for: posizione)
    let (fondo, rettangolo) = cornicePerIsola(isola: misura)
    // Tenuta viva per tutto il filmato, e non è prudenza. La stessa finestra
    // nella sonda della fotografia sopravvive solo perché le due chiusure la
    // nominano; qui l'ultimo uso è il calcolo dell'origine, cioè al secondo zero,
    // e da lì in poi niente la trattiene. Alla prima ripresa la carta è sparita a
    // metà filmato e sotto è ricomparso il terminale di chi sviluppa — lo stesso
    // guasto già pagato due volte il 2026-08-16, questa volta in movimento.
    filmFondo = fondo
    // Lo stesso giro di run loop della fotografia, e per lo stesso motivo: il
    // fondo dev'essere composto PRIMA che parta la registrazione, o i primi
    // fotogrammi sono lo schermo di chi sviluppa.
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))

    // `--profilo-parlato` gira il filmato del POMPAGGIO: al posto di un livello
    // costante, l'isola riceve il parlato scritto in `MisuraPompaggio` e dura
    // quanto serve a contenerlo. Senza il flag la scaletta è quella di sempre,
    // perché il giudizio sulla goccia dipende da questi tempi e non deve muoversi.
    let parlato = CommandLine.arguments.contains("--profilo-parlato")
    // `--taratura=prima` è il POLO NEGATIVO: gira lo stesso filmato con i numeri
    // della mattina del 2026-08-16, quelli che pompano. Il banco deve bocciarlo.
    // Passa da `probeTaratura` e non dalle impostazioni, come la posizione: una
    // sonda che per filmare uno stato deve METTERCI l'app la lascia com'era nel
    // filmato.
    if CommandLine.arguments.contains("--taratura=prima") { WaveIsland.probeTaratura = .diPrima }

    // La scaletta, in un posto solo.
    let entrata = 1.0
    let uscita = parlato ? entrata + MisuraPompaggio.ProfiloParlato.durata : 3.4
    let durata = parlato ? Int(uscita.rounded(.up)) + 1 : 5
    FileHandle.standardError.write(Data("""
        gira -R: \(rettangolo)
        scaletta: durata \(durata)s · entra \(entrata)s · esce \(String(format: "%.2f", uscita))s\
        \(parlato ? " · parlato scritto, taratura \(WaveIsland.probeTaratura == nil ? "viva" : "di prima")" : "")

        """.utf8))

    // `screencapture` si rifiuta di sovrascrivere, e un filmato di ieri
    // riletto come quello di oggi è il modo più silenzioso di sbagliare.
    try? FileManager.default.removeItem(atPath: path)
    let rec = Process()
    rec.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // `-R` non è inquadratura, è CONTENIMENTO: registra il rettangolo della
    // carta e nient'altro, così quello che c'è sul resto dello schermo — la sua
    // roba — non entra nel file nemmeno per un fotogramma. Il fondo copre il
    // dentro, il ritaglio toglie il fuori, e servono tutti e due.
    rec.arguments = ["-x", "-v", "-V\(durata)", "-R\(rettangolo)", path]
    do { try rec.run() } catch {
        FileHandle.standardError.write(Data("filmato: screencapture non parte — \(error)\n".utf8))
        exit(2)
    }

    let origine = NSPoint(x: fondo.frame.midX - misura.width / 2,
                          y: fondo.frame.midY - misura.height / 2)
    DispatchQueue.main.asyncAfter(deadline: .now() + entrata) {
        if parlato {
            WaveIsland.shared.showForProbe(profilo: { MisuraPompaggio.ProfiloParlato.rms(campione: $0) },
                                           position: posizione, origin: origine, animated: true)
        } else {
            WaveIsland.shared.showForProbe(level: livello, position: posizione,
                                           origin: origine, animated: true)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + uscita) {
        WaveIsland.shared.hideForProbe()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(durata) + 1.5) {
        rec.waitUntilExit()
        // Lo stesso cancello della fotografia: `screencapture` esce 0 senza
        // scrivere niente quando questo binario non ha Registrazione dello
        // schermo, e una sonda che annuncia una prova che non ha prodotto è
        // peggio di una sonda che fallisce.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard bytes > 0 else {
            FileHandle.standardError.write(Data("""
                filmato: nessun file scritto in \(path)
                   screencapture è uscito \(rec.terminationStatus) — di solito è il permesso
                   Registrazione dello schermo, che segue l'identità del codice.

                """.utf8))
            exit(3)
        }
        print(path)
        exit(0)
    }
    app.run()
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

    // Il fondo di carta di una sonda il cui soggetto NON è una finestra col titolo —
    // oggi solo `--isola`. Lo scatto qui sotto fotografa una finestra per numero, e
    // un pannello senza bordo non ha una barra del titolo da cui trovarlo: quando
    // c'è un fondo si scatta il suo RETTANGOLO, che è anche l'unico modo di tenere
    // dentro l'inquadratura la relazione fra il guscio e la pagina sotto.
    //
    // Tenuto vivo QUI e non nel ramo che lo crea. Alla prima prova era una `let`
    // locale: ARC l'ha liberata all'uscita dal ramo, la finestra è sparita senza un
    // errore, e la fotografia ha catturato quello che c'era dietro sullo schermo —
    // il desktop di chi sviluppa, che è esattamente ciò contro cui il fondo esiste.
    var sondaFondo: NSWindow?

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
    // `--menu-aperto` — il menu VERO della barra, aperto, con il pannello in testa e le voci sotto.
    //
    // È l'immagine che apre il README, quindi non può essere una ricostruzione: costruisce il menu
    // chiamando `setupMenuBar()` dell'app, poi clicca il proprio bottone nella barra. Il click apre
    // un ciclo modale che blocca questo processo, quindi la fotografia la scatta chi l'ha lanciato,
    // e le coordinate della barra escono su stderr prima del click.
    if CommandLine.arguments.contains("--menu-aperto") {
        // Uno sfondo neutro sotto il menu, e non è estetica: il menu di macOS è traslucido, quindi
        // qualunque cosa ci sia sullo schermo si intravede dentro la fotografia. Sul Mac di chi
        // sviluppa quella roba è il suo desktop, con i nomi delle sue cartelle. La carta dell'app
        // copre tutto e la fotografia mostra solo il menu.
        let backdrop = NSWindow(contentRect: NSScreen.main?.frame ?? .zero,
                                styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = Theme.paperNS
        backdrop.level = .normal
        backdrop.orderFront(nil)

        let delegate = AppDelegate()
        delegate.setupMenuBar()
        if let button = delegate.statusItem.button, let w = button.window {
            let f = w.frame
            let screen = w.screen ?? NSScreen.main
            let top = (screen?.frame.maxY ?? f.maxY) - f.maxY
            FileHandle.standardError.write(Data(
                "icona a: \(Int(f.origin.x)),\(Int(top)) larga \(Int(f.width))\n".utf8))
        }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            delegate.statusItem.button?.performClick(nil)
        }
        // Il ciclo modale del menu non restituisce il controllo, quindi la sonda si spegne da sola.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
        app.run()
    }

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
    } else if let flag = CommandLine.arguments.first(where: { $0 == "--verita" || $0.hasPrefix("--verita=") }) {
        // `--verita[=<file.wav>]` — il pannello ⌃⌥V, aperto sull'archivio vero.
        //
        // Prima passava un testo finto, perché il pannello mostrava una dettatura
        // sola e il testo era tutto quello che aveva dentro. Adesso il pannello È
        // l'archivio: elenco, filtri, ricerca, riascolto. Un archivio inventato
        // fotograferebbe una finestra che non esiste su nessun Mac, quindi la
        // sonda apre quello che c'è, e `=<file.wav>` sceglie su quale riga
        // atterrare. Il salvataggio è staccato: una sonda non scrive nell'archivio
        // di nessuno.
        let pick = flag.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        TruthWindow.shared.show(initial: pick ?? DictationArchive.latest) { _, _, _ in }
    } else if CommandLine.arguments.contains(where: {
        $0 == "--isola" || $0.hasPrefix("--isola=")
    }) {
        // `--isola[=notch|bolla] [--livello=0…1]` — l'isola dell'onda.
        //
        // Tre cose che questa sonda NON fa, e ognuna è il motivo per cui esiste in
        // questa forma. Non apre il microfono: il livello arriva dal flag, così si
        // fotografa un'onda alta senza registrare niente e senza litigare con la
        // Kalamos che sta girando. Non scrive nelle sue impostazioni: la posizione
        // passa da `WaveIsland.probePosition`, non da `AppState`, altrimenti la
        // prossima dettatura si troverebbe configurata dall'ultima fotografia. E
        // non la mette in cima allo schermo dov'è davvero, perché lì dentro
        // l'inquadratura ci sarebbe anche la sua barra dei menu, con le icone di
        // tutte le altre app: il guscio del notch si giudica dalla forma, non dalle
        // coordinate.
        //
        // Sotto ci va un fondo di CARTA, che è la stessa dell'app e quindi ha già
        // due facce: `--light` e `--dark` danno la pagina chiara e quella scura
        // senza un secondo colore scritto a mano. Senza fondo l'isola sarebbe un
        // PNG trasparente, cioè illeggibile proprio nella parte che conta — un'onda
        // di luce additiva su niente.
        let (posizione, livello) = sondaIsola()

        // La carta deve stare SOPRA le finestre delle altre app, non nel suo posto
        // naturale. Al primo tentativo era a livello `.normal` con `orderFront`, e
        // una finestra senza bordo di un'app appena avviata non passa davanti a
        // niente: la fotografia ha catturato il browser che c'era dietro, cioè
        // esattamente il difetto contro cui il fondo esiste. `.floating` più
        // `orderFrontRegardless` la mettono davanti a tutto tranne l'isola, che sta
        // a `.statusBar`, un livello più su. Costruita da `cornicePerIsola()`,
        // condivisa col filmato.
        let misura = IslandPanel.size(for: posizione)
        let (fondo, _) = cornicePerIsola(isola: misura)
        sondaFondo = fondo
        // Un giro di run loop, e non è prudenza: `orderFrontRegardless` più
        // `activate` sono RICHIESTE al window server, non fatti già avvenuti. Prima
        // che il ciclo girasse qui, con l'attesa predefinita di due secondi il
        // fondo non era ancora composto sullo schermo quando scattava l'otturatore,
        // e la fotografia usciva col desktop di chi sviluppa dietro un'isola
        // disegnata perfettamente — riprodotto due volte il 2026-08-16, e la
        // seconda con la ritenzione già a posto: il difetto non era il puntatore,
        // era il tempo. Con `--attesa=4` veniva pulita, cioè la sonda funzionava
        // solo per chi si ricordava un flag, che è il modo peggiore di funzionare.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // Niente `AppState.shared.status = .listening` qui: serviva a far dire alla
        // didascalia la frase giusta, e la didascalia è stata tolta il 2026-08-16.
        // L'onda da sola è il segnale, quindi la sonda non ha più uno stato da
        // preparare.
        WaveIsland.shared.showForProbe(
            level: livello, position: posizione,
            origin: NSPoint(x: fondo.frame.midX - misura.width / 2,
                            y: fondo.frame.midY - misura.height / 2))
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
        // `--anteprima=<notch|bolla>` — quale forma mostra l'anteprima della
        // pagina Onda. Un flag suo e non `--isola=`, che qui sopra dirotta la
        // sonda sull'isola vera: la pagina delle impostazioni e l'isola sono due
        // soggetti, e un flag che ne sceglie uno non può anche configurare
        // l'altro. Passa da `probePosition` e non da `AppState`, così la sonda
        // non riconfigura la Kalamos di nessuno.
        if let forma = CommandLine.arguments.first(where: { $0.hasPrefix("--anteprima=") })?
            .split(separator: "=", maxSplits: 1).last
            .map(String.init)
            .flatMap({ WavePosition(rawValue: $0 == "bolla" ? "bubble" : $0) }) {
            WaveIsland.probePosition = forma
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
        guard let screen = NSScreen.main else { return }
        if let r = sondaFondo?.frame {
            let top = screen.frame.maxY - r.maxY
            FileHandle.standardError.write(Data(
                "scatta -R: \(Int(r.origin.x)),\(Int(top)),\(Int(r.width)),\(Int(r.height))\n\n".utf8))
            return
        }
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) })
        else { return }
        let f = w.frame
        let top = (w.screen ?? screen).frame.maxY - f.maxY
        FileHandle.standardError.write(Data("""
            scatta -R: \(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))
            scatta -l: \(w.windowNumber)

            """.utf8))
    }

    // `--attesa=<secondi>` holds the window open before the shutter. Two seconds
    // is enough to photograph a screen that just sits there, and not enough to
    // photograph one you have to OPERATE first — a list only proves it scrolls
    // once somebody has scrolled it.
    let attesaChiesta = CommandLine.arguments
        .first { $0.hasPrefix("--attesa=") }
        .flatMap { $0.split(separator: "=", maxSplits: 1).last.map(String.init) }
        .flatMap(Double.init) ?? 2.0
    // Con un fondo sotto, l'attesa ha un PAVIMENTO. Due secondi bastano per una
    // finestra col titolo, che il sistema mette davanti da sé; una finestra senza
    // bordo di un'app appena avviata deve prima arrivare davanti a tutte le altre,
    // e se scatti prima fotografi quello che c'era sullo schermo. Il pavimento vale
    // anche per chi non passa il flag, che è il punto: la correttezza di una sonda
    // non può dipendere da cosa si ricorda chi la lancia.
    let attesa = sondaFondo == nil ? attesaChiesta : max(attesaChiesta, 4.0)

    DispatchQueue.main.asyncAfter(deadline: .now() + attesa) {
        // A rectangle when the subject is not a titled window, its window number
        // otherwise. `-l` is still the default because it crops exactly and cannot
        // pick up whatever else happens to be on screen.
        let soggetto: [String]
        if let r = sondaFondo?.frame, let screen = NSScreen.main {
            let top = screen.frame.maxY - r.maxY
            soggetto = ["-R\(Int(r.origin.x)),\(Int(top)),\(Int(r.width)),\(Int(r.height))"]
        } else if let window = NSApp.windows.first(where: {
            $0.isVisible && $0.styleMask.contains(.titled)
        }) {
            soggetto = ["-l\(window.windowNumber)"]
        } else {
            FileHandle.standardError.write("scatta: no window\n".data(using: .utf8)!)
            exit(2)
        }
        // La vecchia fotografia si toglie PRIMA di scattare, ed è il cancello qui
        // sotto a chiederlo. Trovato il 2026-08-16 rifacendo queste stesse quattro
        // foto: con lo schermo bloccato `screencapture` esce 0 senza scrivere
        // niente, il controllo «c'è un file e non è vuoto» trovava quella di ieri,
        // e la sonda stampava il percorso come se avesse scattato. Il cancello
        // esiste per non annunciare una prova mai prodotta, e su un percorso già
        // occupato faceva esattamente quello — anzi peggio, perché la prova che
        // annunciava era vera, solo vecchia.
        try? FileManager.default.removeItem(atPath: path)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o"] + soggetto + [path]
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
