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

## Engines

`OpenSuperWhisper/Engines/EngineKind.swift` owns the engine registration, persistence,
factory, and language-handling contracts. Follow its documentation when adding an engine.

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
