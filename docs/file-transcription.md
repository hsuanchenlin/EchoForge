# Transcribing files

The app transcribes audio files, and has for a long time: several at once, from a
drop anywhere in the window, from Finder's Open With, from a drop on the Dock
icon. Each one becomes a queued `Recording` with `RecordingProvenance.fileTranscription`,
the queue survives a quit, a file can be cancelled or regenerated, and a failure
keeps the row rather than deleting it.

None of that was **findable**. The only affordance before a drag began was eight
words of grey caption at the bottom of the window, and the full-window drop
overlay that explains what to do appears once a drag is already in flight - which
is after the moment somebody needed to know it was possible.

## What changed

`FileImportRow` (`OpenSuperWhisper/History/FileImportRow.swift`) sits above the
window's bottom controls and is a **visible** target:

```
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
  ⬇  Drop audio files here to transcribe    Open Files…
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

Dashed, because that is what a drop target looks like everywhere else on this
platform and the whole point is that it is recognised before anything is dragged.
Beside it, an **Open Files…** button with an `NSOpenPanel` restricted to audio,
for the users who would never have thought to drag.

It **replaces** the caption rather than joining it. A 450 pt window has no room
for both, and two ways of saying the same thing is how the caption ended up
unread.

## The Files lens

Once anything is queued the row becomes a count and a way to look at it:

```
  ⏱  3 files in the queue                  Show   Open Files…
```

`Show` applies `HistoryProvenanceFilter.fileTranscription` to the list below -
the filter that already existed in the search bar's menu - and turns into `Show
all`, because a user who has just found their four files needs the way back from
the same place they were sent.

The count is `RecordingStore.pendingFileTranscriptionCount()`, answered in **SQL**
for the reason the filter is applied there: history is paged, so counting the
loaded page would report a queue of thirty files as however many of them are in
the first hundred rows. It uses the same predicate the lens applies, so the count
and the list it sends the user to cannot disagree.

## What is deliberately unchanged

`FileDropHandler` still owns the drop, `TranscriptionQueue` still owns the queue
and writes the provenance at insert (so a *queued* row is already findable under
the lens, not only a finished one), and `TranscriptionQueueStep` still owns the
rule that a pass which does not settle a row must not be handed it again. Nothing
here touches any of that: this is a surface over machinery that worked.

The `NSOpenPanel` is app-modal and runs its own event loop, so it is outside
`PowerOffPresentationGuard`'s reach - the same knowing exception
`AppStyleMappingSettingsView` already carries. It is transient, and the user is
standing at the machine while it is up.

`FileImportRowRenderTests` draws the row at both window widths, in both
appearances, and with a queue in it, because the state that matters most needs
audio files dropped on a fully permitted build before it can be looked at any
other way.
