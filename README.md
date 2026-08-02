# Kalamos

**Local-only dictation for macOS that writes like you meant it — and checks the
model's work against what you actually said.**

Hold a key, speak, release. Punctuated, cleaned-up text lands at your cursor, in
whatever app you are using. Both models — the one that hears you and the one that
tidies what you said — run on your Mac.

```
you say:  the meeting is on tuesday at ten no wait wednesday at ten thirty in the big room
you get:  The meeting is on Wednesday at ten thirty in the big room.

you say:  so basically um the api returns a list of users and uh each one has an id
          a name and an email and then you filter them by the active flag before
          you render them
you get:  So basically, the API returns a list of users, and each one has an ID, a
          name, and an email. Then you filter them by the active flag before you
          render them.
```

Notice what happened in the first one: Tuesday at ten is *gone*, not punctuated
into the sentence. And in the second: the fillers dropped, "api" became "API",
and one breathless run-on became two sentences.

Every example in this README is real output, and you can reproduce any of them:

```sh
Kalamos --clean "the meeting is on tuesday at ten no wait wednesday at ten thirty"
```

*Kalamos* (κάλαμος) is the reed pen of the ancient world, the one in the Latin
phrase *currente calamo* — writing at the speed of thought, without stopping.

## This is not another Whisper wrapper

Local dictation on the Mac is a crowded shelf in 2026, and it would be dishonest
to open with "the private ones only give you raw Whisper". That was true two
years ago. It is not true now:

- **[FluidVoice](https://github.com/altic-dev/FluidVoice)** (GPLv3, free) pairs
  on-device speech with *Fluid-1*, its own Gemma-based model trained on dictation
  data, and cleans up locally.
- **[VoiceInk](https://tryvoiceink.com)** (GPL, ~$29 prebuilt) is on-device by
  default, with optional cloud enhancement through your own API key.
- **[superwhisper](https://superwhisper.com)** runs Whisper locally and offers
  cloud models — GPT, Claude, Gemini — when you want more.
- **[MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper)** is the offline
  file-transcription workhorse.
- **Wispr Flow, Aqua, LumeVoice** are the polished cloud products: excellent
  text, and your voice goes to a server to get it.

They are good, and several of them are better than Kalamos at things Kalamos does
not try to do — Windows, iPhone, file transcription, meeting notes.

**So here is the actual difference, in one sentence: every one of these asks its
model to behave. Kalamos does not believe it.**

The cleanup model's dangerous failure is not a typo. It is the sentence that
comes back *reading better* while meaning something else — a lead-in clause gone,
a "però" dropped, a misheard word confidently "corrected" into a different one.
It reads well, so you paste it, and you find out weeks later in something you
already sent. The state of the art against this is a strict prompt, and a strict
prompt is a request. It held for us until the afternoon the model deleted a
leading *"però"* four separate times.

So in Kalamos the prompt is not the guarantee. **Every cleanup is diffed against
what you actually said, and discarded if it fails the diff** — words invented,
words lost beyond a budget, a connective missing, or any change at all on a short
utterance. When it fails you get the fast rule-based pass instead: worse text,
never wrong text. In a terminal, where what you dictate is a command someone will
execute, the tolerance drops to zero — one word gained or lost and the model's
version is thrown away.

I could not find another dictation tool that verifies its cleanup against the
transcript rather than trusting the prompt. If yours does, open an issue and I
will link it here.

The rest is a matter of taste, and here it is without spin:

|  | cloud dictation | offline Whisper wrapper | local cleanup (FluidVoice, VoiceInk) | **Kalamos** |
|---|---|---|---|---|
| Audio leaves your Mac | yes | no | no | **no** |
| A cloud path exists at all | — | no | optional | **none, structurally** |
| Punctuation on long run-ons | yes | no | yes | **yes** |
| Self-corrections resolved | sometimes | no | some | **yes** |
| Output checked against what you said | no | — | no | **yes** |
| Safety policy changes by app | no | — | tone only | **yes — verbatim in terminals** |
| Dictate one language, type another | some | no | no | **yes, on device** |
| Rewrite selected text by voice | no | no | no | **yes** |
| Licence | proprietary | proprietary | GPLv3 | **MIT** |
| Price | subscription | one-off | free / one-off | **free** |

Self-corrections are the part worth trying first, because they are the one thing
no amount of punctuation logic can fake. *"We should ship on Friday, I mean
Monday, because Friday is a public holiday"* becomes **"We should ship on Monday
because Friday is a public holiday."** — the wrong day is deleted, the reason for
it survives.

But *"it's not bad, actually it's excellent"* keeps both halves, because there the
same word reinforces instead of retracting. Nothing but reading the meaning tells
those two apart, which is exactly why this needs a model and not a rule list. It
works the same in Italian (*anzi, cioè no, volevo dire*) and French (*plutôt,
enfin non*).

**"Local-only", not "local-first".** *Local-first* is the polite way of saying
there is a cloud path you are not using today. There is no cloud path here: no
account, no key field, no toggle, no server to point at. The single outbound
request in the app's life is the model download on first run, and you can verify
that yourself with one grep — the section below shows you how.

## What this project commits to

These are not aspirations. Each one is either enforced by the code or checkable
by you, and one section below tells you how to check.

**Nothing you say leaves the machine.** No account, no login, no analytics, no
crash reporting, no "anonymous usage statistics" sent anywhere. The only outbound
request Kalamos ever makes is the one-time model download on first run. After
that it works with the network off — try it.

**What touches the disk, precisely.** Two things, both local, both inspectable,
because "we store nothing" is usually a lie and you should not have to take it on
faith:

- **The last 25 transcriptions**, in the app's own preferences
  (`~/Library/Preferences/com.kalamos.app.plist`). They exist so a mis-fired paste
  or a wrong focused field never loses what you said: they are listed in the menu,
  one click copies any of them back, and **Clear History** deletes them all. Never
  transmitted, never more than 25.
- **A timestamp-only usage log** — the time you dictated, never the text — so
  `Scripts/analyze-idle.ts` can suggest an idle timeout that fits how you actually
  work.

Full transcript logging exists for debugging, is **off by default**, and `--doctor`
keeps warning you for as long as it is on.

**No subscription, no tiers, no upsell.** MIT licensed. There is no paid version
to be nudged toward, because there is no paid version.

**It fails loudly or not at all.** A silent fallback that returns plausible text
is worse than an error, because you cannot see it. This is not theoretical: a
substring bug once classified iTerm2 as a code editor — its bundle id is
`com.googlecode.iterm2`, and "googlecode" contains "code" — so AI cleanup was
skipped in the terminal for months, with no visible symptom at all. That class of
failure now has tests, and `--doctor` exists to make the rest of it visible.

**Your Mac is not a datacenter.** Both models unload themselves from memory after
you stop dictating and come back in a few seconds. The idle timeout is yours to set,
including "never".

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xmasyx/kalamos/main/Scripts/install.sh | bash
```

Requires **macOS 14+ on Apple Silicon** (M1 or newer): transcription runs on the
Neural Engine, which Intel Macs do not have.

Removing it: `install.sh --uninstall`, or `--purge` to take the downloaded models
and settings with it.

### What macOS will say, and why

Kalamos is **not notarized**. Notarization means enrolling in the Apple Developer
Program at $99 a year, and this is a free MIT project — so the honest thing is to
tell you exactly what that costs you, rather than hide it.

macOS puts a *quarantine* flag on anything downloaded from the internet. On a
quarantined app that Apple has not notarized, Gatekeeper does not offer you a
choice: on recent macOS you get **"Kalamos is damaged and can't be opened"**,
which is not true — it is what macOS says when an app is unsigned-by-Apple and
still carries that flag.

**The one-line installer clears the flag for you** (`xattr -d
com.apple.quarantine`), which is why it exists. Piping a script from the internet
into a shell is exactly the habit that gets people compromised, so
[read it first](Scripts/install.sh) — it is about a hundred lines and it does
nothing clever.

**If you prefer to download the `.zip` from [Releases](../../releases) by hand**,
do the same thing yourself:

```sh
unzip Kalamos.zip -d /Applications
xattr -d com.apple.quarantine /Applications/Kalamos.app
open /Applications/Kalamos.app
```

**Then macOS asks for two permissions, and both are the app working, not the app
overreaching:**

- **Microphone** — to hear you. Nothing else uses it.
- **Accessibility** — two jobs: noticing the key you press *while you are in
  another app* (that is what a global hot key is), and typing the text into that
  app. Without it, pressing the key does nothing at all — no error, no sound, no
  effect. Setup asks for both with the reason next to each.

If it ever misbehaves, **Preferences ▸ Advanced ▸ Diagnostics…** prints exactly
which of those is missing.

## Using it

1. Click into any text field.
2. **Hold Right Command**, speak, release. The text appears at your cursor.
3. Or **double-tap** it to go hands-free, and tap again to stop.
4. Changed your mind halfway through? **Press Escape** and the recording is
   discarded — nothing is transcribed, nothing is typed. Escape behaves normally
   whenever Kalamos is not recording, so it stays yours everywhere else.

Everything you *do* lives in the menu-bar icon; everything you *decide* lives in
**Preferences** (⌘, from the icon), in four sections — Dictation, Cleanup, Words &
corrections, Advanced. Kalamos speaks Italian, English and French, and the
language you pick on the first screen is the language of the whole app, menu
included.

| | |
|---|---|
| **Languages** | Italian, English, French — detected automatically |
| **AI cleanup** | punctuation, filler, false starts, self-corrections — on device |
| **Translation** | dictate in one language, type in another |
| **Edit Mode** | select text, hold a key, say "make it more formal" — it rewrites in place |
| **Vocabulary** | teach it names and jargon it keeps getting wrong |
| **Corrections** | hard rules: "when you hear X, write Y" |
| **Tone** | adapts register to the app you are writing into |
| **Models** | swap the speech and cleanup models in Preferences — the first one is chosen for your Mac |
| **Prompt** | replace the cleanup instructions with your own |
| **Memory** | keep the models resident, or let them unload after N minutes — your call |
| **History** | the last 25 transcriptions, one click to copy any of them back |

First run downloads the two models — between 3.4 and 6 GB depending on which
cleanup model your Mac was given — with a progress panel that says so while it
happens. After that, nothing: no network, no account, no subscription.

**You are not asked what your Mac can take.** Nobody installing a dictation app
knows how much RAM they have, and nobody who does knows what changes between a
3B and a 7B. So setup reads the machine — chip, memory, cores, free disk — and
proposes four settings from it: which engine listens, whether the cleanup model
runs at all, which one, and when the memory is freed. Every proposal is shown
with the number that decided it, on a page called **Your Mac**. Say *that's fine*
and setup skips the two pages it just answered; say *I'll choose* and they open
with the proposal already selected.

Three rules that page keeps:

- **It shows facts, never predictions.** The seconds quoted elsewhere in this app
  were measured on one machine; printing them next to somebody else's would be
  inventing them. So every reason is a quantity read off your Mac.
- **It never proposes a model nobody measured.** The Qwen2.5 14B and Whisper
  Large v3 are real choices in Preferences and have never been benchmarked here.
- **Nothing is written unless you press a button.** Open setup, read the page,
  close it, and every setting is where you left it.

If the disk cannot hold what the memory could have run, the proposal steps down
on its own and says why — a first run that ends in a failed download is not a
first run.

## Edit Mode — rewriting what is already there

Dictation puts new words in. Edit Mode changes words that already exist: **select
any text, hold the Edit key, say what you want done to it**, and the selection is
replaced. On device, like everything else.

```
select:  hey so i can't do tomorrow's shift sorry
say:     make it more formal
get:     I regret to inform you that I will not be able to attend tomorrow's shift.

select:  we need to fix the login bug update the docs and ship the release by friday
say:     turn it into bullet points
get:     - fix the login bug
         - update the docs
         - ship the release by friday
```

It also translates, shortens, expands, changes tone — whatever you can say in a
sentence. It is **off by default** and lives on its own modifier (Fn by default,
never the dictation trigger), because "rewrite the thing I have selected" is too
destructive to trigger by accident.

Try it without granting anything:

```sh
Kalamos --edit "make it shorter" --on "your text here"
```

## Spoken punctuation, no model required

The rule-based cleanup — the free, instant one — does something the size of the
model cannot fix: it decides whether you *said* a punctuation mark or *meant* the
word.

```
ho finito il lavoro punto      →  Ho finito il lavoro.        ← a full stop
prendi il latte punto poi torna →  Prendi il latte. Poi torna. ← mid-sentence
il punto 4 è importante        →  Il punto 4 è importante.    ← still the word
vediamo il punto di vista      →  Vediamo il punto di vista.  ← still the word
```

Same four letters, four different decisions, no LLM involved. English (*"period",
"new paragraph", "question mark"*) and French (*"point", "nouveau paragraphe"*)
work the same way. `Kalamos --selftest-format` runs these as assertions.

## The net under the model, in detail

The opening claims Kalamos does not trust its own model. This is what that means
in code — `MLXFormatter.changedTooMuch`, and the tests around it.

Every cleanup is diffed against what you actually said, on **content words**
(anything over two characters that is not a known filler), and thrown away if it
fails any of these:

- **Words invented** — anything in the output that was never in the input. This
  is how a misheard word gets confidently "corrected" into a different one.
- **Words lost** — beyond a budget that filler and self-corrections fit inside
  comfortably. This is how a whole lead-in clause vanishes because the model
  decided your sentence was "really" about its second half.
- **Connectives, always** — *però, tuttavia, invece, anche, however, though,
  instead, also, pourtant, plutôt*. Losing one of these changes what a sentence
  concedes or contrasts, and the diff is a single small word. Asking the model to
  stop dropping them **did not work**: it deleted a leading "però" four times in
  one afternoon of real use. The rule lives in code, where it is not a matter of
  persuasion.
- **Short utterances get no latitude at all.** Under eight content words there is
  nothing to restructure, so anything beyond punctuation and capitals is
  rewriting. This is not hypothetical either: five words came back with
  *"interest"* turned into *"interessato"*, a word nobody had said.

Fail any of those and the AI output is discarded — you get the fast rule-based
cleanup instead. Worse text, never wrong text.

**In a terminal the tolerance is zero.** Kalamos knows which app you are typing
into, and what you dictate into a terminal is an instruction someone is about to
execute. There, one word gained or lost sends the result to the fallback, whatever
the length. The accepted cost is real and worth stating: on very ungrammatical
speech the model cannot punctuate without "fixing", so you get a flat sentence
instead. Flat and yours beats polished and altered.

## Translation, on device

Dictate in one language, get another out — the same local model, no service:

```
you say:  Ciao, come stai oggi? Spero che tu stia bene.
you get:  Hi, how are you today? I hope you're doing well.
```

Pick the target in **Preferences ▸ Dictation ▸ Instant translation**. Set it back to *Off* and dictation
stays in whatever language you spoke.

## Nothing is ever lost

Every transcription is recorded **before** injection is attempted, so a paste into
the wrong window or a field that stole focus cannot destroy what you said. The
menu keeps the last 25 and one click copies any of them back. Two of them are also
global shortcuts, so they work without opening anything:

- **⌃⌥C** — put the last transcription back on the clipboard.
- **⌃⌥S** — summarize the last dictation with the local model, when you have
  talked your way through a problem and want the shape of it. The summary lands on
  the clipboard too.

Control+Option rather than Command, because ⌘C belongs to macOS and an app that
swallowed it globally would break copying everywhere.

## Making it yours

Dictation degrades exactly where your work is most specific: names, jargon,
product names, foreign words. Four mechanisms handle it, and they run in this
order.

**Corrections — deterministic, always wins.** *When you hear X, write Y.* Applied
to the raw transcript before anything else touches it, whole-word and
case-insensitive. This is the right tool when Whisper gets a word wrong **the same
way every time**. Menu ▸ *Corrections ▸ Add Correction…*

**Vocabulary — contextual, applied with judgement.** A list of names, terms and
spellings injected into the cleanup model's prompt, so it preserves them when they
appear and repairs near-misses from context. This is the right tool when the
mistake **varies**. The fast path: select a word anywhere on your Mac and press
**⌃⌥L** — it is learned without opening a menu.

The difference matters. A correction is a hammer that always swings; vocabulary is
a hint the model weighs against the sentence. A surname you always want spelled one
way is a correction. A technical term Whisper mangles differently every time is
vocabulary. Both are lists you edit in **Preferences ▸ Words & corrections** —
type, add, delete.

**Your own cleanup prompt.** **Preferences ▸ Cleanup ▸ Instructions for the
model** replaces the built-in instructions completely, so you can make it more literal, more aggressive, or
teach it a house style. Your vocabulary is still appended, whatever you write.
*Reset* puts the original back.

**Tone follows the app you are writing into.** Casual in Messages, WhatsApp,
Telegram and Slack; polite in Mail; clear and professional in Pages, Word and
Obsidian. Register only — never the meaning or your words.

## Memory, on your terms

The two models are the whole cost of running Kalamos, and you decide whether you
pay it continuously or on demand.

**Unload after a while** *(default: 5 minutes)* — the models free their memory when
you stop dictating, and are read back from disk next time, which costs a few
seconds. Between dictations Kalamos holds almost nothing.

**Or keep them resident** — **Preferences ▸ Advanced ▸ Never**. Both models are
then loaded at launch and stay loaded, so the first dictation of the session is as
fast as the tenth, at the price of the RAM staying occupied.

**And a ceiling nobody thinks to check.** MLX keeps a cache of freed Metal
buffers to reuse them, and its default limit is the *memory limit* — measured on
a 36 GB Mac: **35 020 MB**. Dictations of different lengths keep asking for
buffers of different sizes, so that cache only grows. A Kalamos left running all
day reached a **13 GB footprint** (12 GB of it in IOAccelerator, across 2391
regions) while the same binary restarted two minutes earlier sat at 4.9 GB with
1007 regions — same models, same settings, 7.5 GB of pure accumulation. Nothing
ever emptied it, and choosing "never free the memory" guaranteed nothing ever
would.

It is capped at 512 MB now, once, at startup. What that cost, measured properly —
two replicates, arms **alternated** A,B,A,B over 8 rounds of 5 dictations at
temperature 0 so both arms generate the identical tokens:

| | uncapped | capped |
|---|---|---|
| Generation time | baseline | **−0.44% and −0.72%** (noise band: 6.6% and 13.6%) |
| Buffer cache | 1608 MB | **511 MB** |
| Footprint after 40 generations | 5946 MB | **4844 MB** |

No measurable cost, 1.1 GB back almost immediately. Worth writing down: the
*first* attempt at this measurement ran the arms in blocks (A,A,B,B) and reported
the cap was "15% slower" — that was thermal drift, dumped entirely on whichever
arm ran last. If you re-measure anything here, alternate the arms.

Anything in between: 1, 2, 5, 10, 15 or 30 minutes. And if you have no idea which
to pick, `Scripts/analyze-idle.ts` reads the timestamp-only usage log and tells you
what your actual dictation rhythm implies:

```sh
bun Scripts/analyze-idle.ts
```

## Which models your Mac can run

Two models sit in memory: one that hears you, one that cleans up what you said. On
Apple Silicon both live in unified memory, shared with everything else you have
open — so what matters is your **total RAM**, and the sum of the two.

Swap either in **Preferences ▸ Dictation** and **Preferences ▸ Cleanup**.
Switching frees the old one at once and loads the new one on your next dictation.
No rebuild, no reinstall. Any MLX repo id works, not just the ones in the menu.

| Your Mac | Cleanup model it can hold | Speech model | Together |
|---|---|---|---|
| **8 GB** | up to ~2 GB | Small or Turbo | ~3 GB |
| **16 GB** | up to ~6 GB | any | ~8 GB |
| **24 GB** | up to ~10 GB | any | ~12 GB |
| **36 GB+** | up to ~20 GB | any | ~22 GB |

And it is a **peak, not a resting cost**: both models unload themselves after the
idle timeout, and come back in a few seconds when you next dictate.

## What I would actually use

Can-run and should-run are different questions, and the second one has a
surprising answer.

| Your Mac | Cleanup | Speech |
|---|---|---|
| **8 GB** | Qwen2.5 **3B** Instruct (1.7 GB) | Turbo |
| **16 GB and up** | Qwen2.5 **7B** Instruct (4.3 GB) — **the default** | Turbo |

That is the whole recommendation. Two models, and a bigger Mac does not change it.

**Turbo, even on 36 GB.** Large v3 is not the upgrade the size suggests: on
dictation-length audio Turbo is nearly as accurate and several times faster.
Reach for Large v3 for a strong accent or a noisy room, not by reflex.

**Qwen 2.5, in 2026, on purpose — and this is not laziness about updating.**
Qwen 3, 3.5 and 3.6 all exist as MLX 4-bit builds, Kalamos loads them without
complaint, and every one of them is **worse at this particular job**. Not
marginally: measured on the same seven cases, the whole Qwen 3 line lands between
*"barely punctuates"* and *"does nothing but capitalise the first letter"*.

| Cleanup model | Size | Punctuation added to one long run-on | Recognised a name |
|---|---|---|---|
| **Qwen2.5 7B Instruct** | 4.3 GB | **7 marks** | yes |
| Qwen2.5 3B Instruct | 1.7 GB | 5 marks | yes |
| Qwen3 4B Instruct 2507 | 2.1 GB | 3 marks | no |
| Qwen3.5 4B | 3.1 GB | 1 mark | no |
| Qwen3.6 27B | 16 GB | 1 mark | no |

A 27B model losing to a 3B is not a capability gap, it is a mismatch. The Qwen3
family is trained to reason before answering, and this task wants the opposite: no
deliberation, just the same sentence with punctuation. *(That is the likely
explanation, not a proven one — the pinned mlx-swift version may also simply
mishandle their chat template.)*

The lesson generalises: **newer is not better, measured is better.** Run the
comparison yourself before believing this table — it is one command per model:

```sh
Kalamos --selftest-punct --model mlx-community/Qwen2.5-3B-Instruct-4bit
```

**Or no model at all.** *Cleanup ▸ Rule-based (instant)* uses none: spoken
punctuation commands, filler removal, capitalisation. Zero RAM, zero wait. You give
up the self-corrections, which are the part worth having.

## What is deliberately not here

Absent features are decisions too, and an app that explains its omissions is
easier to trust than one that lists only what it has.

**No recording indicator on screen.** macOS already puts an orange dot next to
the menu bar the moment any app opens the microphone — it is drawn by the system,
it cannot be faked by an app, and it is therefore *better evidence* than anything
Kalamos could draw about itself. A second indicator would be a worse copy of
something already on your screen, occupying space to repeat it. An earlier
version had a floating HUD; it was removed for exactly this reason.

**No text appearing while you speak.** Live partial transcription looks
impressive in a demo and is unpleasant to use: words rewrite themselves under
your eyes as the model revises, and you end up reading instead of thinking. The
text arrives once, when you release the key, already clean.

**No Dock icon.** Kalamos lives in the menu bar. The icon appears only while the
Preferences or setup window is open — a window needs the app to be a foreground
one to reliably take keyboard focus — and goes away when you close it.

**No account, no telemetry, no "anonymous usage statistics", no update checker
phoning home.** The single outbound request in the app's life is the model
download on first run.

## When something misbehaves

```sh
/Applications/Kalamos.app/Contents/MacOS/Kalamos --doctor
```

It checks permissions, downloaded models, the compiled Metal shaders, the trigger
key and free disk, and prints the fix for whatever is missing.

For the two privacy permissions use **Preferences ▸ Advanced ▸ Diagnostics…** instead.
macOS attributes those grants to the process that started the app, so a terminal
invocation reports your terminal's permissions rather than Kalamos's — and a
diagnostic that answers a question you did not ask is worse than none. The
command-line version says so rather than showing you a confident wrong answer.

macOS asks for two permissions on first use: **Microphone**, to hear you, and
**Accessibility**, to read the global hot key and type into other apps. Without
the second one, pressing the key does nothing at all.

## Verifying the privacy claim yourself

Do not take the section above on faith — it is a claim about software you did not
write.

- **Cut the network.** Turn Wi-Fi off after the first run. Dictation, cleanup,
  translation and Edit Mode all keep working.
- **Watch the connections.** Point Little Snitch, LuLu or
  `lsof -i -p $(pgrep -x Kalamos)` at it and dictate. After the model download
  there is nothing to see.
- **Read exactly what it stored about you.** This prints the rolling history in
  plain text, so you can see there is nothing else hiding in there:

  ```sh
  plutil -extract transcriptHistory raw -o - \
    ~/Library/Preferences/com.kalamos.app.plist | base64 -d
  ```

  Everything else in that file is settings you chose yourself: trigger key,
  models, vocabulary, correction rules.
- **Read the code.** `grep -rn "https://" Sources/` returns nothing: the app's own
  source contains no URLs at all. The only endpoints in play are the model
  downloads inside WhisperKit and MLX, both of which you can read too.

## Build from source

```sh
git clone https://github.com/xmasyx/kalamos.git && cd kalamos
swift test                  # unit tests
./Scripts/build-app.sh      # → build/Kalamos.app, installed and launched
```

Needs **full Xcode**, not just the Command Line Tools: MLX ships Metal shaders
that only Xcode's build system compiles. A plain `swift build` produces an app
that launches fine and then fails the moment AI cleanup runs — `--doctor` will
tell you if you hit this.

Design notes, and the reasoning behind the parts that look strange:
[docs/architecture.md](docs/architecture.md).

## Status

Working, and used daily by its author. Not there yet:

- **Not code-signed or notarized** — hence the quarantine step above.
- **Three languages.** Adding one is mostly a matter of teaching it that
  language's Whisper hallucinations and its self-correction markers; see
  `WhisperKitTranscriber.swift` and `MLXFormatter.swift`.

Bug reports and pull requests are welcome. For a cleanup problem, the useful
things to attach are the `--doctor` output and what you said versus what you got.

## Credits

Built on [WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device
speech recognition and [MLX](https://github.com/ml-explore/mlx-swift-examples)
for the on-device language model. Neither project is affiliated with this one.

## License

MIT — see [LICENSE](LICENSE).
