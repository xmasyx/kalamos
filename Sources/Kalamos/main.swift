import AppKit

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
    sem.wait()
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
    sem.wait()
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
    sem.wait()
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
    sem.wait()
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
    sem.wait()
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
    sem.wait()
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
    sem.wait()
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
        ("la rosiggine", "la rosiggine"),               // word boundary: no partial hit
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

    if CommandLine.arguments.contains("--onboarding") {
        // The one screen that has no second chance: whoever installs the app sees it
        // once. Its actions are all no-ops here — nothing asks for a permission, so
        // the probe cannot pop a system prompt at somebody's desk.
        OnboardingWindow.shared.show(state: AppState.shared, actions: OnboardingActions(
            applyTriggerKey: { _ in }, applyTriggerMode: { _ in },
            requestMicrophone: { _ in }, requestAccessibility: {},
            openMicrophoneSettings: {}, finish: {}))
    } else {
        PreferencesWindow.shared.show(state: AppState.shared, actions: PreferencesActions(
            apply: { _ in }, isLaunchAtLogin: { false },
            showDiagnostics: {}, rerunOnboarding: {}))
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
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
        print(path)
        exit(0)
    }
    app.run()
}

// Kalamos entry point.
// A menu-bar-only app: `.accessory` keeps it out of the Dock and app switcher.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
