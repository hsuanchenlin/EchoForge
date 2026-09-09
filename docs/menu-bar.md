# The menu bar

`OpenSuperWhisper/MenuBar/` is the status item: what the app is doing, and the
handful of things worth doing without opening a window.

It replaces a menu that opened the app, chose a language, chose a microphone and
quit. Those four items answered none of the questions a user has *between*
dictations - which engine is running, whether it is ready, what key is live,
whether anything was inserted - and every one of them was only visible by opening
the main window, which for a menu-bar-only install means bringing the whole app
forward.

## The icon is three silhouettes and never animates

| State | Icon |
| --- | --- |
| Recording | the mark with a filled dot below it |
| Shortcuts paused, permission needed, no engine | the mark with two upright bars |
| Everything else | the mark |

A menu-bar icon that moves is one that is noticed all day, and the app has
nothing to say continuously. What it has is three facts a glance should answer:
it is listening, it is not going to answer a key press, or it is fine. A model
downloading in the background is deliberately **not** one of them - dictation
carries on, so it keeps the ordinary icon and says so inside the menu.

`Scripts/GenerateTrayIcon.swift` is the artwork and
`Scripts/generate_tray_icon.sh` renders the three PDFs, which are committed. The
mark is the same Speech Ripple as the app icon, drawn to the same rules
(symmetric, no microphone, open arcs rather than rings). It replaces a leftover
upstream bear silhouette that matched neither the old EchoForge icon nor the
current one.

Two things about the drawing are worth knowing before editing it. A **PDF context
cannot erase** - `.clear` is not a blend mode PDF can express and CoreGraphics
paints the shape opaque instead - so the badge sits in geometry that is already
empty: the ripples are open at the top and the bottom, and the gap under the core
is where both badges go. And the badge is what changes between states, not the
mark: `TrayIconArtworkTests` reads the *committed* files and fails if a state
redraws the mark, if a badge runs into it, or if the artwork was edited without
being regenerated.

A slash was tried twice for the paused state and measured at the size the icon is
actually shown. Across the whole mark it filled the gaps between the arcs and came
out as a blob at 36 pixels; over the core alone, with the echo dropped, the
clearance ate most of the core and the icon read as a pen. Eighteen points hold
two elements, not four.

## What the menu holds

```
Ready                                   ← MenuBarState.title
────────────────────────────────
Start Dictation                    ⌥`   ← the trigger in force, as a badge
Pause Kongweh Shortcuts
────────────────────────────────
Engine                ▸  SenseVoice-Small
Language              ▸  Chinese
Microphone            ▸  MacBook Pro Microphone
────────────────────────────────
Recent
  把 PR 開到 feature/login…       ▸  Copy / Open in History
  …
────────────────────────────────
History…  Settings…  About Kongweh…  Quit Kongweh
```

`MenuBarState.resolve` decides the first line, and the order is the product
decision:

1. **What is happening now** - recording, then processing - wins over what is
   wrong, because a user who is mid-dictation can see for themselves that their
   permissions are fine.
2. **A missing permission** and then **no engine at all**, because neither can be
   fixed from this menu.
3. **A pause**, which can.
4. **A model preparing**, last, because it is the only state in the list that
   stops nothing.

The engine submenu shows the engine the user **chose** and, when they differ, the
one dictation is actually running on - the `EngineSelection` split, said the same
way Setup Health says it. The engines it offers come from `EngineCycle.available`,
so a pick can only land on something that could transcribe the next dictation, and
the pick is carried out by `EngineSelectionCommand` - the same call the Settings
picker and ⌥M make. Picking is disabled while a dictation is in flight, for the
reason ⌥M defers rather than switching: the words already spoken belong to the
model they were spoken to.

## Pause means the shortcuts

**It never touches the microphone.** A dictation app that silently muted the
machine would be doing something to a resource it does not own, and the person who
pressed it would find out in their next meeting. The menu says so under the item
while it is on.

What it does is stand the triggers down: the six global shortcuts are
unregistered and the modifier-key and mouse-button monitors are stopped, so while
it is paused ⌥` types a backtick again. Gating the handlers instead would leave
the app swallowing keystrokes it had just promised to stop listening to. `.escape`
is deliberately left alone, so a session already in flight when the pause happens
is still cancellable.

**It is not persisted.** A paused install that came back paused after a relaunch
is an app that looks broken, with one menu-bar icon as the only clue. Quitting is
therefore also the way out of a pause somebody forgot about. The state is visible
in the icon and in the menu's first line for as long as it lasts, which is the
session.

## Recent transcripts

The last three, one line each, from `MenuBarTranscript`. Two rules decide which
rows qualify: it has to have **finished with words** - a failed or pending row has
nothing to copy - and it has to be a row whose transcript is *text the user
wanted*. A YouTube command's transcript is a channel name that was spoken to open
a video and an Ask capture's is a question whose answer is not in that column at
all; Copy on either would hand back nonsense.

Previews collapse newlines and runs of whitespace and are cut to 46 characters,
because a menu item draws a newline as a box and an uncut one widens the whole
menu to somebody's longest paragraph. **Copy puts the whole transcript on the
pasteboard**, not the line that was shown.

On privacy: a menu can only be opened by somebody at an unlocked Mac, which is
what makes showing text here acceptable at all. Nothing on this path reaches a
notification, a lock screen, or anything that outlives the open menu.

Each row is a submenu with Copy and Open in History rather than a click that
copies: two named actions are discoverable, and replacing somebody's pasteboard
the instant they brush a menu row is not a thing to do by accident.

## How it is built

`MenuBarController` decides nothing. `MenuBarState` resolves the status,
`MenuBarTranscript` decides which rows may be shown and cuts them,
`EngineCycle` decides which engines a pick may land on, and
`EngineSelectionCommand` carries a pick out. What lives in the controller is the
AppKit.

The **menu is rebuilt on open** (`menuNeedsUpdate`), so nothing has to keep a
dozen `NSMenuItem`s in sync with published state and nothing is recomputed while
nobody is looking. The **icon follows live**, because it is on screen the whole
time - that is the one thing a status item is for.

`MenuBarSnapshotTests` is the state matrix, asserted without a microphone, a model
or a TCC grant.
