# Spoken commands

Four things a user can say instead of dictating: **"Ask: …"**, which sends the
question to the Ask panel, **"Translate to Spanish: …"**, which translates what
follows instead of pasting it, **"insert [trigger]"**, which expands one of
their own voice snippets, and **"open the latest YouTube video from …"**, which
opens the newest video from a channel they allowlisted. Everything else is
dictation, unchanged.

It is off by default (`Settings → Shortcuts → Ask & Spoken Commands → Spoken
commands`). `docs/ask-panel.md` is the panel's own story,
`docs/voice-snippets.md` is the snippets' and `docs/youtube-latest-video.md` is
the YouTube command's; this file is the router and the translation.

## Where it sits

```
engine output
     │
     ▼
TextPostProcessor.process()        deterministic, cannot fail
     │                             ProcessedText { raw, final, mustSurviveTokens }
     ▼
SpokenIntentPipeline.apply()       only when the caller asked AND the user
     │                             switched it on
     │
     ├── .dictate ─────────► StyleRewriteService.apply()  the chosen style
     ├── .translate ───────► TranslationRewrite.apply()   the spoken target
     ├── .snippet ─────────► the stored template, byte for byte
     ├── .ask ─────────────► nothing at all
     └── .openLatestVideo ─► nothing at all
     │
     ▼
StyledTranscript { raw, transcript, final, status, intent }
     │
     ├── intent == .ask ──────────────► AskPanelWindowController, NOT inserted
     ├── intent == .openLatestVideo ──► YouTubeLatestVideoService, NOT inserted
     └── otherwise ───────────────────► pasted, stored, searched, as always
```

`SpokenIntentRouter` (`Utils/`) is the whole grammar and is pure string
matching. Asking the on-device model to classify the dictation instead would
put a model in front of *every* dictation, make "did my words get pasted"
depend on how the model felt about them, and cost a second of latency on the
plain path that is almost all of the traffic.

## Two conditions, not one

Routing runs only when **both** hold:

- the user switched `spokenIntentsEnabled` on, and
- the caller passed `Settings(routesSpokenIntents: true)`.

Only live dictation passes it. A dropped file, a queued recording, a regenerate
from history and the Ask panel's own voice follow-up all take the plain path -
which is what stops a transcript that happens to begin "Ask:" from opening a
panel nobody was looking at, and what stops a follow-up from routing itself back
into the panel it came from.

## The grammar

| Said | Becomes |
| --- | --- |
| `Ask: …` `Ask, …` | `.ask(query:)` - marker and punctuation stripped |
| `請問…` `请问…` `問 …` `问：…` | `.ask(query:)` |
| `Translate to Spanish: …` (also `into` / `this to` / `it to` / bare `Translate Spanish`) | `.translate(target:text:)` |
| `翻譯成西班牙文：…` (also `翻译成` `翻成` `譯成` `翻譯為` `幫我翻譯成`) | `.translate(target:text:)` |
| `insert [trigger]` `snippet [trigger]` `插入[觸發詞]`, or the trigger alone | `.snippet(keyword:expansion:)` - see `docs/voice-snippets.md` |
| `Open the latest YouTube video from [channel]` `打開YouTube最新影片[頻道]` | `.openLatestVideo(resolution)` - see `docs/youtube-latest-video.md` |
| anything else | `.dictate` - the transcript, byte for byte |

**Everything that is not recognised is dictation.** That bias is the whole
design: a mis-read command sends the user's words somewhere they did not ask
for, and a missed command costs them a retry.

The one command that does not fall back to dictation once its marker matched is
the YouTube one, and only because its marker is long enough to make that safe:
every spelling of it names YouTube *and* says which video is wanted, so a
transcript that begins with it is not a sentence anyone was writing. What it does
instead is nothing at all, with a message saying which channel it did not
recognise - see `docs/youtube-latest-video.md`.

### Why some markers need punctuation

A marker that is also an ordinary word is only promoted when the transcript
shows the pause a real command has:

- **`ask`** needs punctuation (`:` or `,`). "Ask him to call me back" is a
  sentence people dictate, and accepting a bare space would route it. The cost
  is that a speech engine which drops the comma leaves the command undetected -
  the safe direction.
- **`問` / `问`** needs punctuation or a space, which is exactly what the space
  in the spec's `問 [問題]` is doing.
- **`請問` / `请问`** needs nothing behind it. This is a documented compromise:
  Mandarin transcripts do not come back with a space after it, so requiring a
  delimiter would make the Chinese form unusable, and the price is that
  "请问他什么时候来" - *please ask him when he is coming* - is read as a question.
- **`translate to …`** needs no delimiter of its own, because a language name
  has to follow and that is a far stronger constraint. "Translate the document
  before Friday" names no language and stays dictation.
- **`insert …`** is delimited like `問`, and carries the same constraint
  `translate to` does: a trigger the user actually stored has to follow, in
  full. "Insert a row above this one" names none and stays dictation.
- **`open the latest YouTube video from …`** needs no punctuation of its own:
  the English spellings end in `from`, so the word boundary a transcript puts
  after it is delimiter enough, and the Chinese spellings need nothing behind
  them. The whole phrase is the constraint, and a channel the user allowlisted
  has to follow it in full.

The built-in markers are matched before the user's own triggers, so a snippet
can never take `Ask:` or `Translate to …` away from the features that shipped
before it.

### Language names

`SpokenLanguageLexicon` maps what a user says onto an ISO code. The English
names come from `LanguageUtil.languageNames` - the app's one list of what a
language is called, so the picker and the spoken form cannot drift - and the
file adds the Chinese names and the aliases nobody says out loud
("auto-detect") or says differently ("Mandarin").

Names are matched longest first, so `traditional chinese` beats `chinese`, and
a Latin name must not run into another letter, so "Frenchman" is not French.
An unknown language is not a translation: `Translate to Klingon: …` is
dictation.

`SpokenTranslationTarget` carries a Chinese variant when the user named one
(`繁體中文`, `simplified chinese`). A bare "Chinese" carries none, and the
caller's fallback - in the app, the user's chosen output script
(`docs/chinese-script.md`) - stands in. The distinction is not cosmetic: it
decides every character of the answer, and `TranslationRewrite` writes its
accepted answer in that variant rather than trusting the model to have stayed
in it.

The transcript this router reads has already been written in that same chosen
script, command prefix included. That is why every CJK spelling in
`SpokenIntentGrammar` and `SpokenLanguageLexicon` is listed in **both**
scripts: a Simplified speaker whose output is Traditional says
"翻译成意大利语" and the router is handed "翻譯成意大利語", so a spelling
whose counterpart were missing would turn that command back into dictation.
`SpokenIntentRouterTests` converts every entry both ways and fails if one has no
counterpart.

## Translation

`TranslationRewrite` is a sibling of `StyleRewriteService`, not a style inside
it, and the reason is the prompt. Every rule the rewriting stage sends says
*stay in the transcript's language and never translate it*, written in the
transcript's own language, because that is what stops Chinese dictation coming
back in English (`docs/style-rewriting.md`). Translation is the one request
where all of that is backwards.

What is shared stays shared: the `StyleRewriting` protocol, `StyleRewriterFactory`'s
availability, `AsyncDeadline`'s hard budget, `StyleRewriteGuard`, and
`StyledTranscript` as the result. What is not:

- **The backend can be a provider**, and this is the only stage where it can.
  Translation is asked for by name, one dictation at a time, which is what makes
  a per-use cloud call match how it is used - and rewriting, Ask and screen
  queries, which are not, have no such option. It is off by default and takes an
  explicit consent; the prompts, the budget and the guard are identical either
  way. See `docs/cloud-api.md`.

- **The instruction is written in the target language**, where this app has one
  (English, Traditional, Simplified), and names the target explicitly either
  way. It is the same measured behaviour the rewriting stage exploits in the
  other direction - the model answers in the language it was addressed in - so
  writing the instruction in the target is what makes the answer come out in it.
- **`StyleRewriteShape.translating`** is the guard rule that is relaxed, and it
  is relaxed in exactly one place. It turns off the script check and the Chinese
  variant check, because a translation changing the script is the point.

Everything else the guard does still applies to a translation: numbers, currency
symbols, dictionary terms, the model addressing the user instead of translating,
and a length ratio.

The stage's contract is the rewriting stage's contract: **it can translate the
text or leave it alone.** When it fails - no model, timed out, refused - the
user gets the *body*, with the spoken command stripped. Pasting "Translate to
Spanish: hello" into their document would be worse than pasting nothing. The
notice that says why (`StyledTranscript.statusExplanation`) names translation,
not rewriting - `OnDeviceModelFeature.translation`, the same device the Ask
panel uses so a failure names the feature the user was actually using.

## Known limits

- The length ratio for `translating` is 0.1 … 8.0, which is barely a check.
  "會議三點開始。" is seven characters and a correct English translation of it is
  fifty-two, so anything tight enough to be informative would refuse real
  translations. The checks that carry a translation are the ones that do not
  depend on length.
- The target Chinese variant is asked for in the instruction and **not**
  enforced by the guard - the variant check compares the rewrite against the
  *transcript*, which for a translation says nothing.
- Personal terms are still required to survive a translation. They are almost
  always proper nouns, which do; a dictionary entry for an ordinary word could
  refuse a correct translation, and the failure is the safe one - the user keeps
  their own text.
- The letter-boundary check on language names is Latin-only: "Frenchman" is not
  French, but the text a CJK name introduces is itself letters, so requiring a
  boundary there would refuse every real CJK command. The accepted cost is that
  `翻譯成德語課的講義` is read as a request to translate `課的講義` into German
  rather than staying dictation.
- A marker only counts at the front of a dictation. "Tell them I will ask: what
  is the deadline?" is dictation.
- The router runs on the *deterministic* output, so a personal terms entry can
  change what is matched. That is deliberate: it is also what makes a user's own
  spelling of a language name work.

`SpokenIntentRouterTests`, `SpokenIntentPipelineTests`,
`SpokenIntentRouterSnippetTests`, `SpokenIntentRouterYouTubeTests` and
`TranslationRewriteTests` pin all of the above.
