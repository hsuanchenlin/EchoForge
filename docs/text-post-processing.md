# Text post-processing

How transcribed text is formatted between the engine and the user.

## The pipeline

```
AudioRecorder / file drop
        │
        ▼
TranscriptionEngine.transcribeAudio()      WhisperEngine | FluidAudioEngine
        │                                  ParaformerEngine | SenseVoiceEngine
        │                                  engine-specific cleanup only
        │                                  (marker stripping, trimming, chunk joining)
        ▼
TranscriptionService.transcribeAudio()     single choke point
        │
        ▼
TextPostProcessor.process()                TRANSCRIPT STAGE
        │                                  shared by every engine and caller
        │                                  1. personal terms  (on by default)
        │                                  2. CJK autocorrect (protected spans held out)
        ▼
SpokenIntentPipeline.apply()               SPOKEN-COMMAND ROUTING
        │                                  live dictation only, off by default
        │                                  "Translate to …" runs TranslationRewrite,
        │                                  "Ask: …" goes to the Ask panel unpasted,
        │                                  "insert [trigger]" expands a voice snippet
        │                                  and skips the stage below entirely
        │                                  see docs/spoken-intents.md,
        │                                  docs/voice-snippets.md
        ▼
StyleRewriteService.apply()                REWRITING STAGE
        │                                  off by default, on-device model
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

It does two things, in this order:

1. **The personal terms dictionary**, gated on `safeCorrectionEnabled` (default
   on) and nothing else - no language gate, no model, no network. See
   `docs/personal-terms.md`.
2. **CJK/Latin spacing** via the vendored `autocorrect` library, gated on an
   Asian language being selected *and* the user preference being enabled
   (`Settings.shouldApplyAsianAutocorrect`).

The order is load-bearing, and so is the interaction between the two: terms are
applied first so they match what the user actually said, and the spans they
marked never-correct are then held out of autocorrect so a pinned term is not
respaced afterwards.

**Spoken-command routing** (`SpokenIntentPipeline.apply`) sits between the
transcript stage and the rewriting stage, and is a decision rather than a stage:
it picks which model-backed stage runs. For ordinary dictation - and for every
caller that never asked for routing - it *is* the rewriting stage, at the cost
of a prefix comparison. A live dictation that starts with a spoken command runs
`TranslationRewrite` instead, or nothing at all for a question, which
`StyledTranscript.intent` marks so the text goes to the Ask panel and is never
pasted. `docs/spoken-intents.md` is the whole story.

**Rewriting stage** (`StyleRewriteService.apply`) calls a language model and can
change what the words mean - a power only it and its sibling
`TranslationRewrite` have. It is off by default, needs an on-device model most
Macs running this app do not have, and returns the transcript stage's output
unchanged whenever it is off, unavailable, too slow, or produces something its
guard refuses. It is a peer of the terms
dictionary and never its parent. `docs/style-rewriting.md` is the whole story.

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

`TranscriptionService.transcribeAudio` therefore returns `StyledTranscript`
rather than a string. Once a stage can rewrite the user's words, "the text" is
two texts - what was said and what the app made of it - and a caller handed only
the second one cannot keep the first.
