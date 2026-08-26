# App-aware style mapping

A dictation into Slack and a dictation into a mail composer are not the same
piece of writing, and a person switching between them changes register without
thinking about it. This feature does that switch: the style
[style rewriting](style-rewriting.md) runs is chosen from the app the words are
going into, rather than being one setting for the whole day.

It is off by default (`appAwareStyleEnabled`), and it does nothing at all while
style rewriting itself is off. Turning it on is in **Settings → Style**, under
the style list, because it is an exception to the choice made there rather than a
second way to make it.

## What it is allowed to know

**The frontmost application's bundle identifier. Nothing else.**

No window title, no document name, no web address, no page content, no list of
running apps, no accessibility tree. `NSWorkspace.shared.frontmostApplication?
.bundleIdentifier` is the one system call in the feature and
`bundleIdentifier` is the only property read off it. Nothing is sent anywhere -
the whole resolution is a dictionary lookup on this Mac - and nothing is logged,
including the identifier itself.

That is not a policy sitting on top of the code, it is the shape of the code:

- `FrontmostApplicationReading` has exactly one member, so there is no other
  channel through which anything about the frontmost app can arrive.
- `DictationTargetApp` has exactly one stored property, so there is nowhere for a
  title or an address to be carried even by accident.
- What is persisted is bundle identifiers, `AppCategory` raw values and
  `StyleRewriteCatalog` identifiers, so nothing read off a window could be
  written to disk.

`AppStyleMappingTests` asserts all three, and additionally reads
`AppDetector.swift` and `AppStyleMapping.swift` looking for window-title,
document, address, network and logging APIs. Adding one fails a test.

The browser default falls out of the same rule. A browser window is a mail
client, a chat client, a code review and a text editor on four tabs, and the only
thing that would tell them apart is the address of the page. So browsers are a
recognized category whose built-in answer is *use the style the user chose*,
rather than a guess this app would have to look at a URL to make. A user who
lives in one web app can set a rule for their browser by hand.

## The rules

`AppCategoryCatalog` is a hand-maintained table of bundle identifiers, in five
categories - chat, mail, code and terminals, documents and notes, browsers. An
app that is not in it has no category, and no category means the chosen style
stands. Identifiers are matched case-insensitively, because macOS treats
`com.apple.Mail` and `com.apple.mail` as one app.

`AppStyleMappingStore` resolves a dictation, in this order:

1. a rule the user set for that exact app,
2. the app's category (the user's per-category choice, or the built-in default),
3. the style chosen in Settings.

Built-in defaults: chat → `casual`, mail → `formal`, code and documents →
`polish`, browsers → the chosen style. Code and documents both get `polish`
because dictation there is a commit message, a comment or a paragraph, where the
wording is the user's own and only the grammar wants fixing; `bullets` would
restructure prose that was never a list. Both categories are still separately
settable, which is the point of having them apart.

Two asymmetries carry the design, and neither may be relaxed:

- A rule chooses **which** style runs, never **whether** one runs.
  `AppStyleMappingStore.configuration` passes `isEnabled` and the custom prompt
  through untouched, so no app can switch the model on for words the user did not
  agree to send it.
- Nothing here writes `styleRewriteStyleID`. The style the user *chose* and the
  style this dictation *uses* are two different values - the same separation
  `EngineSelector` keeps between the chosen engine and the one that can run - so
  a week of dictating into Slack never ends with "Casual Chat" selected in
  Settings.

A rule naming a style this build does not know (written by a newer build, or a
style since removed) resolves to the chosen style, and says so in its
`AppStyleSource`: the user's own choice is a better answer than a substitute.

## When the app is read

Once, when the dictation session starts - `IndicatorViewModel.dictationTarget`,
captured in its initializer. Not again at decode time: the text is going into
whatever the user was typing in when they pressed the shortcut, and by the time
the audio stops the frontmost app may be something they alt-tabbed to while
speaking.

That one capture is also what the capsule HUD's mode chip is resolved from, so
what the chip promised and what the pipeline did cannot disagree. See
[the capsule HUD](capsule-hud.md).

`Settings(dictationTarget:)` is the join. Its default is `nil`, which means
"no app has a say": a dropped file, a queued recording, a regenerate from
history, and dictation started from Kongweh's own window - the detector returns
`nil` for this app itself - all use the chosen style.

## Known limits

- A dictation that arrives while another transcription is running is queued
  (`TranscriptionQueue`), and the queue transcribes with the chosen style: the
  target is not carried through the recording row it is stored as. Rare, and the
  words still arrive.
- The category table is a list of apps someone wrote down. An app missing from it
  is not mis-categorized, it simply has no category, and a per-app rule fixes it
  in one click.
