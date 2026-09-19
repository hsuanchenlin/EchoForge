# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: the names,
the build, the tests, the release path, and a map of the subsystems with their authoritative
documents. It is deliberately short. Every subsystem has one `docs/*.md` that is its whole
story, and the code beside it carries the measurements; read those before changing anything
they describe, and put new detail there rather than here.

## Naming

**Three names, and which one is authoritative for what.** Do not collapse them.

- **Kongweh** is the product - the only name a user sees. It lives in `CFBundleDisplayName`,
  `CFBundleName`, the permission strings, and every string in the UI and user-facing docs.
- **EchoForge** is the *release and storage* identity: `com.hsuanchenlin.EchoForge`,
  `PRODUCT_NAME` (so `EchoForge.app` and `EchoForge.dmg`), the GitHub repository, and
  `~/Library/Application Support/com.hsuanchenlin.EchoForge/`.
- **OpenSuperWhisper** is the *code* identity: the Xcode project, targets, scheme, source
  directories and the Swift module (`@testable import OpenSuperWhisper`, `-only-testing:`).

The code keeps upstream's paths so merges from `Starmel/OpenSuperWhisper` stay clean. The
storage identity names the folder holding every user's recordings, terms and models, their
Keychain item and their TCC grants, and the updater finds a release by those exact file
names - so changing it is a migration that hands every user an empty app. Do not change it.
`AppIdentityTests` pins both halves. `docs/app-identity.md` has the rest, including why
`GENERATE_INFOPLIST_FILE` is off and why the app icon is generated from a script.

## Build

Submodules are required before anything builds: `git submodule update --init --recursive`
(`libwhisper/whisper.cpp` and `asian-autocorrect`). The toolchain is Xcode plus Homebrew
`cmake`, `libomp` and a Rust toolchain; `Scripts/build_release.sh` checks all of them up
front and names what to install.

`./run.sh build` builds everything (CMake for whisper.cpp, cargo for the autocorrect dylib,
then `xcodebuild`); `./run.sh` also launches the app. The `OpenSuperWhisper` scheme builds
**two** products - the app and the `echoforge` command-line tool - so both compile in CI and
in a release build, and the DMG still contains only the app. CI runs exactly `./run.sh build`
(`.github/workflows/build.yml`) and does not run tests. The GitHub check name is the job name
`build`; a repository ruleset requires it on pull requests to `master`. This repository is a
fork, so Actions has to stay enabled in the Actions tab or pull requests report no checks.

Targets use Xcode file-system-synchronized groups, so new source and test files are picked up
without editing `project.pbxproj`.

## Tests

```
xcodebuild test -scheme OpenSuperWhisper -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO -only-testing:OpenSuperWhisperTests
```

The tool's tests are a separate target with no host app: `-only-testing:EchoForgeCLITests`
in the same command.

- Five tests fail on any machine without the right hardware and TCC grants, independent of
  your change: `ClipboardUtilPasteIntegrationTests` (drives its **own** TextEdit through
  Accessibility - `TextEditTestInstance` owns that rule) and the `MicrophoneService*` cases
  that reach real CoreAudio devices. Verify against a clean checkout before assuming you
  broke them.
- Every preference goes through `PreferenceStore.defaults` (`Utils/AppPreferences.swift`),
  never `UserDefaults.standard`. Any test that writes a preference subclasses
  `IsolatedPreferencesTestCase`: the suite runs in parallel host processes against one real
  defaults domain, and a stray write can reach the developer's Keychain and hang the run.
- Tests must not download models: `TranscriptionService` skips engine load and preparation
  under `isRunningTests`; assert engine decisions through the pure
  `refreshSelection(availability:)`. Model-backed tests are opt-in on gitignored fixtures.
- Many tests are source scans or pixel/geometry reads that stand in for a runtime rule
  (`CloudPrivacyTests`, `CLISeamTests`, `ModalDismissalOnPowerOffTests`,
  `SettingsTabBarGeometryTests`, ...). Read the header before weakening one.

`docs/testing.md` has the detail behind each of these.

## Release

`Scripts/build_release.sh` is the single release build path (`notarize_app.sh` and
`make_release.sh` are wrappers over it). It builds, ad-hoc signs, packages `EchoForge.dmg`
with its `.sha256`, and runs `Scripts/verify_release_package.sh`, which is what decides an
artifact is publishable: it **starts the app** (`ECHOFORGE_LAUNCH_CHECK=1`), because
`codesign --verify` passed on the unopenable v0.3.0. Signing mode and hardened runtime are
one decision - Developer ID on, ad-hoc off - or the app dies in dyld before `main`.

This fork has no Developer ID certificate, so releases are unsigned and unnotarized and users
get past Gatekeeper by hand; `docs/install.md` is the one end-user home for that and the
README must not grow a second copy. A release is **thin** - no model weights; they arrive as
model packs (`docs/model-packs.md`). The disk image holds the app and nothing else.

Publishing happens **on `master`** after the release PR merges: tag `X.Y.Z` (bare since
0.9.1), release `EchoForge X.Y.Z`, body `docs/release-notes/vX.Y.Z.md` verbatim, assets the
DMG pair from one build run plus the hand-built `echoforge-X.Y.Z-darwin-arm64.tar.gz` for
the Homebrew tap. Version bumps go in `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for
every target and configuration; `ReleaseVersionTests` pins that and that notes exist for the
version. Older releases and tags are never edited. `docs/release_build.md` is the whole story.

## Architecture map

Where each subsystem lives, and the document that is its whole story. When a doc is named
here, it is authoritative over this file.

| Area | Code | Story |
| --- | --- | --- |
| App identity, Info.plist, icon | `OpenSuperWhisper-Info.plist`, `Scripts/GenerateAppIcon.swift` | `docs/app-identity.md` |
| Release build and publishing | `Scripts/build_release.sh`, `Scripts/verify_release_package.sh` | `docs/release_build.md`, `docs/install.md` |
| In-app updater, About pane | `OpenSuperWhisper/Updates/`, `EchoForgeCore/Updates/` | `docs/updates.md` |
| Command-line tool | `EchoForgeCLI/`, `EchoForgeCore/` | `docs/cli.md` |
| Engine selection, recovery, preparation, catalog | `OpenSuperWhisper/Engines/` | `docs/engines.md` |
| Engine shortcut (⌥M) | `Engines/EngineCycle.swift`, `EngineSwitcher.swift`, `EngineSwitchHUD/` | `docs/engine-shortcut.md` |
| Model packs, thin releases | `Engines/ModelPack*.swift`, `ModelPacks.json` | `docs/model-packs.md` |
| Model inventory in Settings | `Engines/ModelInventory*.swift`, `ModelRemoval.swift` | `docs/model-inventory.md` |
| Bundled starter model (opt-in) | `Engines/StarterModel.swift` | `docs/starter-model.md` |
| Model licences and attribution | `Engines/EngineCatalog.swift` | `docs/speech-model-attribution.md` |
| FluidAudio defects shipped around | `Engines/SenseVoiceDecoding.swift` and others | `docs/upstream-issues.md` |
| English + Chinese in one utterance | `EngineKind.bilingualDictation` | `docs/bilingual-dictation.md` |
| Live dictation | `OpenSuperWhisper/Live/` | `docs/live-dictation.md` |
| Latency measurements, the queue | `TranscriptionQueue*.swift`, `TranscriptionService.swift` | `docs/dictation-latency.md` |
| File transcription queue | `FileDropHandler.swift`, `TranscriptionQueue.swift` | `docs/file-transcription.md` |
| Cloud provider (opt-in) | `OpenSuperWhisper/Cloud/` | `docs/cloud-api.md` |
| Text post-processing stages | `Utils/TextPostProcessor.swift`, `Rewriting/` | `docs/text-post-processing.md` |
| Style rewriting | `OpenSuperWhisper/Rewriting/` | `docs/style-rewriting.md` |
| Chinese output script | `Utils/ChineseScriptNormalizer.swift` | `docs/chinese-script.md` |
| Personal terms, Whisper prompt | `Utils/PersonalTermsCorrector.swift`, `Engines/WhisperInitialPrompt.swift` | `docs/personal-terms.md` |
| Spoken corrections | `Utils/SpokenCorrection.swift` | `docs/spoken-corrections.md` |
| App vocabulary | `OpenSuperWhisper/Context/` | `docs/app-vocabulary.md` |
| App-aware style | `Rewriting/AppDetector.swift`, `AppStyleMapping.swift` | `docs/app-aware-style.md` |
| Spoken intents (Ask, Translate) | `Utils/SpokenIntentRouter.swift` | `docs/spoken-intents.md` |
| Voice snippets | `Models/VoiceSnippet*.swift` | `docs/voice-snippets.md` |
| YouTube latest video (⌥Y) | `OpenSuperWhisper/YouTube/` | `docs/youtube-latest-video.md` |
| Voice edit (⌥E) | `Rewriting/SelectionEditRewrite.swift` | `docs/selection-edit.md` |
| Ask panel (⌥A) | `OpenSuperWhisper/Ask/` | `docs/ask-panel.md` |
| Screen questions (⌥S) | `Utils/ScreenCaptureService.swift`, `Vision/` | `docs/screen-context.md` |
| History AI fix | `History/TranscriptCorrectionCoordinator.swift`, `Rewriting/TranscriptCorrection.swift` | `docs/history-ai-fix.md` |
| History card | `History/RecordingRow.swift` | `docs/history-card.md` |
| History provenance | `EchoForgeCore/History/RecordingProvenance.swift` | `docs/history-provenance.md` |
| History search and export | `EchoForgeCore/History/HistorySearchQuery.swift` | `docs/history-search-export.md` |
| Database, row creation, `terms.json` | `Models/RecordingStore.swift`, `EchoForgeCore/History/` | `docs/history-storage.md` |
| Dictation card and capsule HUD | `Indicator/`, `CapsuleHUD/` | `docs/capsule-hud.md` |
| Settings sheet, tab bar, power-off | `SettingsTabBar.swift`, `SettingsSheetLayout.swift`, `Utils/PowerOffPresentationGuard.swift` | `docs/settings-sheet.md` |
| Setup Health tab | `OpenSuperWhisper/SetupHealth/` | `docs/setup-health.md` |
| Menu bar | `OpenSuperWhisper/MenuBar/` | `docs/menu-bar.md` |
| Permissions | `PermissionsManager.swift` | `docs/permissions.md` |

## Invariants every session should know

These are the rules that cross subsystem boundaries, stated once. The doc named beside each
has the measurement and the test that pins it.

- **Chosen versus active.** The engine the user chose (`selectedEngine`) and the engine that
  can transcribe now (`EngineSelector`) are different values. No fallback, recovery or
  shortcut ever writes the user's selection; `EngineSelectionCommand` is the one writer.
  `EngineConfiguration.recoverIfNeeded` runs once at launch and nothing else recovers.
  (`docs/engines.md`)
- **Security boundaries are types, not parsers.** `UpdateManifest`, `ModelPackManifest`,
  `CloudEndpoint` and `YouTubeVideoURL` each accept exactly the shape they document and refuse
  everything else with a reason. Do not weaken one; the tests assert the refusals.
  (`docs/updates.md`, `docs/model-packs.md`, `docs/cloud-api.md`, `docs/youtube-latest-video.md`)
- **On-device by default.** Only transcription and translation have a cloud path, and only
  through `CloudAccess.resolve`, which reads the Keychain last so a default install never
  touches it. Every other model feature has `OnDeviceModelFeature.cloudFeature == nil`.
  (`docs/cloud-api.md`)
- **Nothing between engine and paste may fail or invent.** The transcript stage and the live
  insertion stage are synchronous and cannot fail; the rewriting stage is a peer that falls
  back to the deterministic text, bounded by `StyleRewriteGuard`, and a style may omit but
  never invent. `decodeRaw` and `finish` run in one serialised frame. (`docs/text-post-processing.md`,
  `docs/style-rewriting.md`)
- **Everything unrecognised is dictation.** `SpokenIntentRouter` is pure grammar; each hotkey
  has one `DictationPurpose`, and nothing crosses between them. (`docs/spoken-intents.md`)
- **The microphone is owned.** `RecordingSessionClaim` grants one session at a time, callers
  name the session they stop, and every surface that records watches
  `AudioRecorder.failedStart`. (`docs/ask-panel.md`, `docs/dictation-latency.md`)
- **The engine is owned too, from before it loads.** Every transcription - dictation, live
  utterance decode, queued file, post-processing alone - runs inside `runTranscription`, which
  reserves its `TranscriptionFrame` synchronously with the generation bump, before the engine
  load can suspend, and releases it in its own `defer`. Nothing else waits on, clears or
  bypasses that frame. (`docs/dictation-latency.md`)
- **HUDs never take focus.** Dictation ends by pasting into the app the user was in; only the
  Ask panel and the channel picker may activate, and they do it with
  `activate(ignoringOtherApps:)`. (`docs/capsule-hud.md`, `docs/ask-panel.md`)
- **The only app signal is the bundle identifier.** No window title, document name or URL is
  read, logged or sent, for app vocabulary or app-aware style. (`docs/app-aware-style.md`)
- **History is written, never guessed, and carries no id, URL or credential.** Rows are made
  only by `Recording.newRow`; provenance is written only by `RecordingProvenance`; filtering
  and search happen in SQL. (`docs/history-storage.md`)
- **Schema changes are new migrations.** Never edit an applied one in
  `RecordingSchema.makeMigrator()`. The tool opens the database read-only and never migrates.
- **Every `.sheet` and `.confirmationDialog` carries `.dismissesOnPowerOff`**, or an open
  Settings sheet cancels the user's restart. (`docs/settings-sheet.md`)
- **Only microphone and Accessibility gate the app.** Input Monitoring and Screen Recording
  are conditional and never polled. (`docs/permissions.md`)
- **Updates are three user actions** with no background check, the download never runs on
  `URLSession.shared`, and from `.installing` on the staged bundle belongs to the swap script.
  (`docs/updates.md`)

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
