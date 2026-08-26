# The starter speech model

> **Ordinary releases no longer bundle it.** Packaging is opt-in
> (`ECHOFORGE_BUNDLE_STARTER_MODEL=1`) and the default is a thin ~11 MB disk image, because the weights
> live in Application Support and survive an app replacement - so shipping them made every update
> twenty times larger to deliver bytes the machine already had.
> See [model-packs.md](model-packs.md) for the measurements and for how weights are published now.
> Everything below still describes the bundled path, which is what an offline install medium wants
> and what `StarterModel.installIfNeeded()` still does for anyone running a build that shipped one.

Kongweh can ship with a speech model already on board, so a fresh install can dictate
immediately instead of waiting on a 240 MB download and a minute of Neural Engine compilation
before its first word.

The weights are **never committed to this repository**. They are a build input: the release
operator stages them once, and a build asked to bundle them (`ECHOFORGE_BUNDLE_STARTER_MODEL=1`)
packages whatever is staged. A checkout without them builds and runs exactly as before - which
is what CI does on every push.

## What ships

| | |
|---|---|
| Model | SenseVoiceSmall, int8 encoder (`EngineKind.defaultChineseDictation`) |
| Size | ~240 MB |
| Why this one | It is the only engine of the four that covers Mandarin, Cantonese, English, Japanese and Korean in a single download, and it is already the engine the app recommends for Chinese. Bundling a second would mean carrying two sets of weights to answer one question. |
| Attribution | [speech-model-attribution.md](speech-model-attribution.md) - the licence obligations that come with redistributing these weights are **not** optional |

## Staging the artifact

Do this once on a Mac that has already downloaded the model through the app, so what is staged
is byte-for-byte the files the app loads:

```
# 1. Download it in the app: Settings ▸ Model ▸ SenseVoice-Small ▸ Download.
#    Wait for "Downloaded and ready."
# 2. Copy the exact files the engine loads into the staging directory.
Scripts/package_starter_model.sh --stage-from-cache
```

That writes `StarterModel/sensevoice-small/` at the repository root, containing:

```
SenseVoicePreprocessor.mlmodelc
SenseVoiceSmall_int8.mlmodelc
vocab.json
```

`StarterModel/` is gitignored. `StarterModelTests` asserts this file list is exactly
`SenseVoiceEngine.requiredCacheEntries`, and that the script stages the same names, so the two
cannot drift apart - a starter staged against the wrong encoder precision would install weights
that never load.

Set `STARTER_MODEL_DIR` to stage somewhere else, e.g. a shared release machine.

## What the build does

The app target has a `Package Starter Model` run-script phase that calls
`Scripts/package_starter_model.sh`. It:

- packages only when asked: without `ECHOFORGE_BUNDLE_STARTER_MODEL=1` it prints a note,
  removes any stale copy, and leaves the build thin;
- copies `StarterModel/<cache folder>/` into `EchoForge.app/Contents/Resources/StarterModel/`;
- **fails the build** if the staging directory exists but is incomplete, because a build that
  claims to ship a starter model and cannot load it is worse than one that ships none;
- prints a note and removes any stale copy when nothing is staged, so a checkout without the
  artifact keeps building.

## What the app does at runtime

`StarterModel.installIfNeeded()` runs once at launch, in
`AppDelegate.applicationDidFinishLaunching`, before anything reads `EngineAvailability` or
constructs an engine. It copies each entry into the model cache the engine already downloads
into - `~/Library/Application Support/FluidAudio/Models/sensevoice-small/` - so once installed
the starter is indistinguishable from a finished download: the Settings row shows its normal
downloaded badge, and deleting the cache falls back to downloading exactly as it always did.

Three rules it keeps, each with a test:

- **An existing cache is never overwritten.** A model the user paid 240 MB of bandwidth for wins
  over the bundled copy.
- **A partial copy is never left behind.** A failure removes what it wrote, so the app falls back
  to downloading rather than finding files it cannot load.
- **A build with no starter is a no-op.** Not an error, not a warning at the user.

`EngineSelector` then uses it as the last stand-in tier: on a Mac where nothing else is ready,
dictation runs on the starter while the engine the user actually chose is fetched in the
background. It is never *persisted* as the user's choice - see `EngineSelection`.

## Releasing with it

`docs/release_build.md` covers the release itself. The extra steps are staging the artifact and
building with `ECHOFORGE_BUNDLE_STARTER_MODEL=1`, which also flips the release verifier from
`--forbid-starter-model` to `--require-starter-model`. Check it landed:

```
ls "EchoForge.app/Contents/Resources/StarterModel/sensevoice-small"
```

A release built without it is the ordinary thin release; the app downloads a model on first use.
