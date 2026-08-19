<div align="center">
  <img src="docs/icon.png" width="180" height="180" alt="Kalamos icon: a reed pen and the ink stroke it has just left">
  <h1>Kalamos</h1>
  <p><strong>Local-only dictation for macOS that writes like you meant it, and checks the model's work against what you actually said.</strong></p>
</div>

<p align="center">
  <a href="https://github.com/xmasyx/kalamos/releases/latest"><img src="https://img.shields.io/github/v/release/xmasyx/kalamos?style=flat-square&color=2F5C8A" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/silicon-Apple%20M1%2B-fa4e49?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/cloud-none-2F5C8A?style=flat-square" alt="No cloud">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT"></a>
</p>

Hold a key, speak, release. Punctuated, cleaned-up text lands at your cursor, in
whatever app you are using. Every model it uses runs on your Mac.

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

Tuesday at ten is *gone*, not punctuated into the sentence. The fillers dropped,
"api" became "API", one breathless run-on became two sentences. Every example in
this repository is real output, and you can reproduce any of them:

```sh
Kalamos --clean "the meeting is on tuesday at ten no wait wednesday at ten thirty"
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xmasyx/kalamos/main/Scripts/install.sh | bash
```

Requires **macOS 14+ on Apple Silicon** (M1 or newer): transcription runs on the
Neural Engine, which Intel Macs do not have. Builds are unsigned, so the installer
clears the quarantine flag — read the script first, and see
[what macOS will say and why](docs/using-it.md#what-macos-will-say-and-why).

Removing it: `install.sh --uninstall`, or `--purge` to take the downloaded models
and settings with it.

## What it does

It lives in the menu bar. What you reach for while working is one click down: the
dictation language, the last transcription, the words you have taught it.

<img src="docs/screenshots/menu-bar.png" width="380" alt="The Kalamos menu open in the macOS menu bar: the app name and its status, the engine and language it is listening with, and the actions below">

**It checks its own output.** The dangerous failure of a cleanup model is not a
typo, it is the sentence that comes back reading better while meaning something
else: a dropped condition, a missing "not", a rounded number. Those get refused
rather than typed. No other dictation app does this, and it is the reason this one
exists — [the whole argument, with the failure cases](docs/why.md).

**Punctuation lands in 28 milliseconds, 118× faster than the language model it
replaced, and it is the most accurate of every path measured.** F1 against 40
sentences punctuated by hand from a style guide, with the time each path adds to a
dictation:

| Punctuating with | Added time | `.` | `,` | `?` |
|---|---|---|---|---|
| Rules alone | 0 ms | 48.3 | 0.0 | 0.0 |
| A 7B language model | 3,300 ms<br>0.96 – 9.36 s | 72.6 | 53.8 | 50.0 |
| Whisper's own marks | 0 ms | 72.6 | 62.3 | 88.5 |
| **Kalamos today** | **28 ms**<br>never past 70 | **85.9**<br>**+18%** | **78.4**<br>**+26%** | **91.2**<br>**+3%** |

The percentages are against **Whisper's own marks**, not against the language
model, because the free option was never worse than the 7B on any mark and far
better on commas and question marks. Improving on it costs 28 ms.

**The second column is the one to read twice.** The language model's cost grew with
the sentence: on the bench corpus it ran from 0.96 s on a short one to **9.36 s** on
a long one, so the longer the thought you had just spoken, the longer you sat there.
The classifier does not care — it stayed between 6 and 70 ms across the same corpus.
A human starts noticing a delay at around 100 ms, so the punctuated text is simply
*there* when you release the key, whether you said four words or eighty. Across
twenty dictations a day, the old path spent **66 seconds** waiting. This one spends
**0.6**.

**And punctuation is only half of it.** Whisper transcribes what you said, faithfully
— which means it keeps every *sort of*, *like*, *I mean*, *and so on*. Measured over
**386 real Italian dictations** from one Mac's archive, comparing Whisper's raw
output to what Kalamos typed: **180 were changed**, 67 filler words were cut, and
the delivered text came out **0.3% shorter** while gaining all its punctuation.
Spoken self-corrections are resolved by rule at **87.6%** recall with **zero**
legitimate words removed — the 7B model managed 70.1%, and to get there it deleted
64 words you had actually said and invented 44 you had not.

**Long dictations keep their words.** Speaking for two minutes without stopping used
to cost you the odd word, in two different ways, both now fixed and both measured on
a 120-recording archive: a last word said quietly was shaved off with the trailing
silence (**46 words lost, now 8**), and a rare re-decode could drop a stretch in the
middle (**47 words out of 90 on one pass in eight, now zero in 24**). Say the whole
paragraph.

**It also gave you 4 GB of memory back.** Dictating used to hold Whisper *and* a 4 GB
language model resident, about 5.5 GB of weights. Today dictation loads Whisper
alone: **1.5 GB**, measured as Activity Monitor measures it. That saving is the 7B
not being there, not a change of speech engine. The language model is
still there for the two jobs only it can do, rewriting a selection and translating as
you dictate, and it is loaded when you ask for those and not before. [How the 28 ms path is put together,
and the two alternatives measured and thrown away](docs/engines-and-models.md).

**It resolves what you take back mid-sentence.** *"We should ship on Friday, I mean
Monday, because Friday is a public holiday"* becomes **"We should ship on Monday
because Friday is a public holiday."** The wrong day goes, the reason for it
survives. Works the same in Italian and French.

**It learns your words, two ways.** A word misheard the same way every time is a
correction, applied to the raw transcript before anything else. A term mangled
differently every time is vocabulary, weighed in context by the model. Select a
word anywhere on your Mac and press ⌃⌥L to teach it without opening a window: the
dictionary grows while you work, and the transcription gets more precise as it
does. A few other ⌃⌥ shortcuts do the same for the rest of the daily loop, and the
menu bar lists them with their keys.

![Preferences, Words and corrections: a list of terms Kalamos should always get right, and a list of what it hears mapped to what it should type](docs/screenshots/preferences-words.png)

**It rewrites text you already have.** Select any text, hold the edit key, say how
to change it, and it is rewritten in place. **It translates on device**: dictate in
Italian and get English at the cursor, same model, nothing leaves the Mac.

**Nothing is lost, and you can go back and listen.** ⌃⌥V opens every dictation you
have made, with search and filters, the audio next to the text, and playback at
0.5/1/1.25/1.5× with volume past the original when you spoke too quietly. Correcting
a line there is not cosmetic: the correction feeds the words it learns from, so the
next transcription is better for having been wrong once.

**You can see it listening, and you decide where.** A wave shows while the
microphone is open: hanging from the notch as a band that continues the hardware,
or as a small pill above the Dock. It is always draggable, from anywhere on it —
drop it near either of those two spots and it snaps and stays there; drop it
anywhere else and that is where it lives from then on. The wave follows the audio
already being recorded; it listens to nothing extra.

**And it fits the Mac you own.** First run reads the chip, the memory, the cores
and the free disk, then proposes the models that fit and shows you the figure that
decided each choice. Accept and setup is two pages shorter.

![First run, Your Mac: the machine it read, and the speech model, cleanup model and memory policy it proposes, each with the figure behind it](docs/screenshots/setup-your-mac.png)

## Privacy, and how to check it rather than believe it

There is no cloud path here. No account, no API key field, no cloud toggle, no
server to point at. The single outbound request in the app's life is the model
download on first run; after that it works with the network off.

*Local-first* is the polite way of saying a cloud path exists and you are not using
it today. This is **local-only**, and you can prove it yourself with one grep:
[verifying the privacy claim](docs/privacy.md). What touches your disk, precisely,
is in [what this project commits to](docs/commitments.md).

## Engines and models

Three speech engines, switchable in Preferences, all on device.

| Engine | What it runs | Pick it when |
|---|---|---|
| **Whisper** (WhisperKit, Core ML) — default | four model sizes from a menu | the default: it keeps the most words on a long dictation, and it learns your words before it guesses |
| **Parakeet** (FluidAudio) | one model, 461 MB | you want the smallest download and the fastest answer |

There was a third, a **whisper.cpp** engine, from 5 to 19 August 2026. It was added
for two things Core ML could not do then, both were fixed somewhere else, and a
head-to-head on twenty real dictations found nothing left to prefer. Which cleanup
model your Mac can hold, and the measurements behind all of it, including what would
bring that engine back: [engines and models](docs/engines-and-models.md).

## Documentation

- [Using it](docs/using-it.md) — the trigger, Edit Mode, spoken punctuation, translation, nothing is ever lost, troubleshooting
- [Why it exists](docs/why.md) — the crowded shelf, the net under the model, and what is deliberately not here
- [Engines and models](docs/engines-and-models.md) — the three engines with numbers, and what your Mac can run
- [Privacy](docs/privacy.md) — check the claim yourself
- [What it commits to](docs/commitments.md) — enforced by code or checkable by you
- [Architecture](docs/architecture.md) — how it is put together

## Build from source

```sh
git clone https://github.com/xmasyx/kalamos.git && cd kalamos
./Scripts/build-app.sh
```

Needs full Xcode: the Metal shader compiler for MLX ships with it and not with the
Command Line Tools.

## Status

Working, and used daily by its author. Not code-signed or notarized, hence the
quarantine step. Three interface languages so far; adding one is mostly a matter of
teaching it that language's Whisper hallucinations and self-correction markers.

Bug reports and pull requests are welcome. For a cleanup problem, attach the
`--doctor` output and what you said versus what you got.

## Credits

Built on [WhisperKit](https://github.com/argmaxinc/WhisperKit) and
[FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device speech, and
[MLX](https://github.com/ml-explore/mlx-swift-examples) for the on-device language
model. None of those projects are affiliated with this one.

## License

MIT — see [LICENSE](LICENSE).
