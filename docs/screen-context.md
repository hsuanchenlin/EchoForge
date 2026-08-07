# Asking about the screen

**⌥S** takes a picture of the window you are looking at and starts recording a
question about it. The answer arrives on the Ask panel
(`docs/ask-panel.md`), with a thumbnail of exactly what was captured.

Everything is on this Mac: the screenshot is read by the Vision framework and
answered by the same Apple `FoundationModels` system model the rewriting stage
and the Ask panel use. Nothing is uploaded, and nothing is written to disk - not
the image, not the text read off it. The screenshot lives in memory for as long
as the conversation on the panel does, and goes when the panel closes.

## The pieces

```
OpenSuperWhisper/Utils/ScreenCaptureService.swift    ScreenCaptureKit, and which window   (tested)
OpenSuperWhisper/Vision/ScreenObservation.swift      the screenshot, and the size cap     (tested)
OpenSuperWhisper/Vision/VisionEngine.swift           reading it, and asking about it      (tested)
OpenSuperWhisper/Ask/…                               where the answer is shown
```

`ScreenCaptureServiceTests` and `VisionEngineTests` are the two suites. Neither
needs a window server, a Screen Recording grant or an on-device model, because
every rule lives behind a value type or an injected protocol - the same split
`docs/ask-panel.md` describes for the panel itself.

## The order of the shortcut

Three things happen on ⌥S, and the order is the feature:

1. **The frontmost application is read** - `NSWorkspace.frontmostApplication`,
   nothing else about it. This has to happen first, because step 3 activates
   EchoForge and after that *we* are the frontmost application.
2. **The capture starts**, before the panel is drawn, so the screenshot is of
   what the user was looking at rather than of the card that just appeared over
   it.
3. **The panel opens and the microphone starts.** Pressing ⌥S again stops the
   recording and asks the question, the same way the recording hotkey toggles.

The screenshot usually lands during the first fraction of a second of recording;
until it does the panel says "Capturing the screen…", and from then on it shows
the thumbnail. If the capture fails while the user is still speaking, the
recording is **stopped** rather than carried on with: the user asked about their
screen, and answering from the words alone would be a confident reply about
something nothing ever looked at. The same rule holds when the race goes the
other way - a spoken question that finishes transcribing before its screenshot
has arrived **waits** for the capture's own outcome, with a budget so a wedged
capture cannot hang the panel, and a capture that fails or never resolves fails
the query with its own sentence. A screen query is never answered blind.

## Which window

`ScreenCaptureTargetResolver` is a pure function over
`[CapturableWindow]`, and it has three rules, each of which is a bug without it:

- **Never this app.** EchoForge is frontmost by the time its own panel is up, and
  a screenshot of our own HUD answers nothing. Our windows are excluded whatever
  pid is asked for, and a *display* capture excludes our whole application from
  the `SCContentFilter` for the same reason.
- **Ordinary windows only.** Layer 0 is where documents live; the Dock, an open
  menu and every floating panel are above it.
- **The largest one.** An app usually has an inspector and a find bar on screen
  as well as the document, and the document is what the question is about.

No window fitting all three - a Finder-less desktop, an app with only a palette
open - falls back to capturing the main display.

## Permission

Screen Recording is **conditional**, exactly like Input Monitoring: it is read
when ⌥S is pressed and at no other time, it is not part of the polled permission
check, and `PermissionsManager.isMissingRequiredPermission` does not include it.
An install that never presses ⌥S never sees a prompt, and dictation is unchanged
on a Mac that has refused it.

macOS prompts once per app and never again, and has no API that says whether it
already did, so the app remembers having asked
(`screenRecordingAccessRequested`, written by the request itself). On the first
refused ⌥S the OS dialog is already on screen and is the one thing to act on:
the panel explains, and nothing else opens. Every later refusal has no dialog
left to show, so the panel's sentence points at System Settings and the pane is
opened - `AskPanelWindowController.screenRecordingRefusal` is that decision.
Note that a grant applies to the app bundle that asked for it - a fresh download
of EchoForge asks again.

## Why the engine is a protocol

`VisionEngine` takes an image and a question. The shipped implementation,
`ScreenContextVisionEngine`, is multimodal in signature and text in practice:

```
screenshot ──► ScreenshotDownscale ──► Vision OCR ──► ScreenQueryPrompt ──► FoundationModels
```

Apple's on-device `LanguageModelSession` accepts text prompts only, so the
picture is read by `VNRecognizeTextRequest` and the words are what the model
gets. That is a real limitation and it is worth naming: this answers questions
about **text on the screen** well, and questions about colour, layout or an
unlabelled image not at all. A backend that accepts pixels directly conforms to
`VisionEngine` and nothing above it changes - which is why the protocol is
shaped around the image rather than around the text.

Two details of the reading half are their own tested functions because they are
invisible when wrong:

- `ScreenTextLayout.readingOrder` sorts the recognized runs top to bottom and
  then left to right. Vision returns them in no guaranteed order, and a model
  handed a shuffled invoice answers confidently about the wrong number.
- `ScreenshotDownscale` caps the longest edge at 1560 px and never enlarges. The
  cap is applied at capture time, so the full-size image is never allocated, and
  again in the engine for an image that arrived from anywhere else.

## The screen is data, not instruction

`ScreenQueryPrompt` fences the recognized text and tells the model it is content,
the same way `StyleRewritePrompt` fences a transcript. This is the one place
where the Ask panel's own rule is reversed: on that panel the user's words *are*
the instruction and that is the whole feature, but a screen holds text somebody
else wrote - a web page, a chat message, a document - and "ignore your previous
instructions" is a sentence anybody can put on a screen.

That fence is a mitigation, not a guarantee, and it does not have to be one.
Like the Ask panel, and unlike the rewriting stage, this has **no
`StyleRewriteGuard`**: an answer is drawn on a card the user reads, and reaches
another application only when they press **Insert**. A rewrite is guarded because
it replaces the user's own words unread; nothing here does.

## What the panel shows

The thumbnail is shown rather than described. The whole risk of a screen query is
that it captured the wrong window, and a picture is the only way to see at a
glance that it did not. It stays with the exchange afterwards, so an answer three
questions back still says which screen it was about, and the caption names the
application and window title - and nothing else about them.

Three rules in `AskPanelViewModel` carry the rest, and all are pinned by
`AskPanelScreenQueryTests`:

- **A screenshot is used once.** It is cleared when the answer arrives - and
  when the query fails - so the next question the user types is about their
  words and not about a window they have moved on from.
- **A screenshot that arrives late belongs to nothing.** Every capture delivery
  quotes back the token of the query that started it, the same generation
  device the panel already applies to answers, so a capture landing after a
  cancel, a reset, a close or the start of an unrelated follow-up is dropped
  rather than attached to whatever replaced it.
- **A screen question is never asked without its screenshot.** A transcript
  that beats the capture waits for it, and a capture that fails - or never
  arrives inside the wait's budget - fails the question with its own message
  instead of letting it be answered blind.
