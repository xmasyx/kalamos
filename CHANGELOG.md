# Changelog

Every entry says what changed and, where it matters, what was measured to decide
it. Numbers here come from benchmarks in the repo or from real use, never from
an estimate.

## Unreleased

### A hands-free dictation closes its own microphone

- **Ten seconds of silence and the microphone closes by itself**, in one-tap and
  double-tap alike. In one-tap every short press of the trigger starts listening
  and only another press stops it, so a key brushed by accident left the
  microphone open indefinitely — seven recordings nobody asked for in
  twenty-six seconds, one of them sixteen seconds long, three transcribed as the
  classic silence hallucination.
- **Two outcomes, and the difference is what makes it safe.** If you had spoken,
  the dictation finishes normally and your text is delivered — throwing away real
  speech would be the worse failure. If nothing was ever said, the recording is
  discarded without being transcribed: no text, no model run, no invented
  sentence out of ten seconds of room tone.
- Both conditions are required: the window must have elapsed AND the last ten
  seconds be silent. Time alone would cut off a pause mid-dictation.
- The guard judges silence with the transcriber's own threshold rather than a
  second one of its own, so the two cannot disagree about the same audio.
- `defaults write com.kalamos.app handsFreeSilenceSeconds -int 0` turns it off,
  or sets another number.

### Setup offers everything the app does

- **The trigger's fourth mode reached setup.** One-tap was added to the app on
  2026-07-31 and Preferences picked it up for free, because that row is built
  from the enum; setup had its three written out by hand. Anyone running one-tap
  arrived at that page and saw **nothing selected** — their own setting was not
  drawable — and Continue let them walk past it. Setup now builds that page and
  the cleanup page from the same enums, and a test fails if a case exists in the
  app and is missing from setup.
- **Right Shift joins the trigger keys**, so the page is four in a 2×2 like the
  one after it — and setup and Preferences now read ONE list. They had a copy
  each, and Right Shift was in Preferences only: the same drift that had just
  lost the fourth trigger mode, found in the same hour.
- **Cleanup can be turned off from setup too** ("Nothing", the raw words you
  said). Preferences had it; setup did not.
- **Continue is greyed and inert until the page has an answer.** Two pages offer
  a subset of what their setting accepts — the trigger key is any key code, the
  idle timeout any number of seconds — so a value set elsewhere can leave every
  tile dark. Walking past a question you never answered, believing you did, was
  the failure.
- **"Both" became "Hold or double-tap".** It was named back when there were two
  modes to be both of; with four tiles on the page it stopped naming anything.
- **Tile text is aligned across a row.** The titles sit on one line and the notes
  hang below, so a tile whose note runs to two lines no longer pushes its own
  title up and leaves the row looking crooked.
- **Air on the "Your Mac" page**, and the two buttons moved to the bottom,
  centred. The facts line sits midway between the sentence above it and the
  proposals below, instead of hugging the proposals. It is the densest of the eight pages and was taking its spacing from a
  grid of tiles it does not have.
- `--scatta` no longer prints a filename it never wrote: `screencapture` exits 0
  without producing an image when the bundle has no Screen Recording permission,
  which a downloaded or freshly rebuilt copy always lacks.

## v1.1.0

### Setup looks at the Mac instead of asking about it

- **A new page, "Your Mac".** It shows what was read from the machine — chip,
  memory, cores, free disk — and the four settings chosen from it: which engine
  listens, whether the cleanup model runs, which cleanup model, and when the
  memory is freed. Each one carries the number that decided it.
- **Accepting makes setup shorter, not longer.** *That's fine* applies the
  proposal and skips the two pages the machine already answered; *I'll choose*
  opens them with the proposal already selected, so you disagree with it rather
  than starting from nothing.
- **Nothing is written unless you press a button.** Opening setup and closing it
  on that page leaves every setting untouched, which is also true for anyone who
  re-runs setup from Preferences on an install they have been using for months.
- **The memory page no longer prints the rule.** It used to say "after 5 minutes,
  if you have 8 or 16 GB of RAM" and leave the arithmetic to the reader. The app
  knows the number.
- **The disk is checked before a download is proposed.** Under what the models
  need plus 2 GB of headroom, the proposal steps down to punctuation-only, and
  then to the smaller engine — a first run that ends in a failed download was a
  real way to fail that nothing looked at.
- **Two things are deliberately never proposed:** the Qwen2.5 14B and Whisper
  Large v3. Neither has been measured here, and proposing one would be promising
  a quality nobody has seen. Both stay one click away in Preferences.
- **The chip is shown, never used to decide.** "Apple M4 Max" is what makes
  someone recognise their own machine, but every decision keys off memory and
  disk, which are the only quantities there are measurements for.
- `--scatta --onboarding --passo=<n>` photographs any page of setup. The first
  version of the new page recommended "Always ready" while the tile it meant was
  called "Never" — caught in the screenshot, not in the source.

### A second speech engine, off by default

- **Parakeet TDT 0.6B v3 is selectable** next to Whisper (Preferences ▸ Dictation
  ▸ *The engine that hears you*). It is 461 MB against 1.5 GB and transcribes a
  clip in 0.10 s against 0.66 s, measured in-app over ten passes on six
  recordings.
- **It ships switched off, and that is a field result, not a preference.** A
  bench on six *scripted* clips could not tell the two engines apart on the
  delivered text (paired difference +0.9 ± 4.5 points, 150/150 domain terms
  each). An hour of *spontaneous* dictation said otherwise: Parakeet garbles
  ordinary Italian words, and its errors are unstable — one evening produced six
  different spellings of the same proper noun. Correction rules match exact
  strings, so they cannot chase an error that changes shape. Six short, well
  articulated clips do not represent long spontaneous speech; the interval said
  so and the field proved it.
- `--selftest-engine <file-or-dir> [--engine whisper|parakeet] [--ripeti N]`
  runs real audio through the real transcriber and writes JSON, so an engine
  claim can be reproduced from outside the app.

### The vocabulary now repairs the text

Until now the word list fed two things and neither changed what you read: the
Whisper prompt-token path (disabled — it returns empty transcriptions
deterministically) and a line in the cleanup prompt. Measured over 180
transcriptions from three engines with the term sitting in the prompt: **zero
names repaired**. On one engine the model made it worse, inventing a word that
does not exist.

- **`VocabularyRepair`** puts your words back into the raw transcription, after
  your own correction rules and before cleanup — your rule is an instruction,
  the vocabulary is a guess, and the instruction goes first.
- Three brakes, because the failure to avoid is not the missed name but the
  vandalised sentence (an acoustic rescorer once rewrote "nella sala grande" into
  "nella sala Claude"):
  1. exact-but-miscased is repaired at zero distance;
  2. fuzzy matching needs a term of **5+ characters** — swept over 240 real
     dictations, not chosen: four-letter terms sit one edit from ordinary words;
  3. the edit budget is **absolute**, `max(1, length/5)`, never a ratio — a ratio
     lets a long term swallow a long unrelated word.
- Word boundaries are dropped in the comparison, because where an engine puts a
  space is not information about what it heard. That is what puts "ai term" one
  edit from "iTerm".
- A window wider than the term only widens **leftward**: the head of a foreign
  word leaks into the word before it, never the tail into the word after.
  Symmetric widening turned "di cloud e per me" into "di Claude per me" on a real
  dictation; that one rule is what let the floor drop below seven characters.
- `--selftest-vocab <corpus.json> [--terms …] [--min-fuzzy N] [--out …]` runs the
  repair over a whole corpus and **prints every change**, because a rate is not
  evidence.

### The cleanup prompt no longer assumes bare input

The prompt said the input was "all lowercase". On 240 real dictations it arrives
already punctuated **57%** of the time — it depends on where the speaker pauses,
not on length.

- The cost of the false premise was not on punctuated input, where it was
  expected: on **bare** input the model returned the text completely untouched
  **23%** of the time — no capital, no full stop, nothing. That is now **0%**.
- Punctuation marks per 100 words 9.0 → 13.1, sentence ends 5.2 → 7.1, walls of
  text 16/34 → 10/34, words lost 120 → 114, words invented 52 → 40. A blind
  pairwise judge on another vendor preferred the new prompt **50 to 10**, with an
  A/A control that returned 201/201 ties.
- Cost: +50 prompt tokens and +0.12 s ± 0.08 end to end. The tokens themselves
  measure free.
- A variant that additionally forbade repairing the speaker's grammar in so many
  words was measured and **rejected**: it cost twice as much and lost *more* of
  the speaker's words than the prompt it replaced.

### Fixed

- **An edited cleanup prompt no longer skips the fidelity guard.** It had a code
  path of its own that checked for an empty answer and for ballooning and nothing
  else, so anyone who changed a word of the prompt silently switched off
  `changedTooMuch` — the most important thing the app does, disabled by a
  preference nobody would connect to it. `{{VOCAB}}` marks where the vocabulary
  line goes in a hand-written prompt.
- **Preferences no longer sits on top of a full-screen app.** Nothing was
  floating (level 0, no collection behaviour): macOS places a window shown while
  another app is full-screen *into* that space, and there it stays. It now hides
  when Kalamos is not the app you are using, which is the ordinary answer for a
  menu-bar app.
- **Chip rows fill the width they have.** Four columns was a ceiling and read as
  a quota — three options sat in three quarters of the pane with a hole where the
  fourth would have been.
- **Option cards with a second line are laid out in two equal columns** instead
  of flowing, so a picker's options are the same shape rather than each taking
  the width of its own text.
- **The memory-timeout row is four choices on one line**, and the fourth opens a
  field: 5 min, 15 min, Never, or a number you type. One minute and thirty
  minutes lost their slots and neither is lost — a preset is a shortcut, not the
  list of allowed answers.
- **The apply bar is a footer again**, not a section.
- `Tuning` reads its stored value whether it arrives as a number or as a string.
  A value passed on the command line lands in the argument domain as a String, so
  an injected setting was silently ignored and probes measured the default while
  reporting the injection.

### Internals

- `MLXEngine` exposes the token counts of the last generation, so a bench can
  cost a prompt without parsing a log line.
- `--bench-clean` runs a whole corpus through the real cleanup path with the
  model loaded once, alternating arms per item, and records the exact system
  string each arm saw.
- The single text-field shape lives in one place instead of two.

## v1.0.1

Before this changelog existed. See the commit history.
