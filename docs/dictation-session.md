# The dictation session

One dictation, from the press that claims the microphone to the words landing in
whatever the user was typing in. `OpenSuperWhisper/Dictation/` is the whole of
it: `DictationSession` does the work, `DictationPhase` is what it says about
itself while it does, and `DictationSessionPorts.swift` is what it needs from
the rest of the app.

This is the hotkey path only - ⌥\`, ⌥Y, ⌥E, the modifier-only and mouse-button
triggers, and the menu bar item. The main window's record button
(`ContentViewModel`) still has its own smaller copy of the same shape and is not
on this module yet.

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
`IndicatorViewModel` is the card: it follows the session's phase, derives the
`RecordingState` the card draws, and runs the timers. `DictationSessionTests`
is what the extraction bought - the rules below, stated against fakes.

## What the overlays see

```
ShortcutManager  ──► IndicatorWindowManager.prepare()
                          │  builds IndicatorViewModel, which builds the session
                          ▼
                     DictationSession ── @Published phase ──► IndicatorViewModel
                                      └─ @Published liveTranscript ─┘   │
                                                                        ▼
                                              RecordingState ──► the card
                                                             └─► CapsuleHUDViewModel
```

`DictationPhase` is the session's own account: `idle`, `connecting`,
`recording`, `decoding`, `awaitingChannelChoice`, and `ended(DictationNotice?)`.
A `nil` notice means the session ended with nothing to add - every ordinary
success, and every cancel, because the user knows what they did. A notice is
the short line they still have to read, and **how long it stays on screen is not
the session's business**: `IndicatorViewModel` owns that timer, because it is a
property of an overlay rather than of a recording.

`RecordingState` is still the card's vocabulary and is derived one-to-one from
`DictationNotice` (`RecordingState.init(_:)` in `Indicator/IndicatorWindow.swift`).
The capsule follows `RecordingState` through `IndicatorViewModel.state`, so
`CapsuleHUDViewModel.follow` is unchanged - see `docs/capsule-hud.md`.

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

**The microphone is owned.** Every recording is a `RecordingSession` claimed
from `AudioRecorder`, and every stop and cancel names the session it means. A
`failedStart` belonging to another key's capture is ignored.
(`RecordingSessionClaim`, `docs/ask-panel.md`)

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

`ContentViewModel` still holds a second, smaller copy of this orchestration for
the main window's record button. Moving it onto `DictationSession` is the
obvious next step and is out of scope here; until it happens, a rule that has to
hold in both places - `DictationFailureOutcome` is the one that already did -
belongs in a type both can reach.
