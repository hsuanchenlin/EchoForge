# Running and writing tests

## The commands

```
xcodebuild test -scheme OpenSuperWhisper -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation \
  -clonedSourcePackagesDirPath SourcePackages CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO -only-testing:OpenSuperWhisperTests
```

The command-line tool's tests are a separate target with no host app, so they are a separate
run: `-only-testing:EchoForgeCLITests` in the same command ([cli.md](cli.md) has what they
cover). CI (`.github/workflows/build.yml`) runs exactly `./run.sh build` and does **not** run
tests.

Targets use Xcode file-system-synchronized groups, so new source and test files are picked
up without editing `project.pbxproj`.

## Tests that need the machine

Five tests fail on any machine without the right hardware and TCC grants, independent of
your change - verify against a clean checkout before assuming you broke them:
`ClipboardUtilPasteIntegrationTests` (drives TextEdit through Accessibility) and the
`MicrophoneService*` cases that reach real CoreAudio devices.

That paste class drives a real app on the developer's own desktop, so it owns what it
touches: it launches its **own** TextEdit process (`createsNewApplicationInstance`) and may
only drive and kill that one - `TextEditTestInstance` is the ownership decision and
`TextEditTestInstanceTests` holds it, including a source scan for a second termination call.
It used to match on the bundle identifier, so class setUp and tearDown `forceTerminate`d
every running TextEdit and SIGKILLed whatever document the developer had open. The same rule
covers keystrokes: CGEvents go to the frontmost app, so nothing destructive is posted unless
the owned instance actually came to the front, and the test skips rather than typing into
someone else's window.

## Preferences are isolated per test

Every preference goes through `PreferenceStore.defaults` (`Utils/AppPreferences.swift`)
rather than `UserDefaults.standard`, so a test can redirect the lot to a throwaway suite by
subclassing `IsolatedPreferencesTestCase`. Any test that writes a preference must: the suite
runs in several parallel host processes against one real defaults domain, and one clearing
`selectedEngine` while another builds a view model from it is a flake, not a failure. That
base class also drains the main queue before it restores the real defaults, and the comment
there says why: work a preference change woke up can outlive the test, and a re-resolve that
runs against the developer's own settings can reach the Keychain - which an ad-hoc-signed
test host answers with a system dialog that hangs the whole run. `CloudAccess` refuses to
read the real Keychain under a test host for the same reason.

## Tests must not download models

`TranscriptionService` skips both the engine load and background preparation under
`OpenSuperWhisperApp.isRunningTests`; assert engine decisions through the pure
`refreshSelection(availability:)`. Model-backed regression tests are opt-in on locally
generated fixtures under `OpenSuperWhisperTests/Fixtures/` (gitignored) -
[engines.md](engines.md) has the rules.

## Tests that stand in for a runtime

Several tests exist because the thing they guard cannot be seen at build time. When you meet
one, read its header before weakening it:

- `ReleaseVersionTests` - version settings agree across targets, and the reported version has
  release notes ([release_build.md](release_build.md)).
- `ReleasePackagingTests` - runs `Scripts/tests/verify_release_package_test.sh`.
- `AppIdentityTests` and `AppIconArtworkTests` - [app-identity.md](app-identity.md).
- `SettingsTabBarFitTests` and `SettingsTabBarGeometryTests` - [settings-sheet.md](settings-sheet.md).
- `ModalDismissalOnPowerOffTests`, `FailedRecordingStartTests`, `CLISeamTests`,
  `CloudPrivacyTests`, `HistoryProvenancePrivacyTests`, `AppStyleMappingTests`,
  `WhisperInitialPromptTests`, `EngineWeightsPreparationTests` - source scans that keep a
  rule true across the tree; each names the rule it holds.
