# Why Kalamos exists, and what it does not trust

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
that yourself with one grep: see [Privacy](privacy.md).

## What this project commits to

These are not aspirations. Each one is either enforced by the code or checkable
by you, and [Privacy](privacy.md) tells you how to check.

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

