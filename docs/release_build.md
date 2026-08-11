## Release build

A release is **thin**: it ships no model weights, and the verifier fails it if any are
packaged ([model-packs.md](model-packs.md) has the measurements and how weights are published
instead). Bundling the starter speech model is opt-in, for an offline install medium: stage it
**before** building and set `ECHOFORGE_BUNDLE_STARTER_MODEL=1` - see
[starter-model.md](starter-model.md).

```shell
Scripts/build_release.sh                              # ad-hoc: what this fork ships
```

That builds whisper.cpp and the autocorrect dylib, signs, packages `EchoForge.dmg` with its
`.sha256`, and then verifies the artifact. It refuses to hand back a package that does not pass.

With a Developer ID certificate and a `notarytool` keychain profile:

```shell
Scripts/build_release.sh --sign-identity "Developer ID Application: AAAA BBBB (XXXXX)" \
                         --notarize-profile <profile>
# or, equivalently:
./notarize_app.sh "Developer ID Application: AAAA BBBB (XXXXX)" <profile>
```

This fork has neither, so its releases are ad-hoc signed and unnotarized;
[install.md](install.md) is what tells users how to get past Gatekeeper.

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
