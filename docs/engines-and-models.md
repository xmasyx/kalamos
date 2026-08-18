# The two engines, and the models your Mac can run

## Two engines, and why you would pick each

| Engine | What it runs | Pick it when |
|---|---|---|
| **Whisper** (WhisperKit, Core ML) | four model sizes you choose from a menu | the default. You want to swap model size, or the best accuracy on names and jargon |
| **Parakeet** (FluidAudio) | one model, 461 MB | you want the smallest download and the fastest answer, and your vocabulary has no unusual names in it |

Nothing is locked in: the choice is one row in Preferences, and switching takes
effect on your next dictation.

![Preferences, Dictation: the trigger key, how dictation starts, the dictation language, and on-device translation](screenshots/preferences-dictation.png)

## There used to be a third, and why it is gone

Kalamos shipped a **whisper.cpp** engine from 5 August to 19 August 2026. It ran the
*same* Whisper large-v3-turbo weights as the default engine, on a different machine
(C and Metal instead of Core ML), and it was added for two specific things Core ML
could not do at the time. Both were then solved somewhere else, which is the whole
reason it could leave.

**One: your vocabulary could only repair, never prevent.** Whisper accepts an
*initial prompt* — words handed to the decoder before it guesses. Through WhisperKit
that channel returned an empty transcription: 48 times out of 48 on 16 real
recordings, a known upstream defect (WhisperKit issue #372). Through whisper.cpp it
worked. **Upstream then fixed it:** WhisperKit 1.1.0, 6 August 2026, lists
`promptTokens` among its bug fixes; Kalamos moved to that version on 8 August and
re-measured — 0 empty transcriptions out of 160, and the word list takes `Kalamos`
from 0/5 to 5/5 through Core ML exactly as it did through whisper.cpp.

**Two: long audio drifted.** The same file, decoded eight times through WhisperKit,
gave word counts swinging by 11 and by 31; whisper.cpp gave 200 identical texts over
200 passes. But the drift was **ours**, not the library's: Kalamos trimmed the silence
at the *start* of a recording, which shifts everything said afterwards against the
30-second decode windows, by a different amount every time, and a sentence landing on
a seam disappears. Only the trailing silence is trimmed since 16 August, and the
reference sentence came back.

**And when both reasons were gone, the head-to-head said nothing was left.** Twenty
real dictations, both engines, same vocabulary and same forced language: verdict
*not confirmed* — no measured advantage either way on ordinary use.

So it was removed on 19 August. Not because it was bad, but because a third engine
that wins nothing still costs something specific: it arrived as a **prebuilt binary
framework downloaded at build time**, which is a strange thing to carry in an app
whose whole claim is that you can see what runs on your machine.

**What would bring it back** is written next to the code that used to call it: that
48-out-of-48. If the Core ML prompt channel ever regresses, the vocabulary stops
being able to prevent mistakes, and the engine that could is one `git revert` away.

One measured surprise from that period, kept because it still governs how the
vocabulary works today: **a long prompt damages the very words it contains.** With
sixteen terms in the prompt, `endomidollare` — present in the prompt — came out
`endomi-dollare`. With three, it came out right. So Kalamos does not hand over your
whole list: it decodes once, looks at what came back, and re-decodes with only the
words that look wrong, at most five. The second pass costs about a third of a second,
and only on the dictations that need it.

## Which models your Mac can run

**You do not have to work this out.** First run reads the chip, the memory, the
cores and the free disk, proposes what fits, and shows you the number that decided
each choice. Accept it and setup is two pages shorter; say *I'll choose* and every
page opens.

![First run, Your Mac: the machine it read, and the speech model, cleanup model and memory policy it proposes, each with the figure behind it](screenshots/setup-your-mac.png)

The cleanup model is a choice, not a requirement. Setup offers the local model, or
rule-based punctuation that costs nothing and downloads nothing, or the exact words
you said with no tidying at all.

![First run: use the local model, punctuation only, or nothing, with the model recommended for this Mac named underneath](screenshots/setup-cleanup.png)

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

![First run: free the memory after 5 minutes, after 15, or never, with the amount the two chosen models hold stated above and the recommendation for this Mac underneath](screenshots/setup-memory.png)

The figure in that sentence is the sum of the two models **you** were just
proposed, not an average: choose punctuation-only cleanup and it drops, take the
small model on a 8 GB Mac and it drops again.

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

