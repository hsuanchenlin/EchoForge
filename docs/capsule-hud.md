# The floating capsule HUD

One pill at the top of the screen that says what the app is doing with the user's
voice: how loud they are, how long they have been talking, what will happen to the
words, and - once the audio stops - how the transcription is getting on.

It is **on by default** and it is an **alternative** to the indicator card, never
an addition to it. `Settings → Shortcuts → Recording Behavior → Floating capsule
HUD` is where it is turned off, and a stored answer wins: the default only fills
in for an install that has never expressed one.

The default is on because this is the overlay that can be seen. It sits at a
fixed place at the top of the screen, where the card is a small badge beside a
caret nobody is looking at while they are talking - so a dictation that stalled,
one that heard nothing, and one being polished all looked the same to a user who
had never gone looking for the setting. Turning it on adds nothing to the screen;
it moves what was already there.

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
| `.polishing(.transcribing)` | mode chip, spinner, "Transcribing…", cancel | when the text arrives |
| `.polishing(.rewriting)` | mode chip, spinner, "Polishing…", cancel | when the text arrives |
| `.awaitingChannelChoice` | mode chip, list icon, "Choose a channel" | when the channel picker resolves |
| `.complete` | green checkmark, "Inserted" | after 1.5 s |
| `.error(message)` | orange badge, one sentence | after 3.0 s |

`.awaitingChannelChoice` is the YouTube command whose spoken name missed and put
the channel picker up (`docs/youtube-latest-video.md`): the decode is over and
the wait is the user's, so the pill shows no spinner and no timer - the picker's
own outcome ends the session, and `complete()` is refused there because a picker
wait has no text to claim was inserted.

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

The chip names what is about to happen to the words: `Dictate`, the style the
transcript is about to be rewritten into (`Polish`, `Formal`, `Bullets`, …), or
- once the words exist - the spoken command they turned out to be (`Ask`,
`Translate Spanish`, `Snippet: email signoff` - or plain `Snippet` past the
trigger-length cap `docs/voice-snippets.md` explains). A session the YouTube
command key started (`docs/youtube-latest-video.md`) is chipped `YouTube` from
`beginSession` on - the key already said what the words are for, so the chip
never promises a rewrite - and the channel the user named joins it during the
decode (`YouTube: Veritasium`, or plain `YouTube` past the same
trigger-length cap). A voice edit (`docs/selection-edit.md`) is chipped the
same way and for the same reason, `Selection` or `Clipboard` from
`beginSession` on: its key already said the spoken words are an instruction
about text that is already written, so nothing during the decode renames it.
Style labels are
`StyleRewriteStyle.shortName` and language names come from `LanguageUtil`,
because those files own every user-facing word about a style and a language,
and a surface that shortens `name` itself is a second copy that drifts.

It is resolved from `StyleRewriteConfiguration.isRunnable` **and**
`StyleRewriteAvailability.canRun`, the same two answers the pipeline resolves it
from, so a chip never promises a rewrite that is not going to happen - the
enabled-but-empty custom prompt, and the Mac with no on-device model. That second
half is why availability is a parameter of `CapsuleHUDMode.forStyleRewrite`
rather than something it reads: rewriting is on by default now, so a Mac that
cannot run the model arrives here with a perfectly runnable configuration on
every dictation, and a `Polish` chip over words that are only ever going to be
pasted plain is exactly what the chip exists not to say.

When the style is chosen by the app being dictated into rather than in Settings
(`docs/app-aware-style.md`), the chip names the matched style - that is where a
user finds out that this dictation is going to be `Casual` and not `Concise`.
Both the chip and the pipeline resolve against the same
`IndicatorViewModel.dictationTarget`, captured once when the session started, so
they cannot disagree about which app it was.

**A spoken command is the one thing the chip cannot know at `beginSession`.**
Everything else is read from preferences before the recording starts;
"Ask: …" only exists once the transcript does. So `setMode` renames the chip
during the decode - which is why the chip is drawn in `.polishing` as well as
while recording - and is refused unless the capsule is showing **its own**
`.polishing(.transcribing)`. `SpokenIntentActivity` is global, exactly like
`StyleRewriteActivity`, so without that scope a queue transcription's routing
would relabel a recording still in progress. `docs/spoken-intents.md` is the
router's story.

A dictation that turned out to be a question ends on `DictationResult.asked`,
which the capsule shows as no badge at all: the Ask panel is on screen with the
question and the answer on it, and a checkmark reading "Inserted" over the top
of it would be saying something that did not happen. `DictationResult.openedVideo`
gets the same reading, for the same reason: Chrome is in front of the user with
the video on it.

## The level meter

`AudioRecorder.inputLevel` is published only between
`setLevelMonitoring(enabled: true)` and `false`, which the capsule brackets its
own life with. It is not free: a 20 Hz timer on the recorder's work queue plus one
main-thread publish per tick, for the whole recording. A build with the HUD
switched off pays nothing for it.

`AudioRecorder.normalizedLevel(decibels:)` is linear in decibels, not in
amplitude, and `MicrophoneLevel.decibels(forNormalized:)` is its inverse for the
callers that think in bar heights. Speech at a normal distance averages about -20 dBFS and
`pow(10, -20/20)` is 0.1 - a meter that barely moves while someone is talking.
Scaled from `levelSilenceDecibels` (-50 dB, roughly a quiet room on a built-in
mic) the same speech fills about 60 % of the bar.

## Microphone diagnostics

A level meter confirms that *something* arrived. It cannot say that the wrong
input is selected, that a headset came up on its call profile, or that the user
is too far from the machine - and those are three of the ways a dictation quietly
comes back wrong. `MicrophoneSignal` is what the app is willing to say about it,
and `MicrophoneSignalMonitor` is the pure state machine that decides.

| State | The pill | Raised when |
| --- | --- | --- |
| `.measuring` | nothing - the ordinary meter | for the first 1.5 s of every capture |
| `.good` | nothing - the ordinary meter | ordinary speech |
| `.noSignal` | orange meter, `No signal · <input>` | nothing above -42 dBFS has arrived *at any point* |
| `.low` | ordinary meter, `Low signal · <input>` | the loudest peak of the capture is under -28 dBFS |
| `.clipping` | orange meter, `Clipping · <input>` | a buffer peaked at or above -1 dBFS |

`AudioRecorder.inputLevel` carries the mean **and** the peak
(`MicrophoneLevel`), because the two questions are different measurements: mean
power answers "is anything arriving, and is it loud enough", and only the peak
answers "is this being clipped". A voice peaking at 0 dBFS between syllables
averages out around -18 dBFS, which reads as a healthy recording right up until
the transcript comes back full of crushed consonants. Both travel in one
published value, so a tick still costs one main-queue hop.

Four rules keep this from becoming noise:

- **Nothing is claimed inside the grace period.** The opening moments of a
  capture are when a Bluetooth input is still reaching gain and the user has not
  started talking. Clipping is the only exception, because it is the one state
  that is already damaging the recording.
- **The verdict is about the whole capture, not the last moment.**
  `loudestPeak` only grows, so somebody who says a sentence and then thinks is
  never told their microphone went silent. `No signal` means what it says.
- **A merely quiet recording is not painted as a warning.** Only `noSignal` and
  `clipping` change the meter's colour; `low` keeps the accent. A warning colour
  on every quiet dictation is a warning colour nobody reads. And colour never
  carries any of it alone - the line beside the meter says the same thing in
  words.
- **Nothing is refused.** The user may be deliberately whispering. A recording
  the app declined because it disagreed about the volume would be worse than a
  quiet transcript.

The diagnostic line names the **input device**, because "no signal" is not
actionable until the user knows which microphone the app is on - and they are
dictating into another app and cannot go and look. The name is taken once, at
`beginSession`, so a device changed mid-dictation cannot rename the one this
capture is actually running on, and it truncates rather than widening the pill
past the panel that contains it.

The line is **not clickable**, and that is the panel rule rather than an
omission: `ignoresMouseEvents` is on for the whole recording, and a HUD that
swallowed clicks would take the top strip of the screen away from the app being
dictated into. Acting on a diagnostic lives in Settings → Setup Health, which has
the five-second microphone test beside it.

For VoiceOver the capsule is invisible - it is a panel that never becomes key, so
there is no focus move to follow, the same hole `EngineSwitchAccessibility`
fills. `CapsuleHUDViewModel.onSignalDiagnostic` posts an announcement instead,
**on entry only and once per state per session**: the meter publishes twenty
readings a second, and twenty announcements a second is the one way this feature
could do harm.

The pill grows a second line for this, from `capsuleHeight` to
`expandedCapsuleHeight`, and it grows **downwards**: `pillTopInset` pins the top
inside the panel, because the panel's transparent top margin deliberately
overlaps the menu bar and a centred pill would climb into it. `EngineSwitchHUD`
clears the expanded height for the same reason - a capsule reporting a microphone
problem is exactly the one that must not be covered up.

`CapsuleHUDRenderTests` draws all of it offscreen and reads it back, because the
states worth looking at are the ones that need a broken microphone to produce.

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
