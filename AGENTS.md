# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Build

Submodules are required before anything builds - a fresh clone or worktree needs
`git submodule update --init --recursive` (`libwhisper/whisper.cpp` and `asian-autocorrect`).

`./run.sh build` builds everything (CMake for whisper.cpp, cargo for the autocorrect dylib,
then `xcodebuild`); `./run.sh` also launches the app. CI runs exactly `./run.sh build`
(`.github/workflows/build.yml`) and does not run tests.

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

Adding a speech engine means adding a case to `EngineKind`
(`OpenSuperWhisper/Engines/EngineKind.swift`); its `makeEngine()` and `LanguageUtil` switch
exhaustively, so the compiler lists the sites that must handle it. The case raw values are the
strings persisted under the `selectedEngine` default - they are storage format, not display
text, and an unrecognised stored value must keep falling back to Whisper.

## Storage

The recordings database is GRDB, with its full schema history in `RecordingStore.makeMigrator()`
(`OpenSuperWhisper/Models/Recording.swift`). Schema changes go in a new named migration; never
edit an applied one, since the identifier is what decides whether a user's database already ran it.

`terms.json` beside it is the second store: the personal terms dictionary, deliberately a plain
hand-editable file outside the database because it has a different lifecycle and must not be
touched by the recordings retention policy. See `docs/personal-terms.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
