# Voice snippets

A third thing a user can say instead of dictating: **"insert email signoff"**,
and the template they stored for that trigger goes in instead of the words.

It is a macro, not a rewrite. Nothing interprets the template, nothing polishes
it, and nothing is asked to. `docs/spoken-intents.md` is the router's own story;
this file is the snippets.

## Where it sits

```
TextPostProcessor.process()             deterministic, cannot fail
     │
     ▼
SpokenIntentPipeline.apply()            two conditions, see below
     │
     ├── .snippet ──► the stored expansion, byte for byte
     ├── .dictate ──► StyleRewriteService.apply()
     ├── .translate ► TranslationRewrite.apply()
     └── .ask ──────► the Ask panel, nothing inserted
     │
     ▼
StyledTranscript { final: the template, status: .notRequested,
                   intent: .snippet(keyword:) }
```

`VoiceSnippet` and `VoiceSnippetStore` (`Models/`) are the data;
`SpokenIntentRouter.matchSnippet` is the whole grammar; the Settings pane is
**Dictionary & Snippets**, under the personal terms it sits beside.

## Three conditions, not one

Snippets are one of the things spoken-command routing does, so they inherit its
two conditions and add one of their own. All three have to hold:

- the user switched `spokenIntentsEnabled` on (off by default), and
- the caller passed `Settings(routesSpokenIntents: true)` - only live dictation
  does, so a dropped file, a queued recording, a regenerate from history and the
  Ask panel's follow-up cannot expand a macro, and
- `voiceSnippetsEnabled` is on (it is, by default), which is how the macro family
  is switched off without also switching off Ask and Translate.

`Settings.voiceSnippets` resolves all three in one place and hands the router a
list that is empty whenever any of them fails. Nothing downstream re-checks.

## The grammar

| Said | Becomes |
| --- | --- |
| `insert email signoff` `Insert: email signoff` | the template for `email signoff` |
| `insert snippet …` `snippet …` | same |
| `插入會議記錄` `插入片語會議記錄` `插入：會議記錄` | the template for `會議記錄` |
| `email signoff` - the trigger and nothing else | same |
| anything else | dictation, byte for byte |

Two forms, and both demand a trigger this user actually stored:

- **Marker-led.** `insert`, `snippet` and `insert snippet` are ordinary English
  words, so each needs a space or punctuation behind it - and, far more
  importantly, needs the rest of the transcript to name a stored trigger *in
  full*. "Insert a row above this one" names none and is dictation, exactly as
  "Translate the document" names no language. The Chinese markers (`插入`,
  `插入片語`, `插入片语`) need no delimiter, for the reason every CJK marker in the
  router does not: a Mandarin transcript has no space to require.
- **The trigger alone.** The trigger has to *be* the whole dictation. That is
  the only thing standing between a trigger like "address" and every sentence
  containing the word, so it is not negotiable: "email signoff" said on its own
  expands; "the email signoff was wrong" is dictation.

Nothing partial ever fires. A remainder that does not match a stored trigger in
full leaves the transcript alone, because inserting the wrong template costs the
user the words they actually said and a missed trigger costs them a retry.

The built-in commands are matched first, so a trigger cannot take `Ask:` or
`Translate to …` away from the features that shipped before it.

### Matching a trigger

`VoiceSnippetTrigger.normalize` is the comparison, and every difference it folds
away is one the speech engine introduced rather than the speaker:

- **case** - "Email Signoff" in Settings answers "email signoff" spoken;
- **surrounding punctuation** - the pause around a command comes back as a comma
  or a full stop, and quotation marks come back around a phrase;
- **doubled-up spacing** - a run of spaces counts as one, though where a space
  falls still has to match;
- **Traditional against Simplified**, through `ChineseScriptFolding` - the same
  folding the personal terms dictionary uses, so a trigger typed in one script
  answers dictation in the other, whichever script the transcript was written in
  (`docs/chinese-script.md`).

The **template** is never folded or converted, only the trigger is: it is
inserted byte for byte in the script the user typed it in, even when their
Chinese output script is the other one.

Nothing is stemmed and nothing is truncated: a normalized phrase has to match a
normalized trigger in full. Two snippets that normalize onto the same trigger
resolve to whichever is higher in the user's own list, which is the order
Settings shows them in, and the editor says so while it is being typed.

## The template

`VoiceSnippet.expansion` is the one string in this app nothing touches. The
rewriting stage is not consulted - not skipped conditionally, not run and
discarded - because a model asked to polish

```
Attendees:

Agenda:
```

returns a paragraph about a meeting. Blank lines, indentation and a deliberate
missing full stop are the template, so what is stored is what goes in, and
`StyledTranscript.status` is `.notRequested` to say the stage never ran.

The one thing that still applies is the insertion stage
(`TextPostProcessor.prepareForInsertion`), which appends a space after a
trailing full stop so consecutive dictations do not run together. It applies to
every inserted dictation and a snippet is not special enough to exempt.

History keeps what was said - "insert email signoff" - alongside the text that
was inserted, the same way it keeps a transcript next to its rewrite.

## Storage

`VoiceSnippetStore` keeps the list as JSON in the app's defaults domain, under
`voiceSnippets`. Deliberately not a second `terms.json`: the dictionary is a file
because it is meant to be hand-edited, backed up and version-controlled, while
snippets are written only by Settings and read on the dictation path. It also
means a test redirects them by pointing `PreferenceStore.defaults` at a throwaway
suite, which `IsolatedPreferencesTestCase` already does.

The store holds no cached copy - every read decodes from defaults - so the pane
and the dictation path cannot disagree about what is stored. A value that cannot
be decoded is reported (`loadFailure`) and never implicitly overwritten; the only
repair is the Reset button, pressed by a user who has been told what it costs.

Two samples are installed once, on an install that has never had them
(`installSamplesIfNeeded`, called from `applicationDidFinishLaunching`). Deleting
them sticks: the flag is separate from the list, so seeding is an event rather
than a floor the app keeps restoring, and an install that already had snippets is
never handed entries it did not create.

## The capsule

`CapsuleHUDMode.snippet(named:)` is the chip: **"Snippet: email signoff"**, or
plain **"Snippet"** once the trigger passes
`maximumSnippetKeywordCharacters` - a trigger is the user's own text and can be a
sentence, and the chip widens the whole capsule to hold it. Like every spoken
command the chip is set once the words exist, and only while the capsule is
showing its own decode; `docs/capsule-hud.md` has the rule.

## Known limits

- A trigger only counts at the front of a dictation, and the bare form only when
  it is the entire dictation. There is no mid-sentence expansion.
- A template is inserted, never filled in: there are no placeholders, no date and
  no cursor position. `[your name]` in the sample is text to edit, not a field.
- The trigger is matched against the *deterministic* output, so a personal terms
  entry can change what is matched - the same property, and the same deliberate
  one, that makes a user's own spelling of a language name work.
- A trigger that is also an ordinary phrase will fire when it is said on its own.
  The editor asks for a distinctive one; the app cannot know which phrases a user
  says alone.

`VoiceSnippetStoreTests` and `SpokenIntentRouterSnippetTests` pin all of the
above.
