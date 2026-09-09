## Release build

A release is **thin**: it ships no model weights, and the verifier fails it if any are
packaged ([model-packs.md](model-packs.md) has the measurements and how weights are published
instead). Bundling the starter speech model is opt-in, for an offline install medium: stage it
**before** building and set `ECHOFORGE_BUNDLE_STARTER_MODEL=1` - see
[starter-model.md](starter-model.md). `--offline-only` builds the variant with no cloud path
compiled in at all - [cloud-api.md](cloud-api.md) says what it removes and why.

```shell
Scripts/build_release.sh                              # ad-hoc: what this fork ships
```

That builds whisper.cpp and the autocorrect dylib, signs, packages `EchoForge.dmg` with its
`.sha256`, and then verifies the artifact. It refuses to hand back a package that does not pass.

**The build is not reproducible, so publish the pair.** Two runs over the same tree produce
different disk images - measured at 10,726,671 and 10,729,198 bytes for v0.6.0, with different
digests - so `EchoForge.dmg` and the `EchoForge.dmg.sha256` written beside it are one artifact.
Upload both from the same run, and never re-run the build between hashing and uploading: the
updater fails an install whose sidecar does not match (`UpdateManifest.checksumURL`), so a
mismatched pair is a release nobody can install.

With a Developer ID certificate and a `notarytool` keychain profile:

```shell
Scripts/build_release.sh --sign-identity "Developer ID Application: AAAA BBBB (XXXXX)" \
                         --notarize-profile <profile>
# or, equivalently:
./notarize_app.sh "Developer ID Application: AAAA BBBB (XXXXX)" <profile>
```

This fork has neither, so its releases are ad-hoc signed and unnotarized;
[install.md](install.md) is what tells users how to get past Gatekeeper.

### What is still missing, exactly

Unsigned distribution is the single largest product problem this app has: every
install and every update puts a macOS warning in front of the user, the
workarounds in [install.md](install.md) exist only because of it, and a
replacement bundle with a different signature can cost the user their TCC grants.
Nothing in the code can fix it. What is missing is **one credential**, and the
steps that follow from having it are already written above and already
implemented in `Scripts/build_release.sh`.

**The credential.** An Apple Developer Program membership (individual or
organization), from which two things are derived:

1. A **Developer ID Application** certificate, created in Xcode
   (Settings → Accounts → Manage Certificates → +) or on the developer portal,
   and present in the login keychain of whatever machine runs the release build.
   `security find-identity -v -p codesigning` is how to confirm it is there; the
   string it prints, `Developer ID Application: NAME (TEAMID)`, is what
   `--sign-identity` takes.
2. A **`notarytool` keychain profile**, stored once with
   `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
   --password <app-specific-password>`. The password is an app-specific password
   from appleid.apple.com, not the account password. `<profile>` is what
   `--notarize-profile` takes.

**Then the release is the command already documented above**, and three things
follow from it automatically because they are already implemented:

- Hardened runtime turns **on**, because the signing mode decides it - see the
  table below. Nothing about that switch may be set by hand.
- `Scripts/verify_release_package.sh` still runs, and still refuses to hand back
  a package that fails. It checks that every nested Mach-O carries the app's own
  Team ID and that hardened runtime and ad-hoc signing are never combined - which
  is exactly the pair that shipped an unopenable v0.3.0 - and it **starts the
  app** (`ECHOFORGE_LAUNCH_CHECK=1`). None of that weakens for a signed build; it
  gets stricter, because a Developer ID build has a Team ID to check against.
- `notarize_app.sh` staples the ticket, so the DMG works on a Mac that is offline
  the first time it is opened.

**What has to be checked by hand on the first signed release**, because no test
can reach it:

- A **clean Mac** - or a fresh user account - installs and opens the DMG with no
  Gatekeeper dialog at all.
- `spctl -a -vvv -t install EchoForge.dmg` and `spctl -a -vvv /Applications/EchoForge.app`
  both accept, and `xcrun stapler validate` passes on both.
- The **in-app updater** replaces a signed build with a signed build:
  `DownloadedBuildRequirements` and the `codesign --verify --deep --strict` check
  in `UpdateInstaller` are unchanged by signing, but the swap has never been run
  against a notarized bundle.
- **TCC grants survive the update.** This is the reason to do it at all: microphone
  and Accessibility are keyed on code identity, so the first signed release will
  itself re-prompt every existing ad-hoc user once, and every release after it
  must not.

Until that credential exists, [install.md](install.md) stays the single home for
the Gatekeeper workarounds and the README must not grow a second copy of them.

### Signing mode decides hardened runtime

They are not independent settings, and getting this wrong is what shipped an unopenable
v0.3.0:

| Signing | Hardened runtime | Why |
| --- | --- | --- |
| Developer ID | **on** | Required for notarization, and every nested Mach-O carries the same Team ID, so the library validation it enables is satisfiable. |
| ad-hoc (`-`) | **off** | An ad-hoc signature has no Team ID and macOS treats each ad-hoc-signed file as its own identity. With library validation on, the app is refused *its own* embedded dylibs and dies in dyld before `main`. |

`Scripts/build_release.sh` picks this from the signing mode; the project's
`ENABLE_HARDENED_RUNTIME = YES` is the Developer ID default and is overridden for ad-hoc
builds.

### Verifying a package

```shell
Scripts/verify_release_package.sh EchoForge.dmg      # or a .app
```

Checks bundle identity and version, that every Mach-O in the bundle is validly signed with
the app's own Team ID and options, that hardened runtime and ad-hoc signing are not
combined, that every `@rpath` dependency resolves *inside* the bundle, the whole-bundle
seal, that the starter model is packaged or absent as asked (`--require-starter-model` /
`--forbid-starter-model`; `build_release.sh` passes whichever matches how it built) - and
then **starts the app**.

The launch check is the one that matters. v0.3.0 passed `codesign --verify --deep --strict`
on the published DMG and could not start on any Mac; a signature says nothing about whether
the loader will accept it. `ECHOFORGE_LAUNCH_CHECK=1` makes the app report which of its own
libraries dyld mapped and exit before it touches any of the operator's data
(`LaunchDiagnostics`), so this is safe to run against a build you are about to publish.

`Scripts/tests/verify_release_package_test.sh` tests the verifier itself against synthesised
bundles broken in each of those ways, including v0.3.0's defect; `ReleasePackagingTests`
runs it as part of the normal test suite.
