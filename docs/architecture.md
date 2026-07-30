# Architecture

Kalamos turns held-key speech into text in whatever app has focus, without a
network round trip. This document explains how, and why the awkward parts are
the way they are.

## The pipeline

One utterance, start to finish:

```
Right Command held
   │
   ├─ HotkeyManager ──── CGEventTap on flagsChanged (a global key listener)
   │     ├─ Escape → GestureRecognizer.cancel(), and the key is swallowed only
   │     │   when something was actually recording
   │     └─ GestureRecognizer   hold vs. double-tap → DictationAction   [unit-tested]
   │
   └─ DictationController.endAndProcess()
        │
        ├─ 1. AudioRecorder          AVAudioEngine → 16 kHz mono Float32
        ├─ 2. WhisperKitTranscriber  silence-trim → Whisper on the ANE → hallucination strip
        │        └─ language auto-detected, constrained to the enabled set
        ├─ 3. Corrections            deterministic "heard X → write Y" rules
        ├─ 4. Edit Mode (optional)   transform the SELECTED text, then stop
        ├─ 5. Translate OR clean up  MLXTranslator | MLXFormatter | RuleBasedFormatter
        └─ 6. TextInjector           pasteboard + ⌘V into the frontmost app
```

Steps 2 and 5 are the two models. Everything else is plain Swift.

## Why it is built this way

**Two models, not one.** Whisper is excellent at hearing words and hopeless at
punctuation on long run-on speech. A second, general-purpose LLM (Qwen2.5 via
MLX) reads the raw transcript and restores punctuation, drops filler, and honours
self-corrections — "alle due, cioè no, alle tre" becomes "alle tre". Both run on
device. This second pass is the thing Kalamos has that a thin Whisper wrapper does
not.

**Text is injected once, at the end.** No live streaming. Streaming partial
results into someone else's text field means competing with their cursor and
their undo stack; a single paste is atomic and always undoable in one step.

**Injection is pasteboard + ⌘V, not synthetic keystrokes.** Typing a long
transcript character by character is slow and drops characters in apps that
throttle input. The cost is that the clipboard is briefly borrowed.

**Models live in Application Support, not Documents.** `~/Documents` is
TCC-protected: the app hit a permission wall there and silently re-downloaded the
speech model on every launch. Application Support has no such gate.

**Both models unload when idle.** A 1.5 GB speech model and a 4.3 GB LLM resident
forever is antisocial on a laptop. Each has an idle timer that frees its memory;
the next dictation pays a reload of a few seconds. The timer resets on every use,
so active work never pays it.

## Constraints worth knowing before you change something

**`swift build` is not enough — use `Scripts/build-app.sh`.** MLX ships Metal
shaders that must be compiled into `default.metallib`, and only Xcode's build
system does that. A `swift build` product launches happily and then fails the
moment AI cleanup runs. `--doctor` checks for the compiled shaders precisely
because this failure is otherwise invisible.

**Whisper prompt-biasing is deliberately disabled.** Feeding vocabulary through
`DecodingOptions.promptTokens` makes this model and configuration return an
*empty* transcription and mis-detect the language — deterministically, regardless
of prompt content. The prepended prompt shifts the start-of-transcript token to a
non-zero prefill index and decoding degenerates to end-of-text. Vocabulary still
works, by way of the LLM prompts instead. Do not re-enable it without a live
transcription test proving the regression is gone. See
`WhisperKitTranscriber.swift`.

**Whisper hallucinates on trailing silence.** Trained largely on captioned video,
it fills silence with "thanks for watching", "grazie", "abonnez-vous". Kalamos trims
near-silent audio at both ends and strips a known list of these phrases from the
end of the transcript. Any new language needs its own entries in that list.

**The dependency versions are pinned by an overlap, not by taste.** WhisperKit and
mlx-swift-examples share a transitive dependency on swift-transformers, and their
version ranges only overlap on the 0.1.x line. Newer MLX moved to 1.x with no
overlap. Taking the newest of both means splitting MLX into a sidecar process.

**The gesture recogniser is AppKit-free on purpose.** It is the one piece with
real state-machine complexity (hold, double-tap, abort-on-other-key, push-to-talk
on/off), so it is kept free of UI dependencies and unit-tested in isolation.

## Layout

| Path | What lives there |
|---|---|
| `Core/` | `AppState` (settings + status), `DictationController` (the pipeline), `Doctor`, `Corrections`, `Vocabulary`, `Models` (catalog) |
| `Hotkey/` | `CGEventTap` plumbing and the gesture state machine |
| `Audio/` | microphone capture |
| `Transcription/` | the `Transcriber` protocol and its WhisperKit implementation |
| `Formatting/` | rule-based and LLM cleanup, plus Edit Mode's transformer |
| `Translation/` | the `Translator` protocol and its MLX implementation |
| `MLX/` | the shared on-device LLM engine and the summariser |
| `Injection/` | writing text into the frontmost app |
| `Scripts/` | build, install, signing |

## Diagnostics

Every one of these runs headless, without the GUI:

```sh
Kalamos --doctor                # permissions, models, Metal shaders, disk
Kalamos --version
Kalamos --clean "text" [--lang it|en|fr]   # cleanup pass on one string; exit 2 on misuse
Kalamos --edit "instruction" --on "text"   # Edit Mode without needing Accessibility
Kalamos --selftest-format       # spoken punctuation, no model needed
Kalamos --selftest-corrections  # replacement rules (non-destructive)
Kalamos --selftest-punct        # punctuation restoration on real run-on cases
Kalamos --selftest-cleanup      # the cleanup prompt
Kalamos --selftest-edit         # Edit Mode transforms
Kalamos --selftest-translate    # translation
```

## What persists

Two things outlive a launch, both under the user's own account and neither ever
transmitted:

- **`TranscriptHistory`** keeps the last 25 transcriptions in `UserDefaults`
  (`transcriptHistory`), written *before* injection is attempted, so a mis-fired
  paste or a wrong focused field never destroys what someone said. Surfaced in the
  menu; *Clear History* wipes it.
- **`UsageLog`** appends one ISO-8601 timestamp per dictation — never the text —
  so `Scripts/analyze-idle.ts` can recommend an idle-unload timeout.

Full transcript logging is a third thing, **off by default**, and `--doctor`
reports it as a warning for as long as it is on. Turn it on only while diagnosing
something:

```sh
defaults write com.kalamos.app debugLogging -bool true    # → Application Support/Kalamos/kalamos.log
defaults write com.kalamos.app debugLogging -bool false   # off again
```
