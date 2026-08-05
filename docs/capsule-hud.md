# The floating capsule HUD

One pill at the top of the screen that says what the app is doing with the user's
voice: how loud they are, how long they have been talking, what will happen to the
words, and - once the audio stops - how the transcription is getting on.

It is off by default (`Settings → Shortcuts → Recording Behavior → Floating
capsule HUD`) and it is an **alternative** to the indicator card, never an
addition to it.

## One overlay, not two

The card (`OpenSuperWhisper/Indicator/`) and the capsule
(`OpenSuperWhisper/CapsuleHUD/`) are two presentations of the same dictation.
Showing both would be duplicated feedback rather than more of it, so
`IndicatorWindowManager` picks one, once, when the session starts:

```
ShortcutManager.handleKeyDown()
        │
        ▼
IndicatorWindowManager.prepare()          reads capsuleHUDEnabled ONCE
        │                                 → sessionUsesCapsule
        ├── false ──► ensureWindowContent()            the card
        └── true  ──► CapsuleHUDWindowController
                          .beginSession(for: vm)       the capsule
        │
        ▼
IndicatorViewModel.startRecording()       the dictation itself, unchanged
        │
        ▼
IndicatorWindowManager.presentWindow(for:nearPoint:)
        │                                 card: anchored to the caret
        │                                 capsule: top-centre of that screen
        ▼
   … recording → decoding → outcome …
        │
        ▼
IndicatorWindowManager.hide()
        ├── card:    await animateHide()
        └── capsule: endSession(result:)   badge outlives the session
```

`sessionUsesCapsule` is read once on purpose: a preference flipped mid-recording
would otherwise leave a session showing both overlays or neither.

Nothing in `CapsuleHUD/` starts, stops or alters a dictation. The single
exception is the cancel button, which asks `IndicatorWindowManager` to cancel the
work the capsule is currently reporting on.

## What it shows

| State | The pill | Goes away |
| --- | --- | --- |
| `.connecting` | mode chip, spinner, "Connecting…" | when capture starts |
| `.recording` | mode chip, level meter, `m:ss` | when the audio stops |
| `.recording` + confirmation | mode chip, "Press Esc to cancel", countdown bar | when the window lapses |
| `.polishing(.transcribing)` | spinner, "Transcribing…", cancel | when the text arrives |
| `.polishing(.rewriting)` | spinner, "Polishing…", cancel | when the text arrives |
| `.complete` | green checkmark, "Inserted" | after 1.5 s |
| `.error(message)` | orange badge, one sentence | after 3.0 s |

`CapsuleHUDViewModel` is the whole state machine and holds no AppKit: the panel,
the dictation and the clock are all outside it, which is what makes the badge
durations and the transitions testable without a window server, a microphone or a
real 1.5 second wait. `CapsuleHUDViewModelTests` is that test.

Four rules in it are load-bearing:

- **`complete()` is ignored unless a session is in flight.** A cancelled
  dictation, or one already showing why it stopped, must not end on a checkmark.
- **A scheduled auto-hide belongs to the state that scheduled it.** 1.5 seconds is
  long enough for the user to start talking again, and a hide left over from the
  previous dictation would take the fresh capsule off the screen. Every transition
  moves a generation counter that the pending hide checks.
- **`endWithoutBadge()` leaves a badge alone.** When a session ends while a
  message is up, that message's own timer owns the rest of its life.
- **A rewrite may only follow this session's own decode.**
  `StyleRewriteActivity` is global - the transcription queue's rewrites (file
  drop, open-with, history regenerate) raise it too, and a `@Published` replays
  one already in flight at subscription time - so `beginPolishing(.rewriting)`
  is refused unless the capsule is already showing `.polishing(.transcribing)`.

The Esc cancel-confirmation is the session's, not the capsule's:
`IndicatorViewModel` runs the same state machine for both overlays and the
capsule only mirrors `isConfirmingCancel`, swapping the meter for "Press Esc to
cancel" over the card's own `CancelConfirmationBar` countdown.

`DictationResult` (in `Indicator/IndicatorWindow.swift`) is what the outcome is
read from. The card never needed it - it decodes, hides, and says nothing either
way - but a HUD has to tell a silent recording and a failed transcription apart
from a successful one. `.inserted` carries `StyleRewriteStatus.explanation` when
a promised rewrite kept the original - refused by the guard, timed out, failed -
and the capsule tells that story as the `.error` badge; the text itself is
inserted and stored exactly as a plain success is.

## The mode chip

EchoForge dictates; it does not translate or answer questions. So the chip names
what this app actually has: `Dictate`, or the style the transcript is about to be
rewritten into (`Polish`, `Formal`, `Bullets`, …). The label is
`StyleRewriteStyle.shortName`, because `StyleRewriteCatalog` owns every
user-facing word about a style and a surface that shortens `name` itself is a
second copy that drifts.

It is resolved from `StyleRewriteConfiguration.isRunnable`, the same way the
pipeline resolves it, so a chip never promises a rewrite that is not going to
happen - including the enabled-but-empty custom prompt.

## The level meter

`AudioRecorder.inputLevel` is published only between
`setLevelMonitoring(enabled: true)` and `false`, which the capsule brackets its
own life with. It is not free: a 20 Hz timer on the recorder's work queue plus one
main-thread publish per tick, for the whole recording. A build with the HUD
switched off pays nothing for it.

`AudioRecorder.normalizedLevel(decibels:)` is linear in decibels, not in
amplitude. Speech at a normal distance averages about -20 dBFS and
`pow(10, -20/20)` is 0.1 - a meter that barely moves while someone is talking.
Scaled from `levelSilenceDecibels` (-50 dB, roughly a quiet room on a built-in
mic) the same speech fills about 60 % of the bar.

## Why it is drawn the way it is

The perf constraints are the ones `IndicatorWindow` documents, and they apply
harder here because two things move continuously:

- The **duration** redraws itself from a `TimelineView` against
  `recordingStartedAt`. Publishing an elapsed time instead would rebuild the whole
  capsule - material, meter and all - at the timer's rate.
- The **meter** is plain fills and nothing else: no gradients, no shadows, no
  material inside the part that changes 20 times a second.
- The **pulse** on "Transcribing…" is opacity only, which Core Animation
  interpolates on the layer, so the text is rasterized once however long the wait.
- Appearing and disappearing is a window `alphaValue` fade rather than an animated
  SwiftUI `scaleEffect`: compositing an already-drawn window is a GPU operation,
  and re-rasterizing a blur material for every frame of a spring is not.

## The panel

`CapsuleHUDPanel` refuses key and main status, and the panel is
`.nonactivatingPanel`. That is load-bearing rather than tidy: the last thing a
dictation does is paste into whatever app the user was typing in, so a HUD that
took focus on its way up would change the target of the paste it is reporting on.
The cancel button still works - mouse events do not require key status.

`ignoresMouseEvents` is on except while the capsule is polishing. A HUD that
swallowed clicks for the whole recording would take the top strip of the screen
away from the app underneath it.
