# Model packs, and why the app got thin

## The problem this solves

Every EchoForge release from v0.3.0 to v0.5.2 shipped a **222 MB** disk image. Of the 250 MB app
bundle inside it, **229 MB was one speech model** - SenseVoice-Small, packaged into
`Contents/Resources/StarterModel`. Everything else, code and frameworks and all other resources
together, was about 21 MB.

Those megabytes were almost always wasted. Models live in
`~/Library/Application Support/FluidAudio/Models/`, outside the app bundle, and an update replaces
only the `.app` (`UpdateInstaller.installAndRelaunch`). On a machine that already had the model,
`StarterModel.installIfNeeded()` returned `.alreadyInstalled` and copied nothing - after the user
had downloaded 212 MB, verified them, mounted them, and copied them into the staged bundle.

Measured across a real release pair, by mounting both published disk images and hashing every file:

```
files: v0.5.1=45  v0.5.2=45
identical bytes carried over: 246,124,050 (93.98%)
changed files: 2  -  Contents/MacOS/EchoForge (15,763,024 B), Contents/Info.plist (2,179 B)
StarterModel: 9 files, 239,913,642 bytes, changed between the two releases: 0
```

So: the app is thin now, and weights arrive separately.

## What changed

| | Before | Now |
|---|---|---|
| Shipped DMG | ~222 MB | ~11 MB |
| Weights in the bundle | always | only when `ECHOFORGE_BUNDLE_STARTER_MODEL=1` |
| Where weights come from | the bundle, or Hugging Face with no digest | a **model pack** when one is published for the engine, else the engine's own download |
| Integrity of weights | none | SHA-256, on an allow-listed host (packs) |

`Scripts/package_starter_model.sh` still exists and still works; it just does nothing unless asked.
That is what an offline install medium would use, and `Scripts/build_release.sh` verifies whichever
way it was built (`--forbid-starter-model` by default, `--require-starter-model` for that case).

## What a pack is

One engine's cache directory, gzipped, published as a release asset and named by its own version:

```
echoforge-model-sensevoice-small-1.0.0.tar.gz
└── sensevoice-small/
    ├── SenseVoicePreprocessor.mlmodelc
    ├── SenseVoiceSmall_int8.mlmodelc
    └── vocab.json
```

It installs into `~/Library/Application Support/FluidAudio/Models/sensevoice-small/` - the directory
the engine already downloads into - so an installed pack is indistinguishable from a finished
download. Settings' badges, `isModelDownloaded`, and deleting the cache to re-download all keep
working with no knowledge of packs at all.

### The format was measured, not assumed

A `.mlmodelc` is a directory of several files, and the risk with any archive format is that it
survives as bytes but stops loading. It does not:

```
$ tar -czf pack.tar.gz -C StarterModel sensevoice-small     # 229M -> 209M, 3.9s
$ tar -xzf pack.tar.gz -C out                               # 0.5s
$ diff -r StarterModel/sensevoice-small out/sensevoice-small
   IDENTICAL                      (9 files, all SHA-256 equal)
$ swift load.swift out/sensevoice-small/SenseVoiceSmall_int8.mlmodelc
   LOADED ok: ["language", "speech", "speech_lengths", "textnorm"]
```

`ModelPackInstallerTests.testARealCompiledModelSurvivesThePackFormatAndStillLoads` is that
measurement as a test: it packs the locally staged weights, installs the pack, and **loads the
result with CoreML**. It is opt-in on `StarterModel/sensevoice-small` (skipped where that is not
staged, which is CI and a fresh checkout), because the alternative is a 229 MB fixture in the
repository.

## Publishing one

```
# 1. Download the model once in the app, then:
Scripts/package_model_pack.sh --id sensevoice-small --version 1.0.0
# 2. Publish the archive and its .sha256 under the tag it prints.
# 3. Paste the JSON it prints into OpenSuperWhisper/ModelPacks.json.
```

The pack's version is its own and moves independently of the app's: two app releases can want the
same weights, and re-cutting the weights must not mean re-cutting the app.

Step 2 has one flag that is not optional: **`--latest=false`**. A model pack is a release in
GitHub's sense, and a newly published release becomes the repository's *latest* one by default -
which is the exact document `GitHubReleaseMetadataFetcher` reads to answer "is there an update?".
A pack left as latest is a release with no `EchoForge.dmg` in it, so every running copy of the app
would ask for an update and be told, correctly and uselessly, that there is none. Publishing the
first pack therefore verified the pointer afterwards rather than assuming it:

```
$ gh-axi release create 'models/sensevoice-small/1.0.0' --latest=false ...
$ gh-axi api repos/hsuanchenlin/EchoForge/releases/latest   # → v0.5.2, unchanged
```

### What is published today

| | |
|---|---|
| Tag | `models/sensevoice-small/1.0.0` |
| Asset | `echoforge-model-sensevoice-small-1.0.0.tar.gz`, 208,353,071 bytes |
| SHA-256 | `ad0490fa54fba3c96894f2eb3e605b6802d0fef68a43d90d8cad72bcdc17989e` |
| `minimumAppVersion` | 0.6.0 |

The minimum is the version that first *ships* the installer: no released app up to and including
v0.5.2 has any pack code, so a pack offered to one could only be ignored. The entry was written
before that version existed and was deliberately inert until it did - `ModelPackManifest.installable`
filtered it out and the app downloaded SenseVoice's weights the way it always had. **v0.6.0 is the
release that turned it on**, and the version bump was the whole change; nothing else had to be
edited anywhere.

The published URL percent-encodes the tag's slashes
(`.../download/models%2Fsensevoice-small%2F1.0.0/...`), which is what
`Scripts/package_model_pack.sh` emits. Both that form and the unencoded one were fetched before the
entry was written: each answers `206` with `Content-Range: bytes 0-1023/208353071` and redirects to
`release-assets.githubusercontent.com`, which is already in `UpdateManifest.allowedDownloadHosts`,
so the redirect re-check the download performs accepts it.

## The list, and why it ships inside the app

`OpenSuperWhisper/ModelPacks.json` is the manifest. It is **bundled rather than fetched**, which is
a deliberate difference from the release manifest: it costs a few hundred bytes, it works on a
machine that has never been online, and it adds no second network trust boundary. `ModelPackManifest.parse`
is written so a fetched document could be handed to it unchanged if that ever becomes worth doing.

**An entry is the whole switch**, per engine: the download path consults the catalog, so a listed
pack is installed and a missing one is not. With no entry for an engine `ModelPackCatalog.pack(for:)`
answers `nil` and the app downloads that engine's weights exactly as it always has - which is still
every engine except SenseVoice, and remains the only thing a licence position permits
(see [the rules](#the-rules) below).

## How the app uses one

`OpenSuperWhisper/Engines/EngineWeightsPreparation.swift` is the one place "make this engine's
weights ready" turns into fetched bytes, and all three paths that fetch weights go through it:
background preparation in `TranscriptionService`, the Settings download button, and onboarding.
None of them calls an engine's `prepareModels` itself - a source scan in
`EngineWeightsPreparationTests` fails the build if one starts to - because reaching an engine
directly is exactly the bypass a published pack exists to close.

```
prepare(engine)
  │
  ├─ ModelPackSelection.of(engine, in: packs, cache: EngineModelCache.of(engine))
  │     ├─ .install(pack, into: cache) ─→ ModelPackInstaller: allow-listed URL, resumable
  │     │                                 download, SHA-256, atomic install into the engine's
  │     │                                 own cache. Already installed → nothing is fetched.
  │     └─ .downloadThroughEngine(reason) ─→ nothing to install
  │
  └─ the engine's own prepareModels(), always
        With the cache populated this downloads nothing - FluidAudio checks the files exist and
        goes straight to loading - so a pack turns "download + compile" into "verified download
        + the same compile". Only the engine can pay the Neural Engine compile.
```

`ModelPackSelection` is a pure function, so every refusal is assertable without a network. Beyond
what `ModelPackManifest` already refuses, it declines a pack whose `cacheFolder` is not the folder
the engine actually loads from (the weights would land where nothing reads them and the download
would happen anyway), and one whose entries cannot fill the cache on their own (the half-filled
cache the installer exists to prevent). Both fall back rather than fail.

A pack that fails - checksum, archive, anything - falls back to the engine's own downloader, which
is the installer's third rule at the call site: bad bytes are discarded and never reach the cache,
and what runs instead is the download the app would have done had no pack been listed at all. A
**cancellation** is not a failure and never falls back; otherwise "stop this download" would mean
"start a different, larger one".

Progress is reported on the scale FluidAudio already uses - bytes fill the first half
(`downloadShareOfOverallProgress`), the compile the second - so the three surfaces that render it
did not have to learn a second convention.

## The rules

`ModelPackManifest` is the security boundary, the same way `UpdateManifest` is for the disk image,
and for the same reason: what is on the other end is "unpack this into the directory CoreML loads
from". It refuses:

- any URL that is not HTTPS on a GitHub release host **under this repository**;
- any `sha256` that is not 64 hex characters;
- any `entries` name or `cacheFolder` that is not a single path component - this is what stops
  `../../../bin/sh` from being an entry;
- any engine this build does not have, any schema version it does not understand, any implausible
  size;
- any engine this project has not written a redistribution position for
  (`enginesClearedForRedistribution`). Publishing a pack *is* redistribution, and
  [speech-model-attribution.md](speech-model-attribution.md) grants it for exactly one model -
  SenseVoiceSmall - and says no other may be published as a pack until the same paragraph is
  written for it. That is a licence position, so it is a refusal rather than something to be
  remembered: a Paraformer pack cannot be listed by editing one JSON file.

A pack naming a `minimumAppVersion` newer than this build is left out rather than refused, since one
document listing packs for several app versions is the normal case.

`ModelPackInstaller` then keeps three rules, each inherited from `StarterModel`, which learned them
the hard way:

- **An existing cache is never overwritten**, and is checked *before* anything is downloaded - so a
  user who already has the model pays nothing. This is what makes a thinner app safe for existing
  users.
- **A partial install is never left behind.** A cache holding some of the entries is worse than an
  empty one: the engine finds files, fails to load them, and there is nothing to download because
  everything "exists". Entries are moved through a temporary name and rolled back together.
- **A failure leaves the app able to fall back.** Nothing here is required for the app to work.

The archive is checked against the entry list *after* extraction, so an archive that is internally
consistent but incomplete never reaches the cache. A receipt (`echoforge-pack.json`) records which
pack put the weights there.

## Migration

There is nothing to migrate, and that is the point. The weights already live outside the bundle and
survive the swap, so:

| Who | What happens |
|---|---|
| Updating user with models | Keeps them. The thin app finds them present and behaves identically. Nothing is downloaded. |
| Updating user who deleted their cache | Is told no engine is set up and chooses again from the same catalog in Settings; onboarding does not re-run. |
| Fresh install | Picks a model in onboarding. Served by a pack once one is published for that engine, otherwise by the engine's own downloader. |
| Someone still running a bundled build | `StarterModel.installIfNeeded()` is unchanged and still installs from their bundle. It stays until no bundled build is plausibly still running. |

## See also

- `docs/starter-model.md` - the bundled path, which still exists for offline media
- `docs/release_build.md` - the release itself
- `docs/speech-model-attribution.md` - the licence obligations that come with redistributing weights,
  which a pack does not change
