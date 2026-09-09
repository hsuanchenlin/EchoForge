# App vocabulary

Dictating into Xcode and dictating into Mail are not the same activity. One
wants `viewDidLoad` and `snake_case`; the other wants *"Best regards"* and an
email address. This feature primes the recognizer with words and punctuation
that suit the app in front of the user, before it decodes.

It is **off by default**
(`Settings → Dictionary & Snippets → App Vocabulary`), and every profile it
ships is listed in that pane, in full, so the answer to *"what exactly would you
add?"* is on screen rather than in a source file.

---

## The signal, and its limit

The only thing read about where a dictation is going is the frontmost
application's **bundle identifier**. Not the window title, not the document
name, not the web address, not the field the caret is in - and nothing is
logged, stored or sent anywhere.

That is the same invariant `docs/app-aware-style.md` states, and it is enforced
the same way: `AppDetector` and `DictationTargetApp` have nowhere for anything
else to enter, and `AppVocabularyPrivacyTests` scans `OpenSuperWhisper/Context/`
for the accessibility, window-list and networking symbols that would be needed to
learn more.

In the privacy tiers the product research names, this is **tier 0**. Tier 1
(window and document metadata) and tier 2 (bounded nearby text) are not
implemented and are not implied by anything here.

---

## What a profile is

Two halves, doing two different jobs:

```swift
AppVocabularyProfile {
    hint:  "Notes on the code: refactored AuthService, fixed a nil check in
            viewDidLoad, renamed max_retry_count, and opened a pull request
            against main."
    terms: ["camelCase", "snake_case", "TypeScript", "Xcode", …]
}
```

- **`terms`** are words the recognizer is biased *towards*. This is what the
  personal terms dictionary already does, and it is the honest use of a decoding
  prompt: a token the model would otherwise write as the nearest ordinary
  English word.
- **`hint`** is one short passage written the way dictation into that kind of app
  usually reads. whisper.cpp treats an initial prompt as **preceding
  transcript**, so a passage carrying camelCase, a wikilink or an email sign-off
  biases *punctuation and casing* rather than any particular word. That is the
  one mechanism available for "preserve technical casing", and it is a **bias,
  not a guarantee** - said here because a user reading the pane deserves to know
  which of the two they are getting.

Four profiles ship, keyed by the same `AppCategory` the style mapping uses:

| Category | Examples | What it primes |
| --- | --- | --- |
| Code & terminals | Xcode, VS Code, Cursor, Terminal, iTerm | Identifier casing, language and tooling words |
| Mail | Mail, Outlook, Spark | Sign-offs, an email address, mail vocabulary |
| Chat & messaging | Slack, Messages, Discord, WhatsApp | Short-form work chat, punctuation people actually use |
| Documents & notes | Notes, Obsidian, Bear, Pages | Headings, list markers, `[[wikilinks]]`, note vocabulary |

**Web browsers deliberately get nothing.** A browser window is a mail client, a
chat client, a code review and a text editor on four tabs, and the only signal
that would tell them apart is the page's address - which this feature refuses to
look at. That is the same conclusion `AppStyleMappingStore` reaches for the same
category, for the same reason.

---

## Which engine sees it

**Whisper, and no other.** Parakeet, SenseVoice and Paraformer take no decoding
prompt in the pinned runtimes, and no stand-in is invented for them - the same
absolute rule the personal terms dictionary follows
(`docs/personal-terms.md`). `AppVocabularyPrivacyTests` asserts that
`settings.appVocabulary` is read in exactly one file, `WhisperEngine.swift`.

**The cloud endpoint is never shown it.** That provider *does* take a prompt, and
it is sent the typed setting alone - `CloudPrivacyTests` scans `Cloud/` for the
dictionary and `AppVocabularyPrivacyTests` scans it for this. See
`docs/cloud-api.md`.

While an engine without the hook is selected, the pane says so rather than
implying the setting is doing something.

---

## The budget, and who wins

Everything is composed into one prompt by `WhisperInitialPrompt`, charged against
one token budget measured with the model's own tokenizer, and composition stops
at the first entry that does not fit. The order **is** the priority:

```
<the user's typed Initial Prompt>.  <their personal terms>.  <the app's passage>  <the app's words>
                 │                            │                        │
       never trimmed                 never crowded out          dropped first
```

Every carried prompt token comes out of the same 224-token budget whisper.cpp
uses to keep a long recording coherent across its 30 s windows, so this is not a
free addition - which is why a profile is capped at
`AppVocabularyProfile.maximumTerms` terms and
`maximumHintCharacters` characters, and why the caps are applied **when a profile
is resolved** rather than trusted at the point it was written.
`AppVocabularyPromptTests` pins the priority against a 5-token budget.

---

## Turning it off

Three ways, in increasing precision:

1. the master switch;
2. a **kind** of app - "never in mail clients";
3. a **single app**, added from an open panel, which beats its category. Only the
   bundle identifier is read out of the bundle the user chose, and only the
   bundle identifier is stored.

An absent per-category entry means **on**, so a category added by a later build
is on for everybody rather than off for whoever happened to have visited the pane.

---

## What it does not do

- It never removes vocabulary, and never changes the user's own dictionary.
- It never writes a preference on the user's behalf, the way
  `AppStyleMappingStore` never writes `styleRewriteStyleID`.
- It does not choose an engine, a language or a style.
- It has no per-app *custom* word lists. The personal terms dictionary is where a
  user's own words live (`docs/personal-terms.md`); this is a built-in list a
  user switches on, off, or off for one app.

---

## Testing

- `AppVocabularyProfileTests` - the caps, no repeated terms, and that the apps
  named in the brief actually resolve to the profile they should.
- `AppVocabularyStoreTests` - the resolution order, both ways of switching a
  profile off, and that a bundle identifier's two spellings are one key.
- `AppVocabularyPromptTests` - the composed prompt, and the priority under a
  budget too small for everything.
- `AppVocabularyPrivacyTests` - the source scans: nothing but the identifier,
  nothing in `Cloud/`, one reader in `Engines/`.
