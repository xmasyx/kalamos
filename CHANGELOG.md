# Changelog

Every entry says what changed and, where it matters, what was measured to decide
it. Numbers here come from benchmarks in the repo or from real use, never from
an estimate.


## v1.4.0

### Wired headphones no longer crash the app — or leave it deaf

- **Plugging or unplugging a wired microphone could kill Kalamos while it sat idle.** Two crash
  reports half a minute apart, the same garbage pointer in both, fired at the exact moments a pair
  of wired EarPods went in and out — with no recording running. The audio graph lived as long as
  the app: built once, stopped after every dictation, never released. A stopped engine is still a
  CoreAudio client configured against the device it last saw (wired EarPods run at 44.1 kHz, the
  built-in microphone at 48), and the device change called back into a client whose world was gone.
  The graph is now **built when a dictation starts and torn down completely when it ends**: between
  dictations there is nothing left to call into, and every start reads the CURRENT default input —
  which also fixes the quieter half of the bug, a microphone plugged in after launch recording the
  old device's silence.
- **A dictation now survives the microphone changing under it.** The graph listens for the
  configuration change, rebuilds on the new device and keeps the samples already heard; if there is
  nothing to reattach to, the dictation ends with what it heard instead of hanging. Measured with
  the new probe: on the old code the capture froze forever at the first device switch (2.6 s
  captured out of 12); on the new one it keeps growing across two switches (10.9 s out of 12), at
  the cost of ~0.5 s per swap — the time the rebuild takes.
- **A buffer in the wrong format is dropped, never converted.** That is what a device change looks
  like from inside the audio tap, and handing it to a converter built for the other rate asks it to
  misread memory. Three two-pole tests hold the door on the exact 44.1↔48 kHz transition.
- New diagnostic: `Kalamos --selftest-mic [seconds]` watches the capture counter once a second
  while you plug and unplug, and exits non-zero if it ever stops growing.

### The language model now punctuates only where Whisper didn't

- Cleanup no longer runs on every dictation: only when the raw text is long and unpunctuated
  (over 25 words and more than 20 words per punctuation mark) — 15% of a 957-dictation register.
  A duration trigger was rejected by measurement: 58% of long dictations arrive already punctuated,
  because Whisper punctuates from prosody.
- Saying *virgola* as a word (not a command) no longer eats it; the same hole was open on *comma*
  and *virgule* and is closed on both.

### The archive can now say what was actually said

- Re-dictations mark themselves: raw-text similarity above 0.35 within five minutes, a threshold
  read off 813 consecutive pairs from the register and then checked by hand. ⌃⌥L / ⌃⌥K within a
  minute mark too, and ⌃⌥V opens a panel pre-filled with the raw text where you type what you
  really said — the verbatim lands next to the audio.
- No dictation comes out shorter than what the engine heard: unheard stretches are re-listened in
  window-sized pieces, the stitch never doubles a word, and the vocabulary's second decode is
  floored by a word-count guard (it once paid twenty-five words for one properly spelled name).


## v1.3.0

### Whisper is the default engine again, and the reason it stopped being one was mis-measured

- **On long dictations whisper.cpp drops whole sentences, always the same ones.** On the 82-second
  reference file it fails to write one scripted sentence in **16 decodes out of 16**, and on a real
  34-second dictation it loses eight words and leaves a sentence that does not stand up. WhisperKit
  writes that sentence 16 times out of 16, and its word error rate on the same file is 6,5% against
  16,1%.
- **The old measurement was not wrong, it was incomplete.** It compared the two engines on
  *dispersion* — how much the word count wobbles between passes — and whisper.cpp won clearly. It
  never asked whether the text was *complete*. The stability was real, and it was the stability of
  being wrong the same way every time.
- **The cause is found and it is ours, not the library's.** Through the `whisper-cli` binary the
  same file keeps the sentence under every setting tried. Remove the first three seconds of audio
  and the command line loses it too, landing on 109 words — exactly what the app produced. Kalamos
  trims leading silence before decoding, which shifts the audio against whisper.cpp's 30-second
  windows, and a sentence sitting on a seam is dropped. WhisperKit is handed the same trimmed audio
  and keeps it.
- WhisperKit's own long-audio wobble (ISC-163) has not disappeared: bare, it swings by 12 and 10
  words on the two longest files. But even its worst pass carries more words than whisper.cpp's
  best, and with your word list on — now the normal path — the swing falls to 2 and 0, because the
  second decode's prompt gives the decoder an anchor.
- **If you already picked an engine, nothing moved.** This changes what a fresh install starts on.
  Full account: `03-Plans/kalamos-whispercpp/REFERTO-LUNGO-20260808.md`.

### Your word list now works on Whisper too, not only on Whisper.cpp

- **Both Whisper engines now learn your words before they guess.** Until today the initial-prompt
  channel worked only through whisper.cpp, because through WhisperKit it returned an empty
  transcription. WhisperKit 1.1.0 fixed that, it was re-measured here, and the channel is open on
  both: 0 empty transcriptions out of 160, against 160 out of 160 on the old version, with ordinary
  Italian untouched (the sentence *«se lui comandasse la squadra»* stays itself).
- **The discipline is the same one whisper.cpp already used, and it is not "send the whole list".**
  The engine decodes once, looks at which of your words the result seems to have got wrong, and
  decodes again with those alone, at most five. A long prompt damages the very terms it contains,
  which is measured; and on the six clips out of eight where nothing looks wrong, the second pass
  never runs, so it costs nothing.
- **Measured side by side, both engines with your list on** (8 clips, 5 passes, same model): the
  word list takes `Kalamos` from 0/5 to 5/5 and the average word error rate from 5,8% to 4,3% on
  both. WhisperKit is about 14% faster and is the only one that gets `Otium` right; whisper.cpp
  writes *«Otsium»* from the same prompt. Full account:
  `03-Plans/kalamos-whispercpp/REFERTO-20260808.md`. (Written before the long-audio test that then
  moved the default back to WhisperKit — see the entry above.)
- Known limit, written down because it is invisible from outside: a term of **four characters or
  fewer never enters the prompt**, so `fork` is not repaired this way. The fuzzy-match floor is five
  characters, and lowering it is a change that has to be measured, not assumed.

### The dependency wall came down: WhisperKit 0.14.1 → 1.1.0, MLX 2.25.4 → 2.29.1

- **Nothing you can see changed, and that is the point.** Both libraries moved
  forward, no source file needed editing, and all 229 tests pass. The engine you
  dictate through, the models on your disk and every setting stay where they were.
- **Why it was stuck.** WhisperKit and MLX both pulled in `swift-transformers`,
  and their ranges only overlapped on the 0.1.x line, so WhisperKit stayed on
  0.14.1 for months. From 1.x WhisperKit no longer depends on it. A second, purely
  transitive clash remained — WhisperKit 1.1.0 wants `swift-argument-parser` 1.7+,
  while `swift-transformers` 0.1.x pins it to 1.4.x — and moving MLX to 2.29.1,
  which uses `swift-transformers` 1.0.0, clears it.
- **What it unlocked.** WhisperKit 1.1.0 lists `promptTokens` among its fixes, the
  defect that made the word list useless on that engine. It was re-measured the same
  day rather than assumed, and then switched on — see the word-list entry above.
- A source guard was found dead while checking this, and repaired: the test that
  proves every shortcut printed in the menu is a shortcut something listens for
  was anchored to `private func setupMenuBar()`, and the word `private` had gone
  two commits earlier. It now anchors on the function name alone.

### In a terminal, "no scusami" now takes back what you took back

- **Dictating a correction into a terminal used to leave both versions in.** Say
  "il 29 settembre, no scusami, il 29 agosto" and the command arrived carrying two
  contradictory dates. That was deliberate: text dictated into a terminal is an
  instruction, so the cleanup was forbidden from removing anything. It was the
  wrong call — a command with two dates is not the safe outcome, it is the one you
  have to fix by hand.
- **The permission is narrow and gated on evidence, in two places at once.** The
  prompt allows exactly one deletion, and only after a spoken marker ("no scusami",
  "no aspetta", "anzi", "volevo dire", "mi correggo", "no wait"); the fidelity
  guard independently refuses any answer that lost words unless the marker was
  among them, inside a budget of a third of the text, with invented words still at
  zero. A model that decides on its own that a clause was superfluous still gets
  its answer thrown away.
- **Measured on 275 real dictations**, 25 of them containing a marker. The pole
  that decided it is the other 250, which ask for no correction at all and must
  come back word for word: rows losing at least one word went 10 → 7, words lost
  13 → 10, words invented 6 → 4. The door did not widen. It is also deliberately
  shy — of roughly eight genuine retractions in that corpus it resolves one, and it
  leaves alone every marker that continues a thought instead of undoing it ("anzi
  sono peggiori in questo tipo di task" keeps both halves).
- **Outside a terminal nothing changed, and that was measured too.** The general
  prompt already resolved self-corrections, with an example and with the warning
  about false markers. Naming the extra markers there made it worse, with
  retractions resolved going 4 → 3, so the change was reverted.
- **The marker list is now the one you actually speak.** `scusami` was missing and
  `scusa` did not cover it, because matching is by whole word; `sorry` and `I mean`
  came out, since they are ordinary speech long before they are retractions. That
  list is shared, so both fixes apply in every app, not only in terminals. Cost of
  the removals, measured: zero. Across 275 dictations neither word was ever among
  those the cleanup dropped.

## v1.2.0

### Whisper.cpp is now the engine a new install starts on

- **The default moved from WhisperKit to whisper.cpp**, because on the two things
  that decide whether a dictation survives, the measurements are not close. Your
  word list can now act *before* a word is lost: through WhisperKit the initial
  prompt returns an empty transcription 48 times out of 48 (upstream defect,
  WhisperKit issue #372, fixed in no released tag), while through whisper.cpp
  terms that came out wrong 8 times out of 8 come out right 5 times out of 5. And
  long audio stops drifting: the same file decoded eight times gave word counts
  swinging by 11 and by 31, against 200 identical texts over 200 passes of five
  files. The full account is in the README, *Three engines, and why you would pick
  each*.
- **Nothing changes for anyone who already picked an engine.** This is the value
  for an install that has never chosen: your choice in Preferences still wins, and
  all three engines stay selectable.
- **What it costs:** a 1.62 GB model download the first time, against Whisper's
  1.5 GB. On a Mac too small for either, setup still proposes Parakeet (461 MB) —
  and it now weighs the engine it is actually proposing, instead of pricing every

### The menu bar opens with the app's own livery

- **The two greyed-out rows at the top of the menu are now a drawn panel**: the
  name with its glyph, the status aligned right, and one line underneath that
  teaches the trigger key while you are learning it and then tells you which
  engine is listening and in which language — two facts that previously required
  opening Preferences. Everything below stays a native menu, so items, submenus
  and the ⌃⌥ shortcuts behave exactly as macOS behaves.
- Two things worth knowing if you build interfaces on this: a SwiftUI view's
  height must be asked for **after** it has been given its width (asked before,
  it answered 92 points where the content needed 61, i.e. an empty band at the
  top of the menu), and a window with `.fullSizeContentView` declares the title
  bar's thirty points as a safe area that SwiftUI will push your content into.

## v1.1.1

### Two of the four speech models could not be selected

- **Choosing Small or Large v3 no longer kills dictation.** On a machine that did
  not already have them, picking either one failed with `modelsUnavailable`,
  hunting for a file the download had never fetched. The cause is a race this
  process loses every time: the Hub asks a network monitor whether the machine is
  offline, and that monitor is born believing it is, corrected only by a callback
  that has not arrived yet. Worse, its offline path does not fail — it finds the
  models you already have sitting in the folder and returns, having downloaded
  nothing at all. Verified by fetching both models in full, 479 MB and 2.9 GB.
- **A download is finished when the files are there**, not when the function
  returns. The check that says so is new, and so is the error it raises: it names
  the model and tells you what to try, instead of naming a file no reader has
  heard of.

### Whisper's own vocabulary, measured and left off

- **The `promptTokens` switch stays off, and now for a reason with numbers.**
  Teaching Whisper a word before it mishears it is the only lever that acts
  before the word is lost, and it has been disabled since a bad day in July. On
  16 real recordings, 5 passes, both language modes, turning it on returns an
  empty transcription 160 times out of 160 on the Turbo model. Forcing the
  language does not help, which was the standing hypothesis.
- **The prompt itself is fine.** The same prompt on `openai_whisper-base` works,
  and repairs exactly the failure it was written for. This is
  [WhisperKit #372](https://github.com/argmaxinc/WhisperKit/issues/372), fixed
  upstream on 2026-07-30 and in no released tag yet.
- The bench that decided it ships with the app: `--selftest-engine` now takes
  `--prompt` and `--modello`, and counts empty decodes BEFORE the reload gets a
  chance to rescue them, because that rescue is what hid the failure.

### Preferences stays where you left it

- **Each section opens at its own top.** One scroll view kept one offset, so
  scrolling to the bottom of Dictation and clicking Cleanup opened Cleanup at the
  bottom — of a page you had never scrolled. Where you landed depended on how far
  down you happened to be in the section before.

- **Clicking another app no longer makes the settings window vanish.** It goes
  behind, like any other window. `hidesOnDeactivate` had been switched on the day
  before to answer a specific report — a window shown while a terminal is
  full-screen is placed INTO that space by macOS and then sits on top of its host
  — and that flag was too blunt by half: it hid the window on every deactivation,
  full-screen or not. The stepping-aside is now scoped to the case that asked for
  it, detected by the missing menu-bar inset.

### The chips stopped quoting one machine's stopwatch

- **The engine row no longer shows a transcription time.** "0,66 s" against
  "0,10 s" were measured on one Mac; printed next to somebody else's engine they
  are an invention. Only the download size is left, which is true everywhere. The
  qualitative difference the measurements did establish stays in the sentence
  above the row.
- **A row of four choices drops to two columns when a label is too long for a
  quarter of the pane.** "Premuto o doppio tocco" was coming out as "Premuto o
  doppio…", and a choice you cannot read is not a choice. Two columns is also the
  shape the same question has in setup, so the two no longer disagree.

### The app said it was downloading a model it had downloaded weeks ago

- **A cached model no longer announces a download.** The cleanup model's loader
  decided correctly that the file was on disk, then its progress handler
  overrode that decision one line later — the handler fires while a cached model
  is *read*, not only while one is fetched, and the comment saying otherwise was
  simply wrong. So every relaunch popped a panel announcing a 4 GB download of a
  model that had been here for weeks.
- **The same defect in the Parakeet engine**, found by sweeping for it: it
  announced a download on every prepare, cached or not.
- **And the panel itself was landing off the edge of the screen.** It was
  positioned before SwiftUI had laid out its content, so its size read as zero
  and it was parked with its left edge where its right edge belonged. What you
  saw was an unreadable sliver at the edge of the display — reported three times
  as "a little icon appeared and I cannot tell you what it says". It is now
  measured before it is placed, placed again once the window server has
  certainly measured it, and clamped so it can never sit outside the screen.

### The text inside the choice tiles

- **Centred, and aligned across a row.** Both, which is why it took two passes:
  centring alone lets a two-line note push its own title upward so a row reads as
  crooked, and aligning alone leaves a page of bare words hanging from the top of
  their boxes. Every tile on a page that has any note now reserves the room for
  one, so the block can be centred and the titles still line up.
- Titles are semibold, notes a point smaller and a little further down.
- The one note on the language page is gone: a single tile with a note forces
  every tile on that page to reserve room for one, which lifted four bare words
  off centre. What it said is already the hint at the top of the page.

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
