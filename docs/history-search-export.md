# History search and export

Two things a history full of transcripts has to be able to do: let the user find one,
and let the user take one out. Both are entirely local - nothing here reaches the
network, and nothing here asks a model anything.

- **Search** is `OpenSuperWhisper/History/HistorySearchQuery.swift` (what a typed phrase
  means) plus `RecordingStore.query(matching:searching:)` (the predicate it becomes),
  with the field itself in `ContentView`.
- **Export** is `OpenSuperWhisper/History/TranscriptExport.swift` (what a row is written
  as) plus `OpenSuperWhisper/History/TranscriptExportCoordinator.swift` (the press), with
  `HistoryRowActionKind.export` as the button `RecordingRow` draws.

## Search

### It runs in SQL, and that is the whole shape of it

History is **paged** - a hundred rows at a time - which is the same fact
`HistoryProvenanceFilter` is built around. A search that matched over the rows that
happen to be loaded would silently hide every older row that matches, which is the
opposite of what somebody hunting for last month's dictation is asking for. So the match
has to be a predicate SQLite can answer.

That is why `HistorySearchQuery` exists. Two of the things a card shows are neither
stored nor storable as text: the badge says **"Voice edit"** where the column says
`selectionEdit`, and the footer says **"Sep 4, 2026"** where the column holds an instant.
The query type resolves the typed phrase into the provenance kinds whose *on-screen
label* it names and the day, month or year it reads as - once per search, not once per
page - and the store turns those into predicates beside the substring match.

The phrase is ORed across five things and ANDed with the provenance filter beside it:

| What | Where it comes from |
| --- | --- |
| the transcript | `transcription` |
| what the engine heard | `rawTranscription`, the card's "Show original" disclosure |
| the sentence under the badge | `provenanceDetail` |
| the badge's own label | `HistorySearchQuery.provenanceKinds`, matched on `label` / `accessibilityLabel` |
| the date | `HistorySearchQuery.dateInterval`, a half-open range on `timestamp` |

ANDed with the filter, because choosing a kind should *narrow* a search rather than
replace it: a user who typed a word and then picked "Voice edit" wants the voice edits
carrying that word.

### What it never searches

`fileName` is an internal `UUID.wav` nobody has ever seen. `sourceFileURL` is an absolute
path on the user's disk, whose directory components have never been on a card - a match
on one would be an accident of where they keep their files, and one more way for a folder
name to show up in front of somebody. `HistorySearchStoreTests` pins both exclusions.

### Three details that are load-bearing

**The NULL arm, again.** A row written before provenance existed holds NULL, is shown as
"Older recording", and `provenanceKind IN (…)` is false for NULL - so typing those words
reaches it only through `matchesUnrecordedProvenance`. The same rule
`HistoryProvenanceFilter.includesUnrecorded` exists for.

**LIKE has wildcards and a search field does not.** Without `escapedForLike`, a user
typing `100%` would be asking for every row starting `100`, and one typing `_` for every
row at all.

**A phrase that is not a date carries no interval.** `HistoryDatePhrase` is a short,
closed list - an ISO day, a year and month, a bare year within a century of now, and the
localised date the footer itself prints - and everything else is left to the text match.
Guessing a range for a phrase it cannot read would quietly hide every row the words would
have found. Nothing there is relative, either: "yesterday" depends on the reader's locale
as much as on the clock, and a wrong guess would move a search a day without saying so.

### The field

Always on screen, so ⌘F moves focus into it rather than revealing anything - which is why
it is a key equivalent on a hidden button rather than a bar that appears. Typing is
debounced 200 ms and each search asks for one page, so a phrase over a long history never
stalls the keystroke that produced it; the read itself is `nonisolated` and runs on GRDB's
own queue. A no-results state says what was searched for and offers **Clear search**, the
one action back to everything - shared with the field's own ⓧ so a cancelled debounce
cannot survive one of them.

## Export

### The destination is the user's, always

The only writer is the URL `NSSavePanel` returned. Nothing is written beside the
recording, into Application Support, or anywhere the user did not point at; the panel's
own overwrite confirmation is the only overwrite there is. Nothing leaves the device -
there is no share sheet, no upload and no network call anywhere in this path.

`TranscriptExportCoordinator` is **app-lifetime, not row-lifetime**, for the reason
`TranscriptCorrectionCoordinator` is: history is a `LazyVStack`, so the card that opened
the panel is torn down the moment the user scrolls past it.

### The document states only what the card states

`TranscriptExport.Document` is built in one place, and that is what makes the rule a
property rather than a habit. It carries the transcript, the original behind "Show
original", the timestamp, the provenance badge and its sentence, the duration and the
"AI Polished" chip - and never the row's `id`, the internal audio file name, or the
absolute `sourceFileURL` path. A file the user is about to mail to somebody must not
carry the layout of their disk. `TranscriptExportTests` asserts each of those absences in
both formats.

The suggested file name is the date and the kind, in that order, so a folder of exports
sorts usefully - and nothing in it comes from the transcript, because the first words of
a dictation are exactly what a user would not want on a file name in a Finder window
behind them.

### The transcript is written verbatim

Markdown is the default and the transcript sits in a **fenced block**, which is the
load-bearing decision: a dictation is arbitrary text, so it will eventually contain a
`#`, a `*`, a `|` or a line of dashes, and prose would render those as somebody else's
headings, emphasis and tables. The fence is grown past the longest run of backticks in
the text, so a dictation *about* code cannot close it early. Plain text (`.txt`) is the
same facts with no markup, for destinations that have no reader.

Only the one-line field values are flattened, and only their newlines - the transcript
keeps every line break it was said with.

### Every outcome is answered

`TranscriptExportOutcome` has a case for each, and three of the four leave a sentence on
the card - inline and dismissible, the way a refused correction does, never an alert:

- **saved** - names the file, not the path the user navigated to.
- **cancelled** - says nothing. The user knows what they just did.
- **nothingToExport** - a row still running, a failed row, or a completed row with no
  words. It never reaches the panel; `HistoryRowActionKind.available` and
  `TranscriptExport.document(for:)` refuse it from both ends.
- **failed** - carries the system's own reason, which is the only description of a
  refused write the user can act on.

## Tests

| File | What it holds |
| --- | --- |
| `HistorySearchQueryTests` | what a phrase means: case, substring, the labels, the dates, and what is *not* a date |
| `HistorySearchStoreTests` | the predicate against a real database, including the NULL arm, LIKE escaping, and the two fields that are never searched |
| `TranscriptExportTests` | the serialiser: what is carried, what is never carried, Markdown syntax and backticks in a transcript, newlines, non-Latin text |
| `TranscriptExportCoordinatorTests` | the press: cancelled, refused, empty and written, with the panel and the write injected |
| `HistoryRowActionTests` | that only a finished row with words is offered an export |
| `HistoryRowRenderTests` | the card with an export note on it, and a row found by its badge or its words |
