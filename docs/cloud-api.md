# Cloud (OpenAI-compatible) transcription and translation

EchoForge does everything on your Mac. This page is about the one exception you
can switch on: sending speech to be transcribed, or a transcript to be
translated, by a provider you choose, with an API key you own.

**It is off. Nothing here happens until you turn it on**, and turning it on takes
an explicit acceptance of a sheet that says what will be uploaded and where.

---

## What leaves your Mac, exactly

| Feature | Default | What is uploaded when it is on | Where the code is |
|---|---|---|---|
| Speech transcription | **On your Mac** | The audio file of each dictation, plus the language code and your "initial prompt" setting | `Cloud/CloudTranscriptionEngine.swift` |
| Translation (the spoken `Translate to …` command) | **On your Mac** | The text of the dictation you asked to have translated | `Cloud/CloudStyleRewriter.swift` |
| Style rewriting | On your Mac | — never offered a cloud option | `Rewriting/` |
| Ask panel (⌥A) | On your Mac | — never offered a cloud option | `Ask/` |
| Screen questions (⌥S) | On your Mac | — never offered a cloud option | `Vision/` |
| Personal terms, CJK spacing, voice snippets | On your Mac | — no model involved at all | `Utils/`, `Models/` |

Nothing else is sent: no window titles, no bundle identifiers, no history, no
telemetry, no usage counts. EchoForge has no server of its own and never proxies
anything - requests go from your Mac straight to the address in the base-URL
field, and your key is sent to that address and nowhere else.

**What the provider does with what you send is their decision, not
EchoForge's.** Retention, whether it trains a model, who can subpoena it: read
the policy of whoever you configure. That sentence is in the consent sheet for
the same reason it is here.

### Why only translation, out of the three model features

Style rewriting runs on **every** dictation once it is on, whether or not you
were thinking about it that time. The Ask panel and screen questions carry
whatever happens to be on your screen. A translation is different in kind: you
ask for it by name, one dictation at a time, by saying "Translate to Spanish".
That is the one place where a per-use cloud call matches how the feature is
actually used, so it is the only one offered.

It is enforced in the type system rather than by convention:
`OnDeviceModelFeature.cloudFeature` returns `nil` for rewriting and Ask, so
neither has a reachable path to a provider. `CloudPrivacyTests` pins it.

---

## Turning it on

**Settings → Cloud.**

1. **Base URL** - `https://api.openai.com` by default. Any OpenAI-compatible
   provider works; paste the base URL from their documentation, with or without
   the trailing `/v1`.
2. **API key** - yours, from your provider. Press Save and it goes into your
   Mac's **Keychain**. It is never written to EchoForge's settings file, never
   bundled with the app, and never sent anywhere but the base URL above.
3. **Speech model** / **Text model** - free-text, because every provider names
   its models differently. `whisper-1` and `gpt-4o-mini` are the defaults.
4. Switch **Speech transcription** or **Translation** from "On my Mac" to
   "Cloud". The first time you do, a sheet says what will be uploaded and where.
   Accepting it is the consent; it is recorded, and the feature does not switch
   until you accept.

"Forget key and turn everything back to on-device" at the bottom deletes the
Keychain item, forgets both consents and puts both features back on your Mac.

**One thing to expect after an update.** These builds are ad-hoc signed, which
means macOS treats each build as a slightly different application, and a keychain
item belongs to the application that created it. So the first time an updated
EchoForge reads your key, macOS asks "EchoForge wants to use information stored
in your keychain"; choose **Always Allow** and it stops asking. It is only ever
asked of people who have stored a key - the key is read when you open the Cloud
pane, and, if you have chosen cloud transcription, when the app works out which
engine to use. An install that has never turned any of this on never reads the
Keychain at all.

### Providers this is known to work with

Anything implementing `POST /v1/audio/transcriptions` (multipart) and
`POST /v1/chat/completions`. That includes OpenAI itself, Groq, Together,
OpenRouter (chat only), and the local servers people run on their own machines -
Ollama, LM Studio, llama.cpp - which is why plain `http://` is accepted for
loopback addresses and refused for everything else.

Pointing the base URL at `http://127.0.0.1:11434` is worth calling out: the data
does not leave the Mac at all, and the pane and the consent sheet say so rather
than warning you about "a company outside your control".

---

## What it does when things go wrong

Cloud dictation can fail in ways local dictation cannot - no network, a refused
key, a rate limit, a provider outage. All of them end the same way: **your
recording is kept**, carrying the reason, and the regenerate button transcribes
it once the reason is dealt with (or once you switch back to a local engine).
That is `DictationFailureOutcome`, the same primitive that keeps a recording when
no engine is set up.

Recordings over 25 MB - about thirteen minutes at the 16 kHz mono WAV EchoForge
records - are refused **before** the upload starts, so a long dictation does not
cost you the bandwidth to be told no by a 413.

A failed cloud transcription does **not** silently fall back to a local engine.
The app tells you what happened and keeps the audio, because a fallback would
mean you could not tell which engine produced any given transcript.

---

## The rules the code keeps

These are the load-bearing ones. Each is pinned by a test.

- **`CloudAccess.resolve` is the only way to a request.** Nothing in the app can
  build one without a `CloudCall`, and only that function produces one - after
  checking, in order: the build has the cloud path, the feature is set to Cloud,
  its consent is recorded, the base URL is usable, a model is named, a key
  exists. The key is fetched **last**, so a default install does not so much as
  read the Keychain.
- **`CloudEndpoint` is the security boundary**, in the same sense
  `UpdateManifest` is: HTTPS or loopback, no credentials in the URL, no query or
  fragment. It cannot be an allow-list, because the point is that your provider
  works.
- **The cloud engine is never a stand-in.** `EngineSelector` skips it in both
  interim tiers and `EngineConfiguration.recoveryOrder` never recovers onto it,
  so a dictation is never uploaded because some other engine's download had not
  finished. `EngineKind.usesCloudProvider` states that once.
- **The engine picker has no Cloud row.** Every row there is one tap from being
  selected; the cloud engine is chosen in the Cloud pane, where the consent sheet
  is.
- **The guard is unchanged.** A cloud translation goes through
  `StyleRewriteGuard` exactly as an on-device one does - same script, number,
  symbol and length rules - so a model that obeys a spoken "ignore all previous
  instructions" is refused and you keep your own words. See
  `docs/style-rewriting.md`.
- **The key never reaches a log.** It appears in one place, the `Authorization`
  header, and everything printed or stored goes through `CloudRedaction` first,
  including provider error messages that quote it back.

---

## The offline-only build

A build with no cloud path at all is buildable and publishable:

```shell
Scripts/build_release.sh --offline-only
```

It sets the `ECHOFORGE_OFFLINE_ONLY` compilation condition, which makes
`CloudBuild.isCompiledIn` false. In that build:

- the Cloud pane is not in Settings;
- `CloudAccess` refuses every feature before looking at anything else, so a
  preferences file copied from a normal build cannot switch it on;
- `EngineKind.cloud` can never become the active engine.

Everything else is byte-for-byte the same app. The gate is one value rather than
`#if` blocks around the cloud sources because `EngineKind` is switched
exhaustively in eight places and `StyleRewriteAvailability` in two more:
compiling a case out of an enum means compiling every one of those switches
conditionally, which is how a variant build stops being the same build.
`CloudAccessTests` drives the gate with `isCompiledIn: false` and asserts a fully
configured feature is still refused.

---

## Cost

Your provider bills you for what you use, at their rates. EchoForge shows no
prices and counts no spend - it has no way to know your plan. A dictation is one
request; a translation is one request.
