#!/bin/bash
#
# Builds, signs, packages and verifies a release DMG.
#
# This is the one release build path. It used to be two: `notarize_app.sh` for
# an operator with a Developer ID, and - because this fork has neither a
# certificate nor a notarytool profile - nothing at all for the ad-hoc builds it
# actually ships, which were assembled by hand. v0.3.0 is what that cost: every
# hand-run step was individually correct and the published app could not start
# on any Mac.
#
# Usage:
#   Scripts/build_release.sh                                   # ad-hoc (this fork)
#   Scripts/build_release.sh --sign-identity "Developer ID Application: … (TEAM)" \
#                            --notarize-profile <keychain-profile>
#
# Options:
#   --sign-identity ID        Developer ID to sign with. Default: ad-hoc ("-").
#   --notarize-profile NAME   notarytool keychain profile. Requires --sign-identity.
#   --skip-verify             Do not run Scripts/verify_release_package.sh. Only
#                             for debugging this script; a release must be verified.
#
# ## Signing mode and hardened runtime
#
# The two go together and cannot be chosen independently:
#
#   Developer ID  → hardened runtime ON. It is required for notarization, and
#                   every nested Mach-O gets the same Team ID, so the library
#                   validation it enables is satisfiable.
#   ad-hoc        → hardened runtime OFF. An ad-hoc signature carries no Team ID
#                   and macOS treats each ad-hoc-signed file as its own identity,
#                   so with library validation on, the app is refused its own
#                   embedded dylibs at load time and dies in dyld before `main`.
#                   Hardened runtime buys an unnotarized build nothing anyway.
#
# `Scripts/verify_release_package.sh` re-checks that pairing on the finished
# artifact, so getting it wrong here fails the release rather than the user.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="EchoForge"
readonly SCHEME="OpenSuperWhisper"
readonly DERIVED_DATA="${REPO_ROOT}/build"
readonly APP_PATH="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
readonly DMG_PATH="${REPO_ROOT}/${APP_NAME}.dmg"
readonly DEVELOPMENT_TEAM="8LLDD7HWZK"
readonly HOMEBREW_LIBOMP="/opt/homebrew/opt/libomp/lib/libomp.dylib"

sign_identity="-"
notarize_profile=""
run_verify=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign-identity) sign_identity="$2"; shift 2 ;;
        --notarize-profile) notarize_profile="$2"; shift 2 ;;
        --skip-verify) run_verify=false; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -n "$notarize_profile" && "$sign_identity" == "-" ]]; then
    echo "❌ --notarize-profile needs --sign-identity: Apple will not notarize an ad-hoc build." >&2
    exit 2
fi

if [[ "$sign_identity" == "-" ]]; then
    readonly ADHOC=true
    readonly HARDENED_RUNTIME="NO"
    echo "🔏 Signing ad-hoc (no Developer ID), hardened runtime OFF"
    echo "   The result is unsigned as far as Gatekeeper is concerned; docs/install.md"
    echo "   is what tells users how to open it."
else
    readonly ADHOC=false
    readonly HARDENED_RUNTIME="YES"
    echo "🔏 Signing as '${sign_identity}', hardened runtime ON"
fi

cd "$REPO_ROOT"

# --- Dependencies -------------------------------------------------------------

if [[ ! -f "$HOMEBREW_LIBOMP" ]]; then
    echo "❌ ${HOMEBREW_LIBOMP} not found. Run: brew install libomp" >&2
    exit 1
fi

# The build tools are checked here rather than where they are called, so a
# release machine that is missing one is told at the start instead of part-way
# through a clean build - `cmake: command not found`, three minutes in, names
# nothing you can install.
for tool in cmake:cmake cargo:rust xcodebuild:; do
    if ! command -v "${tool%%:*}" >/dev/null 2>&1; then
        echo -n "❌ ${tool%%:*} not found." >&2
        [[ -n "${tool#*:}" ]] && echo -n " Run: brew install ${tool#*:}" >&2
        echo >&2
        exit 1
    fi
done

if [[ ! -f "${REPO_ROOT}/libwhisper/whisper.cpp/CMakeLists.txt" || ! -f "${REPO_ROOT}/asian-autocorrect/Cargo.toml" ]]; then
    echo "❌ submodules are not checked out. Run: git submodule update --init --recursive" >&2
    exit 1
fi

echo "🧹 Cleaning previous builds..."
rm -rf "$DERIVED_DATA" libwhisper/build
rm -f "$DMG_PATH" "${DMG_PATH}.sha256" "${REPO_ROOT}/${APP_NAME}.app.dSYM.zip"
mkdir -p "$DERIVED_DATA"

echo "⚙️  Configuring libwhisper..."
cmake -G Xcode -B libwhisper/build -S libwhisper >/dev/null

echo "🦀 Building autocorrect-swift..."
CARGO_PROFILE_RELEASE_LTO=true \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
CARGO_PROFILE_RELEASE_STRIP=symbols \
CARGO_PROFILE_RELEASE_PANIC=abort \
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin \
    --manifest-path=asian-autocorrect/Cargo.toml

# Both dylibs are staged into the derived-data root, which is where the Xcode
# project's Copy Files phase picks them up (with CodeSignOnCopy, so Xcode
# re-signs them with the app's identity and options - that phase, not this
# signing, is what ends up in the bundle).
stage_dylib() {
    local source="$1" destination="${DERIVED_DATA}/$2"
    cp "$source" "$destination"
    install_name_tool -id "@rpath/$2" "$destination"
    if [[ "$ADHOC" == true ]]; then
        codesign --force --sign - "$destination"
    else
        codesign --force --sign "$sign_identity" --timestamp "$destination"
    fi
}

stage_dylib "asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib" \
    "libautocorrect_swift.dylib"
echo "📦 Staging libomp.dylib..."
stage_dylib "$HOMEBREW_LIBOMP" "libomp.dylib"

# --- Build --------------------------------------------------------------------

echo "🔨 Building ${APP_NAME}..."
xcodebuild_args=(
    -scheme "$SCHEME"
    -configuration Release
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA"
    -skipPackagePluginValidation
    -skipMacroValidation
    -clonedSourcePackagesDirPath "${REPO_ROOT}/SourcePackages"
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=${sign_identity}"
    "ENABLE_HARDENED_RUNTIME=${HARDENED_RUNTIME}"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
)
if [[ "$ADHOC" == true ]]; then
    # An ad-hoc signature has no team; leaving the project's team set would make
    # Xcode look for a provisioning profile that does not exist here.
    xcodebuild_args+=(DEVELOPMENT_TEAM="" "PROVISIONING_PROFILE_SPECIFIER=")
else
    xcodebuild_args+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

if command -v xcpretty >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${xcodebuild_args[@]}" build | xcpretty --simple --color
else
    xcodebuild "${xcodebuild_args[@]}" build
fi

[[ -d "$APP_PATH" ]] || { echo "❌ no app at ${APP_PATH}" >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist")"
echo "✅ Built ${APP_NAME} ${version} (build ${build_number})"

# --- Notarize (Developer ID only) --------------------------------------------

if [[ -n "$notarize_profile" ]]; then
    echo "📤 Notarizing..."
    zip_path="${DERIVED_DATA}/${APP_NAME}.zip"
    rm -f "$zip_path"
    (cd "$(dirname "$APP_PATH")" && zip -qr -y "$zip_path" "$(basename "$APP_PATH")")
    xcrun notarytool submit "$zip_path" --wait --keychain-profile "$notarize_profile"
    xcrun stapler staple "$APP_PATH"
else
    echo "ℹ️  Not notarized (no --notarize-profile)."
fi

# --- Package ------------------------------------------------------------------
#
# hdiutil rather than a third-party DMG tool: the release has to be buildable on
# a machine with nothing installed beyond Xcode and Homebrew, and the previous
# script depended on `swifty-dmg`, which is not installed on the machine that
# cut v0.3.0 - so the DMG was made by hand instead.

echo "💿 Building ${APP_NAME}.dmg..."
staging="$(mktemp -d "${TMPDIR:-/tmp}/echoforge-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$APP_PATH" "${staging}/${APP_NAME}.app"
ln -s /Applications "${staging}/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO -quiet "$DMG_PATH"

if [[ "$ADHOC" == false ]]; then
    codesign --force --sign "$sign_identity" --timestamp "$DMG_PATH"
    if [[ -n "$notarize_profile" ]]; then
        xcrun notarytool submit "$DMG_PATH" --wait --keychain-profile "$notarize_profile"
        xcrun stapler staple "$DMG_PATH"
    fi
fi

# Named relative to the DMG's own directory. The .sha256 is published beside the
# DMG as a release asset, so `shasum -a 256 -c EchoForge.dmg.sha256` has to work
# in the folder a user downloaded it into - not at the absolute path of whatever
# machine built it.
(cd "$(dirname "$DMG_PATH")" && shasum -a 256 "$(basename "$DMG_PATH")") > "${DMG_PATH}.sha256"

# --- Verify -------------------------------------------------------------------

if [[ "$run_verify" == true ]]; then
    echo
    "${REPO_ROOT}/Scripts/verify_release_package.sh" --expect-version "$version" "$DMG_PATH"
else
    echo "⚠️  Skipped verification (--skip-verify). Do not publish this artifact."
fi

echo
echo "📁 ${DMG_PATH}"
echo "   $(cat "${DMG_PATH}.sha256")"
