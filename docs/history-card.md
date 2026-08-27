# The history card

The main window's list of recordings, one card per row: `OpenSuperWhisper/History/`.
`RecordingRow` draws a card, `HistoryRowLayout.swift` holds every decision the card
makes about *how* rather than *what*, and `HistoryProvenanceBadge` supplies the pill
that says what produced the row (`docs/history-provenance.md`).

## Two layouts, one threshold

A card carries four independent things - what produced it, when, how long, and the
words - plus a bar of actions. At the width the window opens at (`ContentView` pins
`minWidth: 400`) there is no room to put those on one line; at the width a user drags
it out to there is far too much room to keep stacking them. So there are exactly two
layouts, and `HistoryWidthTier` picks between them at **480 pt of list width**.

Two tiers rather than a formula over the width, because two layouts can each be
designed, rendered and asserted on where a continuous formula can only be eyeballed.
`HistoryRowMetrics` is the whole table - padding, corner radius, spacing, action glyph
and hit-target size, and the three booleans the card branches on. **Nothing in the view
body may hard-code a measurement the metrics table does not name**: that is what keeps
both tiers designed in one place instead of drifting apart in scattered `if`s.
`HistoryRowLayoutTests` reads the table back; `HistoryRowRenderTests` draws both sides
of the threshold and reads the pixels.

| | compact (< 480 pt) | regular (>= 480 pt) |
|---|---|---|
| metadata chips | stacked under the badge | inline, trailing the badge |
| footer date | clock time only | full date and time |
| action bar | wraps to its own line when the footer is tight | always on the footer row |

The width is measured **once, at the list** (`historyRowMetricsForContainerWidth()`)
and published to every row through the environment. Measuring inside each row would
put a `GeometryReader` in a `LazyVStack` cell, reporting the width that cell's own
height then depends on - which is how a history list starts jittering as it scrolls.

Where a header could still collide at some width or dynamic type size, the card uses
`ViewThatFits` and stacks rather than truncating. A truncated timestamp tells the user
nothing at all, so nothing on the card is allowed to truncate except a source file name
(middle-truncated, deliberately) and a collapsed transcript (three lines, with "Show
more" under it).

## Actions

`HistoryRowActionKind.available(for:)` is a pure function of the recording's status,
and it is read **twice**: once to draw the hover bar, once to register the same actions
with VoiceOver. Hover is a pointer affordance and a VoiceOver user has no pointer, so a
bar that were the only route to delete would be no route at all - and two hand-written
copies of the same four actions is how one of them silently loses a case.

Which actions a state offers is not cosmetic. A row that is still queued or running has
nothing to play and nothing to copy, but keeps **delete**, which is the way out. A row
that failed keeps **regenerate**, which is the way forward - `DictationFailureOutcome`
keeps that audio precisely so the second press is possible. `HistoryRowActionTests`
pins all of it.

## Colour

Every colour comes from `ThemePalette`, per scheme, and none of them carries meaning on
its own. The failed card has a warm border *and* a badge that says "Transcription
failed" in words; the destructive action tints under the pointer *and* is labelled
"Delete recording". Dark mode is not a filter over the light one - the card fill, the
border and the failure tint are each chosen for their own ground, because a soft grey
shadow over a dark surface reads as a smudge and system red on a dark ground vibrates.
