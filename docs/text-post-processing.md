# Text post-processing

How transcribed text is formatted between the engine and the user.

## The pipeline

```
AudioRecorder / file drop
        │
        ▼
TranscriptionEngine.transcribeAudio()      WhisperEngine | FluidAudioEngine
        │                                  engine-specific cleanup only
        │                                  (marker stripping, trimming)
        ▼
TranscriptionService.transcribeAudio()     single choke point
        │
        ▼
TextPostProcessor.process()                TRANSCRIPT STAGE
        │                                  shared by every engine and caller
        │                                  1. personal terms  (on by default)
        │                                  2. CJK autocorrect (protected spans held out)
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

## Two stages, deliberately separate

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
alongside the final text. Only `final` is consumed today; `raw` exists because
any stage that can rewrite the user's words has to be able to show what they
originally said and fall back to it, and that is impossible to retrofit once the
raw text has been dropped at the engine boundary.

`ProcessedText.mustSurviveTokens` is there for the same reason: it is what the
terms dictionary corrected or pinned, and a stage that rewrites the transcript
would have to check its own output still contains all of it. Nothing consumes it
yet.
