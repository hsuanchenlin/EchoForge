# The Ask panel

A floating card that answers a question on this Mac. Opened with **⌥A**, by
dictating "Ask: …" with spoken commands switched on
(`docs/spoken-intents.md`), or with **⌥S** to ask about what is on screen
(`docs/screen-context.md`).

**⌥A records.** The press opens the panel *and* starts the microphone, the way
the dictation key, the YouTube command key and ⌥S all do; a second press ends
the question. It is deliberately no longer a show/hide toggle - a key that
closed an open panel could not also be a key that always starts listening - so
the panel is closed with Esc, the **Close** button, or by discarding the
recording. `AskPanelWindowController.shortcutAction` is that whole rule, pure
and testable, and `AskVoiceShortcutTests` holds it.

For one release it was not: ⌥A reached `present()` and stopped, which put an
idle card on screen with an **Ask by voice** button the user had to find with
the mouse. Every other listening path in the app reaches a call that starts a
capture on the same press - `startVoiceFollowUp` here, `startScreenQuery` for
⌥S, `IndicatorViewModel.startRecording` for the two dictation keys - and this
one reached none of them. That is the shape to check first if it ever looks
broken again: a panel that appears is not a panel that is recording.

Everything about it is on device: it runs the same Apple `FoundationModels`
system model the rewriting stage does, for the same reason - dictation is the
most private thing this app touches, and a feature that mailed a spoken
question to a third party by default is not a trade this app makes.

## The pieces

```
OpenSuperWhisper/Ask/
├── AskService.swift            asking the model, with a deadline
├── AskPanelViewModel.swift     the state machine  (tested)
├── AskPanelView.swift          the card
└── AskPanelWindowController.swift   the panel, the pasteboard, the microphone
```

The split is the same one `CapsuleHUD/` makes: everything the panel *decides*
is in the view model, free of AppKit, so every transition is testable without a
window server or an on-device model - including the ones that cannot be
requested from a real model, like a timeout. `AskPanelViewModelTests` is that
test.

## What it shows

| State | The card | Reached by |
| --- | --- | --- |
| `.idle` | what to do | opening it |
| `.listening` | red mic, "Listening…", Stop | **⌥A**, or **Ask by voice** |
| `.transcribing` | spinner, "Transcribing…" | Stop |
| `.thinking(question:)` | the question, spinner, "Thinking…" | asking |
| (any of the above) | a screenshot thumbnail above the question | **⌥S** |
| `.answered(exchange)` | the question and the answer card | the model replying |
| `.failed(message, question)` | the question, an orange badge, one sentence | anything going wrong |

Four actions: **Copy**, **Insert** (into the app you were last using), **Ask by
voice**, **Close** (also Esc).

A failure carries **what was asked** as well as what went wrong, and shows it.
A spoken question exists nowhere else - the user never typed it, and nothing
stores it - so a card that answered a mis-heard question with a bare sentence
left them unable to tell a misheard question from a model that could not run.
A failure with no question behind it (nothing heard, no microphone) carries
`nil` and says only the sentence.

Two rules in the view model carry it:

- **An answer belongs to the question that asked for it.** The panel can be
  closed, reset or asked something else while the model is working, and a late
  answer must not land on top of whatever replaced it. A generation counter -
  the same device `CapsuleHUDViewModel` uses for its auto-hides - makes that a
  fact rather than a hope.
- **Nothing leaves the panel on its own.** Copying and inserting are closures
  the controller supplies and the user triggers. The view model has no idea what
  a pasteboard is.

A question can also carry a **screenshot** (`AskRequest.screen`), which is what
⌥S adds. Its presence - not a flag - is what routes the question to a
`VisionEngine` instead of the plain answerer, so a question asked about a screen
can never be answered without it. `docs/screen-context.md` is that feature's
whole story.

## Why there is no guard

`StyleRewriteGuard` exists because a rewrite replaces the user's own words on
their way into another application, with nobody reading them first. An answer is
read first, by definition: it is drawn on a card the user is looking at, and it
reaches another app only when they press **Insert**. So the answer is shown
exactly as the model produced it, trimmed and nothing else.

The prompt is correspondingly different. `StyleRewritePrompt` tells the model
that the transcript is content and never instruction; here the user's words
*are* the instruction, and that is the whole feature.

## Focus, and where Insert puts things

This panel takes keyboard focus - the YouTube channel picker
(`docs/youtube-latest-video.md`) is the only other surface that does. It has to:
a question box that cannot receive a keystroke is not a question box, and
keyboard input goes to the *active* application, which this one normally is not.
So opening the panel activates Kongweh and makes the panel key - the opposite of
what `CapsuleHUDPanel` and `IndicatorWindow` do, and for the opposite reason.

The activation is **forced** (`activate(ignoringOtherApps:)`), for the reason
`YouTubeChannelPickerWindowController` measured: macOS grants a background
process the right to activate only just after the user has given it attention,
and this app is given none - a global hotkey press goes to the system rather
than into this app's event stream, and a spoken "Ask: …" opens the panel later
still, after a recording and a transcription. With a plain `activate()` the card
appears over the frontmost app, never becomes key, and Esc and every keystroke
go to that app instead. Same trade as the picker, tolerable for the same
reason: the panel is only ever here because the user pressed a key of their own
or said so.

That is exactly what makes **Insert into Active App** the interesting part. The
application the user was working in is captured **before** the panel opens
(`NSWorkspace.frontmostApplication`, and nothing else about it), brought back
with `activate()`, and the paste is synthesized after
`AskPanelWindowController.activationDelay`. Without that wait the Cmd+V arrives
while this panel still has focus and the answer is pasted into the question
field.

The target is remembered for one presentation only. Closing the panel hands
keyboard focus back to it - the same hand-back Insert does, so Esc puts the
user's keystrokes back in the document they came from - and then forgets it,
so a panel opened later from Kongweh's own window has no target at all: the
answer goes to the clipboard and nowhere else. Guessing where to paste is the
one thing this must not do, which is also why a target that cannot come
forward - quit while the panel was open - degrades to the clipboard rather
than to a paste into whatever happens to be frontmost.

## The voice follow-up

The same path whether it was started by **⌥A** or by the **Ask by voice**
button - the shortcut requests the capture through `startVoiceFollowUp` rather
than around it, which is what makes the privacy, cancellation, error and
recording-lifecycle behaviour of the two identical by construction rather than
by agreement.

It records through `AudioRecorder` and transcribes through
`TranscriptionService`, but deliberately **not** through
`IndicatorWindowManager`. That machinery exists to paste into another app, and
this recording is a question for the panel that is already on screen - so the
panel shows its own listening state and no indicator or capsule appears.

The follow-up's own transcription
(`AskPanelWindowController.followUpTranscriptionSettings`) keeps routing off -
a follow-up that began "Ask: …" must not be routed back into the panel it came
from - and pins the style rewrite off whatever the user's preference says: a
question is not a dictation to restyle, and restyling it on its way to the
model that is about to answer it changes what was asked. The deterministic
stages (personal terms, CJK spacing) still run.

Conversation history is written into the prompt (`AskPrompt.prompt(for:)`)
rather than kept in a live `LanguageModelSession`, because the panel outlives
any one session - it can be left open across dictations - and a stored session
created when the Mac was in a different state is harder to reason about than a
string built each time. Only the most recent `AskService.maximumHistoryExchanges`
exchanges are written: an unbounded conversation would rebuild exactly the
overrun `maximumQuestionCharacters` exists to prevent. The conversation lives
only while the panel does: nothing here is written to the database or anywhere
else.

## Deadlines

`AskService.budget` is 30 seconds, against the rewriting stage's 3-12. That is
the difference between the two features rather than an inconsistency: a rewrite
is holding up a paste into another app, while this is a panel the user opened on
purpose and is sitting in front of. The ceiling exists so a wedged model ends in
a sentence rather than a spinner nobody can stop.

`AsyncDeadline` is the shared mechanism and documents why it is not a task
group - in short, a task group waits for its losing child, and the model call
has no documented cancellation behaviour, which would make the budget a
suggestion.

Questions over `AskService.maximumQuestionCharacters` are not put to the model
at all: they would overrun its context window and fail after spending the whole
budget.

## Availability

The same model, so the same answer: `StyleRewriterFactory.availability()`, and
the same sentence shown to the user. It needs macOS 26 and Apple Intelligence
while the app supports macOS 15.1, so the whole framework is behind
`#if canImport(FoundationModels)` as well as `@available` - which is what keeps
the project building against an SDK that predates it.

The model is pre-warmed when the panel opens, which is the moment the user is
about to wait for it.
