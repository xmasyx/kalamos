# Kalamos

**Dictation for macOS that writes like you meant it — and never sends your voice anywhere.**

Hold a key, speak, release. Punctuated, cleaned-up text lands at your cursor, in
whatever app you are using. Both models — the one that hears you and the one that
tidies what you said — run on your Mac.

```
you say:   let's meet at 2, actually 3
you get:   Let's meet at 3.

you say:   i invited marco lucia and tom to dinner
you get:   I invited Marco, Lucia, and Tom to dinner.
```

*(Both produced by `Kalamos --selftest-cleanup`, which you can run yourself.)*

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

Self-corrections are the part worth trying first, because it is the one thing no
amount of punctuation logic can fake. Say *"let's meet at 2, actually 3"* and you
get **"Let's meet at 3."** — the abandoned half is dropped and everything else
survives. But say *"it's not bad, actually it's excellent"* and both halves stay,
because there the same word reinforces instead of retracting. The model has to
read the meaning to tell those apart, which is why this needs a real model rather
than a list of rules. It works the same in Italian (*anzi, cioè no, volevo dire*)
and French (*plutôt, enfin non*).

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

First run downloads about 6 GB of models. After that, nothing.

## Which models for your Mac

Two models are loaded: one that hears you, one that cleans up what you said. On
Apple Silicon they live in unified memory, shared with everything else you have
open — so the number that matters is your **total RAM**, and the sum of the two.

Both are swappable from **menu ▸ Speech Model** and **menu ▸ Cleanup ▸ AI Model**.
Switching frees the old one immediately and loads the new one on your next
dictation; no rebuild, no reinstall.

| Your Mac | Cleanup model | Speech model | Loaded together |
|---|---|---|---|
| **8 GB** | Qwen2.5 3B (~1.8 GB) | Small | ~2.5 GB |
| **16 GB** | Qwen2.5 7B (~4.3 GB) | Turbo (1.6 GB) | ~6 GB — **the defaults** |
| **24 GB** | Qwen2.5 7B, or 14B if you like | Turbo or Large v3 | 6–10 GB |
| **32 GB+** | Qwen2.5 14B (~8 GB) | Large v3 | ~11 GB |

Three things make this less scary than the table looks.

**It is a peak, not a resting cost.** Both models unload themselves after the idle
timeout — 5 minutes by default, yours to change under **Advanced ▸ Unload Models
After**, including *Never*. When you are not dictating, Kalamos holds almost
nothing. The reload costs about a second.

**On 8 GB, prefer the smaller model over no model.** Measured against the 7B on
the same seven cases, Qwen 3B got every self-correction right — but on a long
run-on it added five punctuation marks where the 7B added fifteen, once left a
sentence without its closing period, and once dropped a trailing clause outright.
Weaker where it matters most, then, but still a far better trade than running the
7B and swapping to disk. Check it yourself:

```sh
Kalamos --selftest-punct --model mlx-community/Qwen2.5-3B-Instruct-4bit
```

**You can also just turn the LLM off.** **Cleanup ▸ Rule-based (instant)** uses no
model at all: spoken punctuation commands, filler removal, capitalisation. Zero
extra RAM, zero wait. You lose the self-correction handling, which is the part
worth having.

The bigger speech model is rarely the upgrade people expect: Turbo is the default
because on dictation-length audio it is nearly as accurate as Large v3 and several
times faster. Reach for Large v3 for accents or noisy rooms, not by reflex.

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
