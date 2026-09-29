# The dictation session

One dictation, from the press that claims the microphone to the words landing in
whatever the user was typing in. `OpenSuperWhisper/Dictation/` owns the
orchestration: `DictationSession` does the work, `DictationPhase` is what it says
about itself while it does, and `DictationSessionPorts.swift` is what it needs
from the rest of the app. `RecordingCapture` owns one microphone capture from
start through stop or cancel.

This module serves the hotkey paths - ⌥\`, ⌥Y, ⌥E, the modifier-only and
mouse-button triggers, and the menu bar item - plus the main window's record
button and the Ask panel's voice follow-up. `DictationDelivery` keeps their
destinations distinct: insertion, history only, or the Ask panel.

## Why it is its own module

It used to be `IndicatorViewModel.startDecoding`: about 260 lines inside the
dictation card's view model, sharing an object with a blink timer, a
two-second auto-dismiss timer and an Esc confirmation window. A piece of work
with a beginning and an end had been put in the same type as a thing on screen
with animations, and the consequence was not aesthetic - it was that **every
rule the orchestration holds could only be reached through a real microphone,
a real engine and a real `Timer`.** The busy rule, the live fallback table,
keep-versus-discard, what a cancel means on each path: all of them were
asserted, when at all, by reading the source.

The split is by lifetime. `DictationSession` is the dictation.
`IndicatorViewModel` is the card: it follows the session's phase, draws it,
and runs the timers. `DictationSessionTests` is what the extraction bought -
the rules below, stated against fakes.

## What the overlays see

```
ShortcutManager  ──► IndicatorWindowManager.prepare()
                          │  builds IndicatorViewModel, which builds the session
                          ▼
                     DictationSession ── @Published phase ──► IndicatorViewModel
                                      ├─ @Published liveTranscript      │
                                      └─ @Published intentOutcome       │
                                                                        ▼
                                              DictationPhase ──► the card
                                                             └─► CapsuleHUDViewModel.follow(_:)
```

`DictationPhase` is the session's own account: `idle`, `connecting`,
`recording`, `decoding(.transcribing)` / `decoding(.rewriting)`,
`awaitingChannelChoice`, and
`ended(DictationNotice?, DictationResult?)`. A `nil` notice means the session
ended with nothing to add - every ordinary success, and every cancel, because
the user knows what they did. The optional result lets the capsule distinguish
success, silence, cancellation, and transcription failure without a second
input. A notice is the short line they still have to read, and **how long it
stays on screen is not the session's business**: `IndicatorViewModel` owns that
timer, because it is a property of an overlay rather than of a recording.

The card draws `DictationPhase` directly. The capsule follows the same phase
through `CapsuleHUDViewModel.follow(_:)`: `.decoding(.rewriting)` is
"Polishing…", a notice becomes the error badge, and `.ended(nil, result)`
supplies the outcome directly. The chip rename for a spoken command comes from
this session's `intentOutcome`, which `finish(raw:settings:progress:)` fills
in - see `docs/capsule-hud.md`.

`DictationSessionRegistry.current` is the one answer to "is a dictation
running?" Five ways of starting one and three of stopping one all ask it;
`ShortcutManager` used to keep that answer privately.

## The ports

`DictationSessionPorts.swift` states what one dictation needs as narrow
protocols - the microphone, the engine, history, the queue, the insertion, the
Ask panel, the voice-edit rewrite, the duration of a file, and the live decoder.
Each production conformance is one line over the singleton that already existed,
so nothing about the app's wiring changed. `N4` of the architecture review -
making `RecordingStore` and `TranscriptionQueue` constructible - is deliberately
**not** done here; the adapters make it unnecessary for this step.

## The rules it holds

Each of these is one test in `DictationSessionTests`.

**The microphone is owned.** Every recording is a `RecordingCapture` claimed
from `AudioRecorder`, and every stop and cancel names the session it means. A
failed start belonging to another key's capture cannot reach this one: the
handle itself is the report.
(`RecordingCapture`, `RecordingSessionClaim`, `docs/ask-panel.md`)

**The busy rule, and what it does with the audio.** A start refused because a
transcription is running keeps nothing (`.busy(.startRefused)`). A *stop* while
busy keeps the audio and queues it (`.busy(.audioQueued)`) - except a voice
edit, whose words are an instruction about a selection that will be gone by the
time the queue reaches them, so it is refused and the audio deleted. The busy
check comes **after** the live check, because a live session's own utterance
decode raises `isTranscribing` exactly like a queue item does.
(`docs/live-dictation.md`)

**Every live failure is a fallback.** `LiveDictationOutcome.committed` finishes
the joined text and never decodes the file; every `LiveDictationFallbackReason`
decodes the WAV whole, exactly as the dictation would have gone without a live
session, and none of them is shown to the user. A live session still
`.unavailable` at the stop is dropped, which puts the dictation back on the
whole-file path - busy rule included. (`docs/live-dictation.md`)

**A failure the user can fix keeps their audio.** `DictationFailureOutcome` is
the one rule and is shared with the main window; the kept recording carries the
sentence that says what to do, and the overlay carries the two words that fit.
Everything else discards. (`docs/history-storage.md`)

**A cancel means two different things.** On the whole-file path it interrupts
the engine. On the live path it does not: the frame in flight may belong to a
queued file this dictation is waiting behind, so `didCancelWorkInFlight` is set
and the finished work is simply refused. Either way nothing is pasted and no row
is written. (`docs/live-dictation.md`)

**What the press captured decides what happens to the words.** The purpose, the
target app and the selected text are read once, at the start. A spoken question
goes to the Ask panel and is pasted nowhere; a `.youTubeCommand` capture can
only ever open an allowlisted channel; a `.selectionEdit` capture pastes the
rewrite of the captured text and never the spoken instruction.
(`docs/spoken-intents.md`, `docs/selection-edit.md`, `docs/youtube-latest-video.md`)

## What is left

The main window's record button and the Ask panel's voice follow-up already
run on `DictationSession` (`delivery: .historyOnly` / `.toPanel`). Pipeline
progress (rewriting, spoken-intent routing) is reported through
`TranscriptionService.finish(raw:settings:progress:)` onto this session's
`phase` and `intentOutcome`. A typed history change stream is still
outstanding.
