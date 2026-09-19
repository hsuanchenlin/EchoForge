# App identity: three names, and which one is authoritative for what

The product, the release artefacts and the code carry three different names. Do not collapse
them - each split exists for a reason and each reason still holds.

| Name | Role | Where it lives |
| --- | --- | --- |
| **Kongweh** | The product - the only name a user sees. Taiwanese *kóng-uē* (講話), "to talk". | `CFBundleDisplayName`, `CFBundleName`, the permission strings, every string in the UI and in user-facing docs. |
| **EchoForge** | The release and storage identity. | `com.hsuanchenlin.EchoForge`, `PRODUCT_NAME` (so `EchoForge.app` and `EchoForge.dmg`), the GitHub repository, `~/Library/Application Support/com.hsuanchenlin.EchoForge/`. |
| **OpenSuperWhisper** | The code identity. | The Xcode project, targets, scheme, source directories and the Swift module (`PRODUCT_MODULE_NAME`, what `@testable import OpenSuperWhisper` binds to, and what `-only-testing:` arguments name). |

## Why the split holds

The code keeps upstream's paths so merges from `Starmel/OpenSuperWhisper` stay clean.

The release and storage identity was left at EchoForge through the Kongweh rename because it
names the folder holding every existing user's recordings, personal terms and downloaded
models, their Keychain item and their TCC grants, and because `UpdateManifest.assetName` and
`UpdateInstaller` find an update by those exact file names. Moving it is a migration, not a
rename, and it would hand every existing user an empty app. The EchoForge rename did exactly
that once, on purpose (it is what lets an upstream install stay), and
[install.md](install.md) tells users what they lose and how to copy it across. Do not change
it again.

`OpenSuperWhisperTests/AppIdentityTests.swift` pins both halves of that boundary, including
that the data paths still resolve under the old identity.

Renaming reached the product, not the models or the upstream credit: engine and model names
are constrained by their licences (see
[speech-model-attribution.md](speech-model-attribution.md)), and the README and LICENSE keep
upstream's attribution.

## The Info.plist is hand-written

`GENERATE_INFOPLIST_FILE` is **off** for the app target. Xcode's generated plist hard-codes
`CFBundleName` to `$(PRODUCT_NAME)` and no `INFOPLIST_KEY_` overrides it, so with generation
on the app menu said EchoForge while Finder said Kongweh. The keys generation used to supply
are written out in `OpenSuperWhisper/OpenSuperWhisper-Info.plist` instead, several as
`$(BUILD_SETTING)` so `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` still reach the
bundle the way `ReleaseVersionTests` expects.

## The app icon is generated

`Scripts/GenerateAppIcon.swift` is the vector source and `Scripts/generate_app_icon.sh`
renders `OpenSuperWhisper/AppIcon.icns` from it. The `.icns` is committed, so builds never
run the script - which means editing the artwork without re-running the script ships the old
icon, and `AppIconArtworkTests` exists to catch exactly that: it reads the committed `.icns`
rather than the source. `CFBundleIconFile` in the Info.plist is what loads it; there is no
`AppIcon.appiconset`.

The mark is "Speech Ripple" and the file's own header states what may not drift - it is
symmetric, it has no microphone, and its palette is ink, white and cyan with nothing warm in
it, because it replaced a bronze-and-ember "Forge Ribbon" direction that was dropped along
with the EchoForge name. `AppIconArtworkTests` asserts that at the pixel level.

The menu-bar icons use the same mark and are generated from `Scripts/GenerateTrayIcon.swift`;
[menu-bar.md](menu-bar.md) owns the artwork and state contracts.
