# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Naming

The shipped app is **EchoForge** (`com.hsuanchenlin.EchoForge`); the repository, Xcode project,
targets, source directories and the Swift module are still `OpenSuperWhisper`. That split is
deliberate: the product carries the fork's own identity, while the code keeps upstream's paths so
merges from `Starmel/OpenSuperWhisper` stay clean. So `PRODUCT_NAME` is `EchoForge` with
`PRODUCT_MODULE_NAME` pinned to `OpenSuperWhisper` (that is what `@testable import
OpenSuperWhisper` binds to), and the scheme and `-only-testing:` arguments below keep the old
names. `OpenSuperWhisperTests/AppIdentityTests.swift` pins the user-facing side of it - bundle
identifier, display name, permission strings, and that the icon ships with every size.

Renaming reached the product, not the models or the upstream credit: engine and model names are
constrained by their licences (see `docs/speech-model-attribution.md`), and the README and LICENSE
keep upstream's attribution.

The app icon is generated, not hand-drawn: `Scripts/GenerateAppIcon.swift` is the vector source and
`Scripts/generate_app_icon.sh` renders `OpenSuperWhisper/AppIcon.icns` from it. The `.icns` is
committed, so builds never run the script. `CFBundleIconFile` in the Info.plist is what loads it;
there is no `AppIcon.appiconset`.

## Build

Submodules are required before anything builds - a fresh clone or worktree needs
`git submodule update --init --recursive` (`libwhisper/whisper.cpp` and `asian-autocorrect`).

`./run.sh build` builds everything (CMake for whisper.cpp, cargo for the autocorrect dylib,
then `xcodebuild`); `./run.sh` also launches the app. CI runs exactly `./run.sh build`
(`.github/workflows/build.yml`) and does not run tests.

## Release

`notarize_app.sh` (and `make_release.sh`, which calls it) needs a "Developer ID Application"
certificate and a `notarytool` keychain profile. This fork does not have either, so its
releases are unsigned and unnotarized and users have to get past Gatekeeper by hand.
`docs/install.md` is the one end-user home for that: install path, the two Gatekeeper
workarounds, permissions, and how to use the Chinese engines. The README links to it and
must not grow a second copy. Per-release notes live in `docs/release-notes/vX.Y.Z.md` and
are what the GitHub release body is created from. Version bumps go in `MARKETING_VERSION`
and `CURRENT_PROJECT_VERSION` in `OpenSuperWhisper.xcodeproj/project.pbxproj`, which carry
them once per target and configuration - keep all of them in step, the way `make_release.sh`
does. `OpenSuperWhisperTests/ReleaseVersionTests.swift` pins that: the two settings agree
across every target and configuration, and the version the app reports has notes carrying
its number and the Gatekeeper workaround.

## Updates

`OpenSuperWhisper/Updates/` is the About pane and the in-app updater. Nothing there runs on its
own: checking, downloading and installing are three separate user actions, and there is no
launch-time or background check to add one to.

`UpdateManifest` is the security boundary, not a parser: it is the only thing standing between
release metadata and "replace the running application", so it accepts an exact asset name, an
HTTPS URL on GitHub's release hosts under this repository, and a `vX.Y.Z` tag - and refuses
everything else with a reason. `DownloadedBuildRequirements` then checks the downloaded bundle's
identifier and version, and `codesign --verify --deep --strict` checks it was not modified since
signing. That signature is **ad-hoc**, so it proves integrity and not authorship; the allow-list is
what carries the rest. Do not weaken either half - `UpdateCheckerTests` asserts the refusals.
The allow-list check on the initial URL is not enough by itself: GitHub's API always returns a
`github.com` link, but the bytes are served from a redirect to its object store, so the download
re-checks every redirect it follows against the same host allow-list
(`UpdateManifest.isAllowedRedirectHost`) before continuing.

The swap runs in a detached shell script that waits for the app to exit first, because a running
bundle cannot replace itself; `UpdateInstaller` documents the sequence.

## Tests

```
xcodebuild test -scheme OpenSuperWhisper -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO -only-testing:OpenSuperWhisperTests
```

Five tests fail on any machine without the right hardware and TCC grants, independent of your
change - verify against a clean checkout before assuming you broke them:
`ClipboardUtilPasteIntegrationTests` (drives TextEdit through Accessibility) and the
`MicrophoneService*` cases that reach real CoreAudio devices.

Targets use Xcode file-system-synchronized groups, so new source and test files are picked up
without editing `project.pbxproj`.

Every preference goes through `PreferenceStore.defaults` (`Utils/AppPreferences.swift`) rather
than `UserDefaults.standard`, so a test can redirect the lot to a throwaway suite by subclassing
`IsolatedPreferencesTestCase`. Any test that writes a preference must: the suite runs in several
parallel host processes against one real defaults domain, and one clearing `selectedEngine` while
another builds a view model from it is a flake, not a failure.

## Engines

`OpenSuperWhisper/Engines/EngineKind.swift` owns the engine registration, persistence,
factory, and language-handling contracts. Follow its documentation when adding an engine.

The engine the user *chose* and the engine that can transcribe *now* are two different values, and
keeping them apart is the load-bearing rule of this area. `EngineSelector`
(`Engines/EngineSelection.swift`) is the pure function that picks the active one: the desired
engine when it can load, else the last one that actually loaded (`lastReadyEngine`), else the
starter model - and the interim tiers must also support the dictation language, since Paraformer
returns fluent Mandarin for German rather than refusing it. Nothing in that path ever writes
`selectedEngine`. `TranscriptionService` publishes the result as `selection`, prepares the desired
engine in the background (`ModelPreparation`), and switches over when it is ready.

`OpenSuperWhisper/Engines/EngineConfiguration.swift` is the single answer to "can this app
transcribe, and with what?" - it checks the stored engine against what is downloaded, recovers
onto another downloaded engine when it cannot load, and reports `.unavailable` when nothing can.
`recoverIfNeeded`, the call that writes that recovery, runs only once - at launch, before anything
constructs an engine - and it skips a selection whose download was in flight when the app quit
(`pendingEnginePreparation`), so quitting mid-download does not undo the choice that started it.
Every check after that is read-only. Anything that would leave the app with an engine it cannot
load - a new onboarding path, a new engine, a new way to reach `hasCompletedOnboarding` - has to go
through it. `EngineConfigurationTests`, `EngineSelectionTests` and
`BackgroundModelPreparationTests` pin the recovery order, that a working configuration is never
changed behind the user's back, and that no fallback ever becomes the user's selection; when
nothing can transcribe the user is told (`DictationFailureOutcome`) and their audio is kept as a
failed recording rather than deleted.

Model preparation is never modal. History stays open, searchable and playable throughout, and
dictation is disabled only when `EngineSelector` finds nothing at all. Progress is a percentage
only for byte-download phases and an indeterminate `Preparing model…` otherwise -
`ModelPreparationStage` is the one place that decides which, and `docs/upstream-issues.md` records
why FluidAudio's own fraction cannot be used as-is. Transcription progress and model-preparation
progress are separate published values and must stay that way; they overlap routinely.

A release can ship with SenseVoice-Small already installed. The weights are a build input, never
committed: `docs/starter-model.md` is the whole story - staging, the `Package Starter Model` build
phase, and `StarterModel.installIfNeeded()` at launch. A checkout without the artifact builds and
behaves exactly as before, which is what CI does. Bundling weights changed a licence position that
`docs/speech-model-attribution.md` had stated absolutely; read that file before bundling anything
else.

Tests must not download models. `TranscriptionService` skips both the engine load and background
preparation under `OpenSuperWhisperApp.isRunningTests`, because a test pins `availability` to
describe a Mac it is not running on; assert the decision through `refreshSelection(availability:)`,
which is pure.

`OpenSuperWhisper/Engines/EngineCatalog.swift` owns everything user-facing about an engine -
picker name and order, the honest caveats, download size, cache path and the attribution links.
Settings and onboarding both read it; neither may write a second copy of the copy.
`OpenSuperWhisperTests/EngineCatalogTests.swift` pins the licence obligations (the model name
must survive in the UI, the credit and three links must exist) and the caveats, so shortening
that text fails a test instead of quietly dropping an obligation.

`OpenSuperWhisper/Onboarding/OnboardingModelCatalog.swift` is the first-run model list: which
rows are offered, in what order, and to whom. A row that exists for one language is shown only
to users dictating it (or who already downloaded it), the same rule Settings applies to the
Hebrew Whisper fine-tune. `OnboardingModelCatalogTests` pins the ordering, the recommendation
and that engine rows take their name, size and caveats from `EngineCatalog`.

Onboarding's one obligation is that the row it shows as selected is the row whose engine is
persisted - including the automatic selection of an already-downloaded row, which for one release
set only `selectedModelId` and shipped users past onboarding with no engine at all. Every
selection goes through `selectModel`, and `commitSelectedModel` is the guard on the way out;
`OnboardingEngineSelectionTests` injects the download state so both hold without a download.

`OpenSuperWhisper/Engines/Audio/` is the engine-neutral audio path every engine shares:
16 kHz PCM decoding, the bundled Silero VAD, and chunking for engines with an input ceiling.
An engine must not reach into another engine for any of it. Engines whose backend rejects or
silently clamps long input take `AudioChunkSource` with an `AudioChunkBudget`; the budget type
documents why each limit exists and `OpenSuperWhisperTests/AudioChunkerTests.swift` pins them.

Model weights are downloaded at runtime and never bundled into the `.app` - some are
redistributed under licences that require attribution and forbid rebranding. Any engine whose
model the app downloads needs an entry in `docs/speech-model-attribution.md`.

Engine limits are measured against the pinned FluidAudio, not read off its config constants,
because several of them mislead. Defects found there that the app ships around rather than
patches - and the reasons - live in `docs/upstream-issues.md`; add to it instead of rediscovering
them. Model-backed regression tests are opt-in on locally generated fixtures under
`OpenSuperWhisperTests/Fixtures/` (gitignored); each engine's integration test documents how to
generate its own, and fixture filenames must be unique across engines because the test bundle
flattens them all into one Resources directory.

## Storage

The recordings database is GRDB, with its full schema history in `RecordingStore.makeMigrator()`
(`OpenSuperWhisper/Models/Recording.swift`). Schema changes go in a new named migration; never
edit an applied one, since the identifier is what decides whether a user's database already ran it.

`terms.json` beside it is the second store: the personal terms dictionary, deliberately a plain
hand-editable file outside the database because it has a different lifecycle and must not be
touched by the recordings retention policy. See `docs/personal-terms.md`.

Both live in `~/Library/Application Support/<bundle id>/`, along with downloaded models, so the
bundle identifier is load-bearing user data - changing it hands every user an empty app. The
EchoForge rename did exactly that once, on purpose (it is what lets an upstream install stay), and
`docs/install.md` tells users what they lose and how to copy it across. Do not change it again.

## Permissions

`OpenSuperWhisper/PermissionsManager.swift` owns the permission state the root view switches on.
`isMissingRequiredPermission` is that switch: microphone and Accessibility only - Input Monitoring
is conditional on the shortcut mode and must never gate the app. Accessibility is the one grant
made entirely outside the app, with no completion handler to hang off the way microphone and Input
Monitoring have; the file documents the triggers that stand in for one and why the obvious-looking
`NSWorkspace` notification is not among them. Statuses are read through `PermissionStatusReading`
so the refresh and transition logic is testable at all - `PermissionsManagerRefreshTests` pins it,
and the real TCC calls are exactly what that seam leaves out.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
