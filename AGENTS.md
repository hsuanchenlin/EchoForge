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
The toolchain is Xcode plus Homebrew `cmake`, `libomp` and a Rust toolchain;
`Scripts/build_release.sh` checks all of them up front and names what to install.

`./run.sh build` builds everything (CMake for whisper.cpp, cargo for the autocorrect dylib,
then `xcodebuild`); `./run.sh` also launches the app. CI runs exactly `./run.sh build`
(`.github/workflows/build.yml`) and does not run tests.

## Release

`Scripts/build_release.sh` is the single release build path, for both this fork's ad-hoc
builds and a Developer ID build (`notarize_app.sh` and `make_release.sh` are wrappers over
it). It exists because there used to be no script for the ad-hoc case at all - only a
Developer ID one this fork cannot run - so releases were assembled by hand, and v0.3.0
shipped an app that could not start on any Mac.

Signing mode and hardened runtime are one decision, not two. Hardened runtime turns on
library validation, which requires every loaded library to carry the process's Team ID; an
ad-hoc signature has none, and macOS treats each ad-hoc-signed file as its own identity, so
an ad-hoc build with hardened runtime is refused its own embedded dylibs and dies in dyld
before `main`. Developer ID → on; ad-hoc → off. See `docs/release_build.md`.

`Scripts/verify_release_package.sh` is what decides whether an artifact is publishable, and
every release build runs it. `codesign --verify --deep --strict` is not that check - it
passed on the published, unopenable v0.3.0 DMG. The verifier's load-bearing part is that it
**starts the app**: `ECHOFORGE_LAUNCH_CHECK=1` makes `LaunchDiagnostics` report which
bundled libraries dyld mapped and exit from `AppEntryPoint`, before anything touches the
operator's preferences, model cache or database. `Scripts/tests/verify_release_package_test.sh`
tests the verifier against synthesised broken bundles and `ReleasePackagingTests` runs it - so
that script must never start a fixture that cannot start. Such a bundle is killed by SIGABRT
and macOS answers with a crash report and a "quit unexpectedly" dialog on every test run;
its unlaunchable cases are asserted off the signature and verified with `--no-launch`
instead, and the script's header says how.

This fork has no "Developer ID Application" certificate and no `notarytool` keychain
profile, so its releases are unsigned and unnotarized and users have to get past Gatekeeper
by hand. `docs/install.md` is the one end-user home for that: install path, the two Gatekeeper
workarounds, permissions, and how to use the Chinese engines. The README links to it and
must not grow a second copy. Per-release notes live in `docs/release-notes/vX.Y.Z.md` and
are what the GitHub release body is created from. Version bumps go in `MARKETING_VERSION`
and `CURRENT_PROJECT_VERSION` in `OpenSuperWhisper.xcodeproj/project.pbxproj`, which carry
them once per target and configuration - keep all of them in step, the way `make_release.sh`
does. `OpenSuperWhisperTests/ReleaseVersionTests.swift` pins that: the two settings agree
across every target and configuration, and the version the app reports has notes carrying
its number and the Gatekeeper workaround.

Publishing is the last step and it happens **on `master`**, not on the release branch. Every
`vX.Y.Z` tag points at the squashed release commit the release PR produced, so the GitHub
release - tag `vX.Y.Z`, name `EchoForge X.Y.Z`, body the notes file verbatim, assets
`EchoForge.dmg` and `EchoForge.dmg.sha256` and nothing else - is created only after that PR
is merged. The two assets are the pair from one `Scripts/build_release.sh` run and are never
rebuilt between hashing and upload, for the reason `docs/release_build.md` measures. Older
releases and tags are never edited, replaced or force-updated.

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

The download is written around one measured platform fact: **`URLSession` delivers progress
callbacks only to a session's own delegate, never to one passed per task** - four megabytes
produced zero callbacks that way and fourteen the other. That is why `ResumableDownload` owns
the session it runs on instead of the installer holding a shared one, and it is worth
re-measuring before anyone "simplifies" it back. The **download** must never run on
`URLSession.shared`: its `timeoutIntervalForResource` is seven days, which is how a 0.5.0
update sat at 0% forever after a connection died silently mid-transfer. The *check* is a
different case and deliberately stays on `.shared` (`GitHubReleaseMetadataFetcher`): it is one
small GET whose request carries its own 20 s `timeoutInterval`, so it cannot wedge the same way.

A transfer **resumes**. The partial file and the validator it was fetched with live under
Caches (`PartialDownloadStore`), and the next attempt asks for `bytes=<n>-` conditioned on
`If-Range`, so a failure at 95% of a large asset costs one press rather than the whole download
again. `ResumeDecision` is where the server's answer is read, as a pure function: appending a
200's whole-file body onto an existing partial produces a file of exactly the right length made
of the wrong bytes, and that is the failure the whole shape is arranged around. A partial
survives a failed or cancelled *download* and never survives a failed *verification*.
`ResumableFileDownloader` is the same transfer for callers that only need the bytes -
`ModelPackInstaller` is the other one - and `StallWatchdog` is shared by both.

Progress is reported as **bytes**, not a fraction: `0%` used to cover everything from an
unanswered request to the first 1.1 MB of a 212 MB asset, so a slow download and a dead one
looked identical. `DownloadProgress` carries the counts, `UpdateProgress.connecting` is the
stretch before the first byte, and `DownloadProgressText` owns the wording.

Releases publish a `.sha256` sidecar and the updater checks it (`UpdateManifest.checksumURL`).
A release without one still installs - none before v0.5.2 published any - but a sidecar that
exists and does not match, or cannot be read, fails the install rather than being skipped.
`UpdateDownloadSettings` carries the configuration and the stall interval, and
the watchdog it feeds measures **silence, not throughput** - a slow link is a normal way to
take a 222 MB update and must complete, so nothing there may become a rate floor or a cap on
total transfer time. `UpdateDownloadWatchdogTests` drives all of it against a real loopback
HTTP server, because a `URLProtocol` stub hands `URLSession` the body in one piece and so
cannot show progress arriving at all.

The pane's states are the other half: a download can be cancelled (back to `.available`), a
failure carries the release so it can be retried in one press, and `.verifying` is its own
state so the seconds `hdiutil` and `codesign` take are never shown as a download that has
stopped moving.

The swap runs in a detached shell script that waits for the app to exit first, because a running
bundle cannot replace itself; `UpdateInstaller` documents the sequence. Two consequences of that
wait are load-bearing, and both once made "Install and Relaunch" quietly reopen the old version.
From `UpdateState.installing` onward the staged bundle belongs to the script, so nothing may delete
it on the way out - a failed `mv` is not a visible failure, it is the rollback trap silently
restoring the old bundle and relaunching it. And quitting has to actually happen, promptly, since
the script is already spinning on this pid: `NSApplication.terminate` is a request that a window or
sheet can delay, so `RunningApplicationTerminator` backs it with a forced exit.
`UpdateInstallerTests` pins both, plus that the script is written outside the staging directory it
deletes.

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

That paste class drives a real app on the developer's own desktop, so it owns what it touches:
it launches its **own** TextEdit process (`createsNewApplicationInstance`) and may only drive and
kill that one - `TextEditTestInstance` is the ownership decision and `TextEditTestInstanceTests`
holds it, including a source scan for a second termination call. It used to match on the bundle
identifier, so class setUp and tearDown `forceTerminate`d every running TextEdit and SIGKILLed
whatever document the developer had open. The same rule covers keystrokes: CGEvents go to the
frontmost app, so nothing destructive is posted unless the owned instance actually came to the
front, and the test skips rather than typing into someone else's window.

Targets use Xcode file-system-synchronized groups, so new source and test files are picked up
without editing `project.pbxproj`.

Every preference goes through `PreferenceStore.defaults` (`Utils/AppPreferences.swift`) rather
than `UserDefaults.standard`, so a test can redirect the lot to a throwaway suite by subclassing
`IsolatedPreferencesTestCase`. Any test that writes a preference must: the suite runs in several
parallel host processes against one real defaults domain, and one clearing `selectedEngine` while
another builds a view model from it is a flake, not a failure. That base class also drains the main
queue before it restores the real defaults, and the comment there says why: work a preference change
woke up can outlive the test, and a re-resolve that runs against the developer's own settings can
reach the Keychain - which an ad-hoc-signed test host answers with a system dialog that hangs the
whole run. `CloudAccess` refuses to read the real Keychain under a test host for the same reason.

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

A user's engine choice is carried out in exactly one place, `EngineSelectionCommand`, shared by the
Settings picker, the Cloud pane's toggle and the ⌥M engine shortcut - it writes `selectedEngine`,
moves the dictation language when the new engine cannot do it, keeps `CloudTranscriptionSelection`'s
bookkeeping, posts `.selectedEngineChanged` for an open pane to follow, and reloads the service.
The shortcut itself is `EngineCycle` (the pure decision: which engines a press may land on, the
wrap-around, and the mid-dictation rule) plus `EngineSwitcher` (reads the machine, and waits);
`docs/engine-shortcut.md` is its whole story. Three things there are absolute: a press never lands
on an engine that could not transcribe the next dictation - so it never changes the dictation
language either, since an engine that would need that is skipped; a press during a dictation is
deferred until the session is over rather than applied or refused, and "in flight" spans the whole
session because every individual flag is briefly false between the recorder stopping and the
transcription starting; and the cloud engine is offered only on `CloudAccess.isSelectable`, which
never grants consent and never reads the Keychain on an install that has not consented. A press's
only feedback is `EngineSwitchHUD`, so it is drawn on **every** attached display rather than on the
one holding the focused window - that guess is what made 0.8.0's working shortcut look absent on a
two-display Mac - and posted as a VoiceOver announcement, which a never-key panel otherwise has no
way to reach. Settings → Models states the shortcut in the binding actually in force
(`EngineShortcutHint`), and nothing on that path may write one.

Model preparation is never modal. History stays open, searchable and playable throughout, and
dictation is disabled only when `EngineSelector` finds nothing at all. Progress is a percentage
only for byte-download phases and an indeterminate `Preparing model…` otherwise -
`ModelPreparationStage` is the one place that decides which, and `docs/upstream-issues.md` records
why FluidAudio's own fraction cannot be used as-is. Transcription progress and model-preparation
progress are separate published values and must stay that way; they overlap routinely.

A release is **thin**: it ships no model weights, and `docs/model-packs.md` is the whole story.
Bundling them made the DMG 222 MB, of which 212 MB was one model - and models live in Application
Support and survive an app replacement, so an updating user downloaded, verified, mounted and copied
bytes their machine already had, then never read them (measured across v0.5.1 → v0.5.2: two files
changed, 94% of the bundle identical). Weights now arrive as a **model pack**: one engine's cache
directory as a versioned, SHA-256'd `.tar.gz` published as a release asset, installed by
`ModelPackInstaller` into the directory the engine already downloads into, so an installed pack is
indistinguishable from a finished download. `ModelPackManifest` is its security boundary and refuses
the same way `UpdateManifest` does - including any engine this project has not written a
redistribution position for, which is exactly one (`enginesClearedForRedistribution`).
`OpenSuperWhisper/ModelPacks.json` is the shipped list, and an entry in it is the whole switch: an
engine with one gets the verified pack, an engine without one downloads weights exactly as before.
It lists one pack today - SenseVoiceSmall 1.0.0, published under the `models/<id>/<version>` tag
namespace with `minimumAppVersion` 0.6.0, since no released app before that carries the installer.
Every field there names bytes that are already published, so editing one without re-publishing the
asset gives every machine a pack that fails its checksum and silently falls back;
`ModelPackManifestTests` pins the digest, the size, the URL and that the pack fills the cache
SenseVoice actually loads from.

`Engines/EngineWeightsPreparation.swift` is the one place "make this engine's weights ready" turns
into fetched bytes, and all three paths that fetch weights go through it - background preparation,
Settings and onboarding. None of them may call an engine's `prepareModels` itself; that bypass is
what a published pack exists to close, and a source scan in `EngineWeightsPreparationTests` fails if
one appears. `ModelPackSelection` is the pure decision, and refuses a pack whose cache folder or
entries do not match what the engine loads. A failed pack falls back to the engine's own downloader
and a cancelled one does not, and the engine's own preparation always runs afterwards because only
it can pay the Neural Engine compile. `docs/model-packs.md` is the whole story.

The bundled path still exists and is opt-in (`ECHOFORGE_BUNDLE_STARTER_MODEL=1`), for an offline
install medium and for anyone still running a build that shipped one:
`docs/starter-model.md` covers staging, the `Package Starter Model` build phase, and
`StarterModel.installIfNeeded()` at launch. `Scripts/build_release.sh` verifies whichever way it
built - `--forbid-starter-model` by default. Bundling weights changed a licence position that
`docs/speech-model-attribution.md` had stated absolutely; read that file before bundling or
publishing anything else.

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

An engine that cannot refuse a language has to refuse its own output instead. Paraformer takes no
language parameter, so `LanguageUtil.paraformerLanguages` locking the picker to `zh` does nothing
about somebody speaking English: the model answers, as the tokeniser's sub-word units with `@@`
continuation markers in them (`docs/upstream-issues.md`), and that used to be pasted into whatever
the user was typing in. `ParaformerLanguageGuard` reads the joined transcript before the engine
returns it and fails the dictation - `TranscriptionError.unsupportedSpokenLanguage`, which
`DictationFailureOutcome` keeps the recording for, so switching engine and pressing regenerate is
all it costs. Three rules there are absolute. It classifies **output only**: nothing retokenises,
strips markers or repairs a transcript, because text that had to be repaired to be shown is a guess
pasted into someone's editor. The `@@` rule never stands alone - the model also returns whole Latin
words, and the marker depends on an upstream defect that may be fixed - so every predominantly-English
marker case in `ParaformerLanguageGuardTests` has a twin without one that the Latin-share rule has to
catch by itself. And it is tuned to fire rather than to be certain, because a false positive costs a
kept recording and one press while a false negative is corruption in the user's document. Two cases
sit outside both rules. Cantonese has no signal in the output at all - it comes back as fluent,
wrong Mandarin - and the engine's caveats say so instead. And a mostly-Mandarin recording with an
embedded English sentence is refused today only by its `@@` markers: the mixed fixture is 24 Han to
8 Latin letters, about a quarter, a share the guard accepts by design, so if upstream fixes
detokenisation the share rule lets it through and that mis-transcribed English reaches the user's
transcript.

Engine limits are measured against the pinned FluidAudio, not read off its config constants,
because several of them mislead. Defects found there that the app ships around rather than
patches - and the reasons - live in `docs/upstream-issues.md`; add to it instead of rediscovering
them. Model-backed regression tests are opt-in on locally generated fixtures under
`OpenSuperWhisperTests/Fixtures/` (gitignored); each engine's integration test documents how to
generate its own, and fixture filenames must be unique across engines because the test bundle
flattens them all into one Resources directory.

## Cloud

`OpenSuperWhisper/Cloud/` is the opt-in path to an OpenAI-compatible provider, and
`docs/cloud-api.md` is its whole story - including the table of exactly what leaves the device
and what never does. Everything else in this app is on-device and stays that way; the one
other request that carries anything the user configured is the YouTube channel feed below, which
carries a channel id and nothing about them.

**`CloudAccess.resolve` is the only way a request can exist.** Nothing can build one without a
`CloudCall` and only that function produces one, after checking in order: compiled in
(`CloudBuild`), the feature is set to Cloud, its consent is recorded, the base URL resolves, a
model is named, a key exists. The key is fetched **last**, so a default install never reads the
Keychain - `CloudAccessTests` asserts that, and `CloudPrivacyTests` asserts a default install
sends nothing at all. `CloudEndpoint` is the security boundary the way `UpdateManifest` is:
HTTPS or loopback (a local Ollama is a legitimate provider), no credentials, no query.

Two features and no more: transcription (`EngineKind.cloud` behind `TranscriptionEngine`) and
translation (`CloudStyleRewriter` behind `StyleRewriting`). Rewriting, Ask and screen queries have
**no** cloud path, enforced by `OnDeviceModelFeature.cloudFeature` returning `nil` rather than by
convention. Transcription's on/off is `selectedEngine == .cloud` and there is deliberately no
second preference beside it; translation, which has no engine, gets `cloudTranslationEnabled`.
Consent is separate from both (`CloudConsent`) because "the toggle was on" and "the person agreed"
are different states.

`EngineKind.usesCloudProvider` states once that this engine is never chosen *for* the user:
`EngineSelector` skips it in both interim tiers, `EngineConfiguration.recoveryOrder` never recovers
onto it, and `EngineCatalog.pickerOrder` has no row for it - it is first selected in the Cloud
pane, where the consent sheet is. A failed cloud dictation keeps the recording
(`DictationFailureOutcome`), because every one of those failures is transient or fixable. The API
key lives only in the Keychain (`CloudCredentialStore`) and only ever reaches the `Authorization`
header; everything printed or stored goes through `CloudRedaction` first, and a source scan in
`CloudPrivacyTests` holds both.

The offline-only variant is `Scripts/build_release.sh --offline-only`
(`ECHOFORGE_OFFLINE_ONLY` → `CloudBuild.isCompiledIn == false`). It is one value rather than `#if`
around the sources because `EngineKind` is switched exhaustively in over a dozen places; compiling
a case out means compiling every switch conditionally, which is how a variant stops being the same
build.

## Text post-processing

Everything between the engine and the user is three stages, described in
`docs/text-post-processing.md`: the deterministic transcript stage
(`TextPostProcessor.process` - Chinese output script, personal terms, then CJK
spacing), the style rewriting stage (`StyleRewriteService.apply`), and the
live-dictation insertion stage. The first and third are synchronous and cannot
fail; keep them that way.

A Chinese transcript is written in **one** script - the user's, Traditional
unless they chose otherwise (`chineseOutputScript`) - by `ChineseScriptNormalizer`
at the front of the transcript stage, with `docs/chinese-script.md` as the whole
story. Three things there are absolute. It is an **output** setting only: it never
makes recognition Chinese, never writes `whisperLanguage` and never tilts
auto-detect, and English dictation stays English even with the language set to
Chinese - it converts only text that both the language and the characters say is
Chinese (`ChineseScriptVariant.isChineseText`, the same predicate
`StyleRewriteLanguage` asks with). The mapping is **ICU** (`HanCharacterTransform`,
shared with `ChineseScriptFolding`) applied one character at a time and refused
unless it returns exactly one character, which is what makes "Latin, digits,
timestamps and punctuation come out untouched" a property rather than a hope; a
hand-maintained table is not an option. And it converts **the recognizer's words,
never the user's**, which is why it runs before the terms dictionary and why a
snippet template is inserted in the script it was typed in.

`OpenSuperWhisper/Rewriting/` is the rewriting stage and `docs/style-rewriting.md` is its
whole story. Two rules carry it. First, it is a **peer** of the terms dictionary, never its
parent: off, unavailable, timed out or refused, the deterministic output is what the user
gets, and `TranscriptionService.transcribeAudio` returns `StyledTranscript` so callers keep
both texts. Second, `StyleRewriteGuard` - not the prompt - is the boundary. The on-device
model obeys a spoken "ignore all previous instructions" every time; what stops it reaching
another app is the guard comparing the rewrite against the transcript (script, numbers,
symbols, dictionary terms, length). `StyleRewriteShape` is the only place a rule is relaxed,
and a style may omit but nothing may invent. Do not weaken either half - the tests assert
the refusals.

Style identifiers in `StyleRewriteCatalog` are persisted in preferences; renaming one resets
the user's choice. Instructions there are written for how the model actually behaves, not
how it should - the comments record what was measured.

The model is asked *in* the language of the dictation, not only about it: an English
instruction makes it answer Chinese dictation in English, and a Chinese instruction in the
wrong variant silently converts the user's script. So every style carries English,
Traditional and Simplified texts, `StyleRewriteLanguage` picks one **from the transcript**
(the dictation language only breaks ties), and `ChineseScriptVariant` (`Utils/`) is the
shared detector the guard also refuses a converted rewrite with. A new style needs all
three; `docs/style-rewriting.md` has the measurements.

A dictation can also be a **command** rather than text: `SpokenIntentRouter`
(`Utils/`) reads "Ask: …" / "請問…" / "Translate to Spanish: …" / "翻譯成…" off the
front of a transcript, and `SpokenIntentPipeline` runs whichever stage it names.
`docs/spoken-intents.md` is its whole story. Three things there are absolute.
The router is **pure grammar** - no model classifies a dictation, because that
would put a model in front of every one of them. **Everything unrecognised is
dictation**, so a marker that is also an ordinary word ("ask", "問") is only
promoted when the transcript shows the pause a real command has. And routing
needs *two* conditions - the user's `spokenIntentsEnabled` and a caller passing
`Settings(routesSpokenIntents: true)` - which only live dictation does, so a
dropped file or the Ask panel's own follow-up cannot route itself.

The third thing a dictation can be is a **voice snippet**: `VoiceSnippet` /
`VoiceSnippetStore` (`Models/`) hold the user's triggers and templates, the
router expands one on "insert [trigger]" / "插入[觸發詞]" / the trigger said
alone, and `docs/voice-snippets.md` is its whole story. Two rules carry it.
The template is inserted **byte for byte** - the rewriting stage is never
consulted, because a model asked to polish a form returns prose - and a trigger
fires only on an exact, whole match of something this user stored, which is what
keeps "insert a row here" and "the email signoff was wrong" as dictation. The
list lives in the defaults domain rather than beside `terms.json`, since the
dictionary is a file to be hand-edited and this is not; `Settings.voiceSnippets`
resolves the three gates (`spokenIntentsEnabled`, `routesSpokenIntents`,
`voiceSnippetsEnabled`) in one place.

The fourth is an **action**: `OpenSuperWhisper/YouTube/` opens the newest video
from a channel the user allowlisted - "open the latest YouTube video from
Veritasium" - and `docs/youtube-latest-video.md` is its whole story. Three things
carry it. The allowlist is the security model: a channel is named by the
canonical `UC…` id its owner typed into Settings, nothing resolves a handle or
searches, and no spoken name can reach a channel that is not listed. It is the
one command whose marker, once matched, does **not** fall back to dictation -
every spelling names YouTube *and* says which video is wanted, so a transcript
that begins with it is not a sentence anyone was writing, and an unknown or
ambiguous channel does nothing and says so rather than being pasted. And what
leaves the app is one documented feed request and one validated video URL handed
to Chrome by `NSWorkspace`: no scraping, no automation, no login, no injected
script, and no existing tab touched. `YouTubeVideoURL` is the boundary the way
`UpdateManifest` is, and `YouTubeFeedParser` refuses a feed that declares
entities rather than parsing it carefully.

`OpenSuperWhisper/Ask/` is the floating Ask panel (⌥A, or a spoken question) and
`docs/ask-panel.md` is its story. It runs the same on-device model as rewriting
and has deliberately **no `StyleRewriteGuard`**: a guard exists because a rewrite
replaces the user's words unread, and an answer is read before it goes anywhere.
It is also the one HUD that *takes* focus - a question box has to - which is why
the app to paste into is captured before the panel opens rather than read at
insertion time. `TranslationRewrite` is a sibling of `StyleRewriteService`, not a
style inside it, because that stage's rules say "never translate this"; the one
guard rule it relaxes is `StyleRewriteShape.translating`, and it relaxes it in
that one place. `AsyncDeadline` (`Utils/`) is the shared hard budget both model
callers use and documents why it is not a task group.

**⌥S** asks that same panel about the screen: `Utils/ScreenCaptureService.swift`
takes the shot and `Vision/` reads and answers it, with `docs/screen-context.md`
as the whole story. Three things there are absolute. The frontmost app is read
and the capture started **before** the panel opens, because opening it makes
EchoForge frontmost - and this app is never in the picture either way. Screen
Recording is **conditional** like Input Monitoring: read when ⌥S runs, never
polled, never part of `isMissingRequiredPermission`. And what is on the screen is
*data* - `ScreenQueryPrompt` fences the text read off it the way
`StyleRewritePrompt` fences a transcript - while `VisionEngine` stays shaped
around the image, so today's OCR-plus-text-model backend can be replaced by a
real multimodal one without touching anything above it.

Which style runs can be chosen by the app the user is dictating into
(`Rewriting/AppDetector.swift`, `Rewriting/AppStyleMapping.swift`, off by
default); `docs/app-aware-style.md` is its whole story. Two things there are
absolute. The only signal read is the frontmost app's **bundle identifier** - no
window title, document name or web address, and nothing logged or sent anywhere -
and that is enforced by the shape of `FrontmostApplicationReading` and
`DictationTargetApp` plus a source scan in `AppStyleMappingTests`. And a mapping
chooses *which* style runs, never *whether* one runs, and never writes
`styleRewriteStyleID` - the same separation `EngineSelector` keeps for engines.
The app is read once per session (`IndicatorViewModel.dictationTarget`) and
reaches the pipeline through `Settings(dictationTarget:)`, whose `nil` default
means "no app has a say": dropped files, the queue, and history regenerates.

Showing a user what post-processing changed is one implementation, not two: `TextDiffUtil`
(`Utils/`) compares the stored original with the final text and `TextDiffView` styles the
result, for both the Settings preview and the history row's "Compare". It must reproduce the
final text exactly and must not mark up case or whitespace alone - `TextDiffUtilTests` pins
both, and `docs/style-rewriting.md` says why.

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

## Dictation overlays

A dictation is shown either as the caret-anchored card (`OpenSuperWhisper/Indicator/`) or as the
floating capsule at the top of the screen (`OpenSuperWhisper/CapsuleHUD/`, off by default) - one or
the other, never both, because they are two presentations of the same session.
`IndicatorWindowManager` is the single place that decides, and it reads `capsuleHUDEnabled` **once**
per session into `sessionUsesCapsule`; a preference flipped mid-recording would otherwise leave a
session with two overlays or none. Nothing in `CapsuleHUD/` starts, stops or alters a dictation.

`docs/capsule-hud.md` is the capsule's whole story. Three things there are easy to get wrong and are
pinned by `CapsuleHUDViewModelTests`: an auto-hide belongs to the state that scheduled it (1.5 s is
long enough for the next dictation to start, and a stale hide would close it); `complete()` is
ignored unless a session is in flight, so a cancelled or already-failed dictation cannot end on a
checkmark; and a rewrite is followed only from the session's own decode - `StyleRewriteActivity` is
global, so a queue transcription's rewrite (file drop, open-with) must not hijack a recording
capsule. `DictationResult` exists for the `complete()` rule - the card decodes, hides and says
nothing either way, so nothing before the capsule needed to tell a silent recording from a failed
one - and carries the sentence for a rewrite that kept the original, which the capsule shows as the
badge the checkmark would otherwise paper over.

A HUD panel must not take focus: dictation ends by pasting into whatever app the user was typing in.
Hence `.nonactivatingPanel` plus `canBecomeKey`/`canBecomeMain` false, `ignoresMouseEvents` except
while a cancel button is up, and `constrainFrameRect` returning its argument - AppKit otherwise pulls
the panel down until its transparent shadow margin fits on screen, which lands every placement 16 pt
low.

## Settings, sheets, and shutting down

Settings is a **sheet**, it has **no `TabView`**, and `SettingsSheetLayout` owns what follows.

The tab bar is `SettingsTabBar` (`OpenSuperWhisper/SettingsTabBar.swift`), this app's own control,
because AppKit's was not fixable from outside: a SwiftUI `TabView` in a sheet renders its tabs as one
`NSSegmentedControl`, and on macOS 26 that control drew its selection pill on the selected segment's
rect and its keyboard focus ring about 6 pt wider - on every tab, at 550 pt and again at 680 pt.
Widening the sheet did not settle it and no containment could, since both rects are produced inside
AppKit. The owned bar derives all four - the tab's frame, the selection fill, the focus frame
(`focusRingOutset` outside it) and the hit target - from one frame per tab, so they cannot disagree.
`SettingsTabBarGeometryTests` reads that back out of rendered pixels; it can, because the ring is now
an ordinary overlay rather than something only a key window draws. Do not "simplify" this back to a
`TabView`, and do not reach for `focusEffectDisabled()` without the ring beside it - that removes the
affordance rather than fixing it.

Its width is still set by the tab bar and not by any pane: the bar is one row of titles, so the tab
titles and the sheet's width are a single decision. The 550 pt sheet was set when there were four
tabs and never revisited; by eight it was 122 pt short and every title truncated.
`SettingsTabBarFitTests` lays the bar out headlessly and fails when the titles stop fitting, so
adding a tab or a longer title says so at test time. Tab titles live in `SettingsTab`, which is the
list that test reads.

Only the selected pane is built, and that is a deliberate change: the `TabView` built every tab
whenever Settings opened - the measured fact that kept `CloudSettingsViewModel`'s initialiser off
the Keychain - and only deferred each pane's `onAppear` until it was displayed. That timing is what
carries over, so the `onAppear` refreshes several panes rely on still run when they did; what is new
is that a pane nobody opens (the Cloud one, which reads the Keychain in `onAppear`) is now never
built at all. A pane can no longer resize the bar either, since the bar is its
sibling with a width of its own; the segmented control *was* sized from the whole hosted tree, and at
680 pt a 900 pt pane took it from 648 to 657 and moved every segment as the user changed tabs. What
still contains a pane is `settingsPane()` (`SettingsSheetLayout.swift`), applied to the pane on
screen: `Color.clear` takes the offered width and reports none of its own, so the pane is an overlay
inside it and never speaks for the sheet. `frame(maxWidth:)` and `frame(idealWidth:)` were measured
and do not contain it; `frame(width:)` does but clips real content; the modifier is deliberately
un-clipped so nothing trims a focus frame at a pane's edge.

A visible window-modal sheet also makes AppKit **refuse the quit Apple Event** loginwindow sends, so
an open Settings sheet cancels the user's restart and puts up *"'EchoForge' interrupted restart"*.
`Utils/PowerOffPresentationGuard.swift` is the one owner of that: it reads
`NSWorkspace.willPowerOffNotification` and broadcasts `.dismissModalPresentations`, and
`.dismissesOnPowerOff($binding)` takes each presentation down. Two things there are absolute and
both are measured, not reasoned. **The dismissal must go through the SwiftUI binding** - AppKit's
sheet check runs before `applicationShouldTerminate`, so the delegate is never consulted, and
`NSWindow.endSheet` never touches the state SwiftUI presents from. And **every `.sheet` and
`.confirmationDialog` needs the modifier**, which a source scan in `ModalDismissalOnPowerOffTests`
enforces; `.alert` is exempt because an alert measurably does not block termination while a
confirmation dialog does. The one presentation outside the guard's reach is
`AppStyleMappingSettingsView`'s `NSOpenPanel.runModal()`, which runs its own event loop - transient,
and the user is at the machine while it is up. The guard wins a race rather than proving a rule:
taking a sheet down costs ~270 ms and loginwindow quits apps one at a time, which is seconds.

## Permissions

`OpenSuperWhisper/PermissionsManager.swift` owns the permission state the root view switches on.
`isMissingRequiredPermission` is that switch: microphone and Accessibility only - Input Monitoring
and Screen Recording are conditional on the shortcut being used and must never gate the app, and
Screen Recording is not part of the polled check either (`docs/screen-context.md`). Accessibility is the one grant
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
