# Text post-processing

How transcribed text is formatted between the engine and the user.

## The pipeline

```
AudioRecorder / file drop
        │
        ▼
TranscriptionEngine.transcribeAudio()      WhisperEngine | FluidAudioEngine
        │                                  ParaformerEngine | SenseVoiceEngine
        │                                  engine-specific cleanup
        │                                  (marker stripping, trimming)
        │                                  and joining pieces (CommittedTranscript)
        │                                  Whisper alone is also shown the personal
        │                                  terms *before* decoding, as its initial
        │                                  prompt - see docs/personal-terms.md -
        │                                  followed by whatever the app being
        │                                  dictated into contributes, when that is
        │                                  switched on: docs/app-vocabulary.md
        ▼
TranscriptionService.decodeRaw()           the engine and nothing after it
        │
        ▼
TranscriptionService.finish()              single choke point: every stage
        │                                  below runs here and nowhere else
        ▼
TextPostProcessor.process()                TRANSCRIPT STAGE
        │                                  shared by every engine and caller
        │                                  1. Chinese output script (Traditional
        │                                     by default, Chinese text only)
        │                                  2. spoken corrections ("scratch that",
        │                                     "replace X with Y") - live dictation
        │                                     only, off by default
        │                                     see docs/spoken-corrections.md
        │                                  3. personal terms  (on by default)
        │                                  4. CJK autocorrect (protected spans held out)
        ▼
SpokenIntentPipeline.apply()               SPOKEN-COMMAND ROUTING
        │                                  live dictation only, off by default
        │                                  "Translate to …" runs TranslationRewrite,
        │                                  "Ask: …" goes to the Ask panel unpasted,
        │                                  "insert [trigger]" expands a voice snippet
        │                                  and skips the stage below entirely
        │                                  a YouTube command capture (⌥Y, its own
        │                                  key) leaves here before any of that,
        │                                  and so does a voice-edit capture (⌥E)
        │                                  see docs/spoken-intents.md,
        │                                  docs/voice-snippets.md,
        │                                  docs/youtube-latest-video.md,
        │                                  docs/selection-edit.md
        ▼
StyleRewriteService.apply()                REWRITING STAGE
        │                                  ON by default (polish), on-device model
        │                                  guarded; falls back to the text above
        │                                  see docs/style-rewriting.md
        ├──────────────┬───────────────────────────────┐
        ▼              ▼                               ▼
IndicatorWindow   TranscriptionQueue              ContentView
 (live dictation)  (file / drop queue)           (in-window recorder)
        │              │                               │
        │              └── stores in Recording ────────┘
        ▼
TextPostProcessor.prepareForInsertion()    INSERTION STAGE
        │                                  live dictation output only
        ▼
ClipboardUtil                              pasted and/or copied per preferences
```

## Three stages, deliberately separate

**Transcript stage** (`TextPostProcessor.process`) is formatting that belongs to
the transcription itself. It must be identical no matter which engine produced
the text or how it will be consumed, so it runs exactly once, in
`TranscriptionService`. Its output is what gets stored in `Recording`,
displayed in history, and searched.

It does four things, in this order:

1. **The Chinese output script**: a Chinese transcript is written in the script
   the user chose - Traditional by default - whichever one the engine returned.
   Deterministic ICU, no model and no network, and a no-op for every language
   that is not Chinese. See `docs/chinese-script.md`.
2. **Spoken corrections**: what the speaker took back - "scratch that", "delete
   the last sentence", "replace Friday with Monday", "start over" - plus optional
   hesitation-sound pruning. Off by default, and only for live dictation: a
   dropped file is somebody's recording and a ⌥E instruction is the instruction.
   See `docs/spoken-corrections.md`.
3. **The personal terms dictionary**, gated on `safeCorrectionEnabled` (default
   on) and nothing else - no language gate, no model, no network. See
   `docs/personal-terms.md`.
4. **CJK/Latin spacing** via the vendored `autocorrect` library, gated on an
   Asian language being selected *and* the user preference being enabled
   (`Settings.shouldApplyAsianAutocorrect`).

The order is load-bearing all the way through. Script normalization runs first
because it converts **the recognizer's words and never the user's**: everything
below it splices in text the user typed themselves - a dictionary entry, and
later a snippet template - and those are inserted in the script they were stored
in. Corrections run second, on normalized text, so their trigger tables need the
user's own script and nothing else - and *before* the dictionary, because the
dictionary hands back character ranges an edit would invalidate and splices in
words the user typed, which a retraction has no business reading as a trigger.
Terms are then applied before spacing so they match what the user actually said,
and the spans they marked never-correct are held out of autocorrect so a pinned
term is not respaced afterwards. A term still matches across the scripts either
way, because the matcher compares script-folded text (`ChineseScriptFolding`).

**Spoken-command routing** (`SpokenIntentPipeline.apply`) sits between the
transcript stage and the rewriting stage, and is a decision rather than a stage:
it picks what runs in the rewriting stage's place. For ordinary dictation - and
for every caller that never asked for routing - it *is* the rewriting stage, at
the cost of a prefix comparison. A live dictation that starts with a spoken
command runs `TranslationRewrite` instead, inserts a stored voice snippet with
no model consulted (`docs/voice-snippets.md`), or runs nothing at all for a
question, which `StyledTranscript.intent` marks so the text goes to the Ask
panel and is never pasted. A capture from the **YouTube command key** is not a
dictation at all and leaves this stage before any of that runs: nothing is
restyled and nothing is pasted, and the intent carries the channel to the caller,
which opens the video in Chrome or says why it could not
(`docs/youtube-latest-video.md`). `docs/spoken-intents.md` is the whole story.

**Rewriting stage** (`StyleRewriteService.apply`) calls a language model and can
change what the words mean - a power only it and its sibling
`TranslationRewrite` have. It is on by default with the polishing style - the one
that changes the user's words least - needs an on-device model most Macs running
this app do not have, and returns the transcript stage's output unchanged
whenever it is off, unavailable, too slow, or produces something its guard
refuses. That last clause is what makes the default safe: on a Mac without the
model the user gets exactly what they got before the stage existed. It is a peer
of the terms dictionary and never its parent. `docs/style-rewriting.md` is the
whole story.

It is separate from `TextPostProcessor` because that type is deterministic,
synchronous and cannot fail, and this one is asynchronous, has a deadline and
fails routinely. Merging them would give the deterministic stages an
`async throws` signature and a failure mode they do not have.

**Insertion stage** (`TextPostProcessor.prepareForInsertion`) is formatting for
text emitted by the live dictation path. Today it appends a trailing space after
punctuation so consecutive pasted dictations do not run together in the target
app. The live path applies it before honoring the user's paste and copy
preferences, preserving the existing behavior when output is copied without
being pasted.

This stage is **not** part of the stored transcript, and that is intentional.
Only the live dictation indicator applies this stage. The queue, the in-window
recorder and the history "Copy entire text" button all read stored text, so none
of them applies it.

## Why it is centralised

Both stages used to be scattered. `AutocorrectWrapper.format` was called
separately inside `WhisperEngine` and `FluidAudioEngine`, so a third engine
could ship without it and nobody would notice; the trailing-space rule lived
inside a SwiftUI view model. Neither had tests covering both consumption paths.

Centralising them means:

- adding an engine cannot accidentally skip transcript formatting,
- the difference between the queue and live paths is one explicit call site
  rather than an accident of where code happened to live,
- both stages are directly unit-testable.

`TextPostProcessorTests` pins the behaviour of both stages, including the
deliberate asymmetry.

## Adding a stage

Transcript-level formatting goes in `process`. Live-output affordances go in
`prepareForInsertion`. If a change would alter what is stored in `Recording`, it
belongs in the transcript stage and needs a test asserting both consumption
paths agree.

`process` returns `ProcessedText`, which carries the engine's raw output
alongside the final text. `raw` is what lets the rewriting stage show the user
what they originally said and fall back to it, and it is what
`Recording.rawTranscription` stores; it would have been impossible to retrofit
once the raw text had been dropped at the engine boundary.

`ProcessedText.mustSurviveTokens` is what the terms dictionary corrected or
pinned. `StyleRewriteGuard` reads it: a rewrite that does not still contain
every one of them is refused, whatever style asked for it.

`ProcessedText.corrections` is what the spoken-correction stage did, as typed
operations rather than a diff - the kind, the trigger, what was removed and what
replaced it - and is nil when the stage did not run, so "no corrections were
made" cannot be read as "corrections were never considered".

`TranscriptionService.transcribeAudio` therefore returns `StyledTranscript`
rather than a string. Once a stage can rewrite the user's words, "the text" is
two texts - what was said and what the app made of it - and a caller handed only
the second one cannot keep the first.

`transcribeAudio` is two named halves run inside one serialised transcription:
`decodeRaw(url:settings:)` is the engine and nothing after it, and
`finish(raw:settings:)` is every stage above, run once over a raw transcript.
The halves exist so that a caller can decode pieces of a dictation separately
and finish the joined text once - the stages run over a whole transcript, never
over a piece - and `TranscriptionDecodeAndFinishTests` holds them to it: a decode
returns the engine's words byte for byte, and a decode shares the engine's
serialisation and cancellation with whole-file work rather than running beside it.
