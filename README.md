# Kalamos

**Dictation for macOS that writes like you meant it — and never sends your voice anywhere.**

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

## Why another dictation app

There are two kinds of dictation tools, and both make you give something up.

**The good ones send your voice to a server.** Punctuation, filler removal and
self-corrections need a language model, and running one is expensive, so the
polished products do it in the cloud. You get excellent text, and your meeting
notes, medical questions, private messages and half-formed ideas get uploaded
along the way.

**The private ones give you raw Whisper.** A thin local wrapper hands you the
transcript as the speech model produced it: run-on sentences with no internal
punctuation, every "ehm" preserved, and the sentence you abandoned mid-way still
sitting there next to the one you meant.

Kalamos does the second pass **locally**, with a quantised 7B model on the GPU
and Neural Engine. That is the whole point of the project:

|  | cloud dictation | thin local wrapper | **Kalamos** |
|---|---|---|---|
| Audio leaves your Mac | yes | no | **no** |
| Punctuation on long run-ons | yes | no | **yes** |
| Filler and false starts removed | yes | no | **yes** |
| Self-corrections resolved | sometimes | no | **yes** |
| Account required | usually | no | **no** |
| Price | subscription | free | **free, MIT** |

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
you stop dictating and reload in about a second. The idle timeout is yours to set,
including "never".

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xmasyx/kalamos/main/Scripts/install.sh | bash
```

Requires **macOS 14+ on Apple Silicon** (M1 or newer): transcription runs on the
Neural Engine, which Intel Macs do not have.

Releases are not notarized yet, so the installer clears the quarantine flag that
macOS puts on downloads. That is a real thing to be careful about — read the
script before you pipe anything into a shell, including this one.

Removing it: `install.sh --uninstall`, or `--purge` to take the downloaded models
and settings with it.

## Using it

1. Click into any text field.
2. **Hold Right Command**, speak, release. The text appears at your cursor.
3. Or **double-tap** it to go hands-free, and tap again to stop.
4. Changed your mind halfway through? **Press Escape** and the recording is
   discarded — nothing is transcribed, nothing is typed. Escape behaves normally
   whenever Kalamos is not recording, so it stays yours everywhere else.

Everything else lives in the menu-bar icon.

| | |
|---|---|
| **Languages** | Italian, English, French — detected automatically |
| **AI cleanup** | punctuation, filler, false starts, self-corrections — on device |
| **Translation** | dictate in one language, type in another |
| **Edit Mode** | select text, hold a key, say "make it more formal" — it rewrites in place |
| **Vocabulary** | teach it names and jargon it keeps getting wrong |
| **Corrections** | hard rules: "when you hear X, write Y" |
| **Tone** | adapts register to the app you are writing into |
| **Models** | swap the speech and cleanup models from the menu |
| **Prompt** | edit the cleanup instructions yourself |
| **Memory** | keep the models resident, or let them unload after N minutes — your call |
| **History** | the last 25 transcriptions, one click to copy any of them back |

First run downloads about 6 GB of models. After that, nothing.

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
vocabulary.

**Your own cleanup prompt.** *Cleanup ▸ Edit Prompt…* replaces the built-in
instructions completely, so you can make it more literal, more aggressive, or
teach it a house style. Your vocabulary is still appended, whatever you write.
*Reset* puts the original back.

**Tone follows the app you are writing into.** Casual in Messages, WhatsApp,
Telegram and Slack; polite in Mail; clear and professional in Pages, Word and
Obsidian. Register only — never the meaning or your words.

## Memory, on your terms

The two models are the whole cost of running Kalamos, and you decide whether you
pay it continuously or on demand.

**Unload after a while** *(default: 5 minutes)* — the models free their memory when
you stop dictating, and reload in about a second next time. Between dictations
Kalamos holds almost nothing.

**Or keep them resident** — *Advanced ▸ Unload Models After ▸ Never*. First
dictation of the session is as fast as the tenth, at the price of the RAM staying
occupied.

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

Swap either from **menu ▸ Speech Model** and **menu ▸ Cleanup ▸ AI Model**.
Switching frees the old one at once and loads the new one on your next dictation.
No rebuild, no reinstall. Any MLX repo id works, not just the ones in the menu.

| Your Mac | Cleanup model it can hold | Speech model | Together |
|---|---|---|---|
| **8 GB** | up to ~2 GB | Small or Turbo | ~3 GB |
| **16 GB** | up to ~6 GB | any | ~8 GB |
| **24 GB** | up to ~10 GB | any | ~12 GB |
| **36 GB+** | up to ~20 GB | any | ~22 GB |

And it is a **peak, not a resting cost**: both models unload themselves after the
idle timeout and reload in about a second.

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

**Qwen 2.5, in 2026, on purpose.** Qwen 3, 3.5 and 3.6 all exist as MLX 4-bit
builds and Kalamos loads them fine. They are also, measured on the same seven
cases, *worse at this job* — and not by a little:

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

## When something misbehaves

```sh
/Applications/Kalamos.app/Contents/MacOS/Kalamos --doctor
```

It checks permissions, downloaded models, the compiled Metal shaders, the trigger
key and free disk, and prints the fix for whatever is missing.

For the two privacy permissions use **menu ▸ Advanced ▸ Diagnostics…** instead.
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
- **No settings window** — everything is in the menu bar.
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
