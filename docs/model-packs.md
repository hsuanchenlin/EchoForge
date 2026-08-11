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
| Where weights come from | the bundle, or Hugging Face with no digest | the engine's own download today; a **model pack** once the install path is wired in and one is published |
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

## The list, and why it ships inside the app

`OpenSuperWhisper/ModelPacks.json` is the manifest. It is **bundled rather than fetched**, which is
a deliberate difference from the release manifest: it costs a few hundred bytes, it works on a
machine that has never been online, and it adds no second network trust boundary. `ModelPackManifest.parse`
is written so a fetched document could be handed to it unchanged if that ever becomes worth doing.

**It is empty until packs are actually published, and that is the correct state.** With no entries
`ModelPackCatalog.pack(for:)` answers `nil` and the app downloads weights exactly as it always has.
Shipping the pack code changes nothing on its own - and publishing assets alone does not switch an
engine over either, because nothing in the app consults the catalog yet (see below).

## Not wired into the download path yet

`ModelPackCatalog.pack(for:)` and `ModelPackInstaller.install` have **no production caller**. This
change deliberately shipped the pack format, its security boundary, the installer and the packaging
script and stopped there: wiring the download path safely needs a published pack to test against.
Until that wiring lands, publishing a pack and listing it in `ModelPacks.json` changes nothing and
the app keeps fetching weights through each engine's own downloader.

What remains, and it must land **before the first pack is published**: the model-preparation and
onboarding download path consults `ModelPackCatalog.pack(for:)` for the engine it is about to
fetch, installs the pack when one is listed, and falls back to the engine's own downloader
otherwise.

## The rules

`ModelPackManifest` is the security boundary, the same way `UpdateManifest` is for the disk image,
and for the same reason: what is on the other end is "unpack this into the directory CoreML loads
from". It refuses:

- any URL that is not HTTPS on a GitHub release host **under this repository**;
- any `sha256` that is not 64 hex characters;
- any `entries` name or `cacheFolder` that is not a single path component - this is what stops
  `../../../bin/sh` from being an entry;
- any engine this build does not have, any schema version it does not understand, any implausible
  size.

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
| Updating user who deleted their cache | Lands in the same first-run model picker a fresh install sees. |
| Fresh install | Picks a model in onboarding and downloads it through the engine's own downloader. A pack will serve this only once one is published *and* the install path is wired in (see above). |
| Someone still running a bundled build | `StarterModel.installIfNeeded()` is unchanged and still installs from their bundle. It stays until no bundled build is plausibly still running. |

## See also

- `docs/starter-model.md` - the bundled path, which still exists for offline media
- `docs/release_build.md` - the release itself
- `docs/speech-model-attribution.md` - the licence obligations that come with redistributing weights,
  which a pack does not change
