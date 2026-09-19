# Where user data lives, and how a history row is made

Everything a user accumulates lives in `~/Library/Application Support/<bundle id>/` -
the recordings database, `terms.json` and the downloaded models - so the bundle identifier
is load-bearing user data, and [app-identity.md](app-identity.md) says why it must not
change. `AppDataLocation` (`EchoForgeCore/`) names that directory with a constant rather
than `Bundle.main`, because the `echoforge` tool is a second process with a different
identity ([cli.md](cli.md)).

## The recordings database

The recordings database is GRDB, with its full schema history in
`RecordingSchema.makeMigrator()` (`EchoForgeCore/History/RecordingSchema.swift`), which
`RecordingStore.makeMigrator()` (`OpenSuperWhisper/Models/RecordingStore.swift`) forwards
to. Schema changes go in a new named migration; never edit an applied one, since the
identifier is what decides whether a user's database already ran it. `RecordingStore` stays
in the app - it is what migrates and writes - and the tool opens `RecordingSchema`
**read-only** and never migrates.

Every row also records what produced it and what became of it - `RecordingProvenance`,
three nullable columns, written never guessed, failing closed, carrying no id, URL or
credential. [history-provenance.md](history-provenance.md) is the whole story, and
`HistoryProvenancePrivacyTests` holds the privacy half plus a source scan that keeps
`RecordingProvenance` the only writer of those columns. The history list filters and
searches in **SQL** (`RecordingStore.query(matching:)`), not over the loaded page, because
history is paged; `provenanceKind IN (…)` is false for NULL, so the legacy filter asks for
the NULL and every other filter must not. [history-search-export.md](history-search-export.md)
covers search and export.

## One place makes a row

A new row is made in **one** place, `Recording.newRow` (`EchoForgeCore/History/Recording.swift`),
which names its audio by the row's own id, `<UUID>.wav`, and takes the provenance as a
required parameter. The five paths that create history - hotkey dictation, the main window's
record button, voice edit, the queue and a kept failed dictation - all go through it, and
nothing else may build a `Recording` by hand; `RecordingRowFactoryTests` holds the names
apart.

The name used to be the timestamp to the second, computed inline at each of those sites, so
several files dropped together became distinct rows pointing at one `.wav` - the queue's copy
(`TranscriptionQueue.placeAudio`, which still replaces whatever is at the destination, now
safely) kept only the last one, and deleting any of the rows removed the audio of all of
them. Rows written before that keep their old names and are never renamed: `fileName` is
resolved as stored, so the old and new schemes coexist in one directory and there is no
migration for it. The recorder's temporary file is not a history recording and keeps its
second name; `AudioRecorder` says why that one cannot collide.

## The second store

`terms.json` beside the database is the personal terms dictionary, deliberately a plain
hand-editable file outside the database because it has a different lifecycle and must not
be touched by the recordings retention policy. See [personal-terms.md](personal-terms.md).
Voice snippets, by contrast, live in the defaults domain ([voice-snippets.md](voice-snippets.md)).
