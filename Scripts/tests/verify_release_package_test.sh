#!/bin/bash
#
# Tests Scripts/verify_release_package.sh against app bundles built to be
# broken in the exact ways a release can be broken.
#
# The fixtures are synthesised with clang rather than taken from a build of
# EchoForge, so this runs in seconds, needs no models or submodules, and - the
# reason it exists - can reproduce the v0.3.0 defect from first principles: an
# ad-hoc signature plus hardened runtime plus an embedded dylib is a bundle that
# cannot start, no matter whose code is in it. Case 1 asserts both that the
# fixture really does die in dyld and that the verifier rejects it, so the check
# cannot drift into a heuristic that merely looks right.
#
# Usage: Scripts/tests/verify_release_package_test.sh

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly VERIFIER="${REPO_ROOT}/Scripts/verify_release_package.sh"
readonly BUNDLE_ID="com.example.EchoForgeVerifierFixture"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/echoforge-verifier-test.XXXXXX")"
work_dir="${work_dir%/}"
trap 'rm -rf "$work_dir"' EXIT

failures=0
ok() { printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; failures=$((failures + 1)); }

# --- Fixture ------------------------------------------------------------------

cat > "${work_dir}/lib.c" <<'EOF'
int fixture_answer(void) { return 42; }
EOF

# Mirrors LaunchDiagnostics: report the mapped images that live inside the
# bundle, then exit. The verifier cross-checks that list against the Mach-O
# files it found on disk.
cat > "${work_dir}/main.c" <<'EOF'
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int fixture_answer(void);

int main(void) {
    // Without the variable it does nothing at all, so a fixture that *can*
    // start says so by producing no output rather than by hanging.
    if (getenv("ECHOFORGE_LAUNCH_CHECK") == NULL) { return 0; }

    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) { return 1; }

    // .../Fixture.app/Contents/MacOS/Fixture -> .../Fixture.app/
    // realpath first, for the same reason LaunchDiagnostics canonicalises:
    // dyld reports whatever path the process was launched with, doubled slashes
    // and /var symlinks and all, while the image names are normalised.
    char root[4096];
    if (realpath(executable, root) == NULL) { return 1; }
    for (int i = 0; i < 3; i++) {
        char *slash = strrchr(root, '/');
        if (slash == NULL) { return 1; }
        *slash = '\0';
    }
    size_t root_length = strlen(root);

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        char resolved[4096];
        if (name == NULL || realpath(name, resolved) == NULL) { continue; }
        if (strncmp(resolved, root, root_length) == 0 && resolved[root_length] == '/') {
            printf("loaded: %s\n", resolved + root_length + 1);
        }
    }
    printf("answer: %d\n", fixture_answer());
    printf("ECHOFORGE_LAUNCH_CHECK: ok\n");
    return 0;
}
EOF

# Builds a fresh fixture bundle. $1 is a name, $2 is "runtime" or "no-runtime".
make_fixture() {
    local name="$1" runtime="$2"
    local app="${work_dir}/${name}/Fixture.app"

    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Frameworks"
    cat > "${app}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Fixture</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>Fixture</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
EOF

    clang -dynamiclib -o "${app}/Contents/Frameworks/libfixture.dylib" \
        -install_name "@rpath/libfixture.dylib" "${work_dir}/lib.c" || return 1
    clang -o "${app}/Contents/MacOS/Fixture" "${work_dir}/main.c" \
        -rpath "@executable_path/../Frameworks" \
        "${app}/Contents/Frameworks/libfixture.dylib" || return 1

    local options=()
    [[ "$runtime" == "runtime" ]] && options=(--options runtime)

    # Inside-out, the way any correct signing pass goes.
    codesign --force --sign - ${options[@]+"${options[@]}"} \
        "${app}/Contents/Frameworks/libfixture.dylib" 2>/dev/null || return 1
    codesign --force --sign - ${options[@]+"${options[@]}"} "$app" 2>/dev/null || return 1

    echo "$app"
}

verify() {
    "$VERIFIER" --expect-bundle-id "$BUNDLE_ID" "$1" 2>&1
}

# --- 1. Hardened runtime + ad-hoc: the v0.3.0 defect ---------------------------

echo "[1] hardened runtime + ad-hoc signature (the v0.3.0 defect)"
broken="$(make_fixture broken runtime)"
if [[ -z "$broken" ]]; then
    bad "could not build the fixture"
else
    launch_output="$("${broken}/Contents/MacOS/Fixture" 2>&1)"
    if [[ "$launch_output" == *"different Team IDs"* ]]; then
        ok "the fixture really is unlaunchable, for the reason v0.3.0 was"
    else
        bad "expected a Team ID load failure, got: ${launch_output}"
    fi

    output="$(verify "$broken")"
    if [[ $? -eq 0 ]]; then
        bad "the verifier passed a bundle that cannot start"
    elif [[ "$output" == *"hardened runtime + ad-hoc signature"* ]]; then
        ok "the verifier rejects it and names the cause"
    else
        bad "the verifier rejected it for the wrong reason:"
        echo "$output" | sed 's/^/      /'
    fi
fi

# --- 2. The same bundle signed correctly for this fork -------------------------

echo "[2] ad-hoc signature, no hardened runtime"
good="$(make_fixture good no-runtime)"
if [[ -z "$good" ]]; then
    bad "could not build the fixture"
else
    output="$(verify "$good")"
    if [[ $? -eq 0 ]]; then
        ok "the verifier passes it"
    else
        bad "the verifier rejected a working bundle:"
        echo "$output" | sed 's/^/      /'
    fi
fi

# --- 3. A missing embedded dylib ----------------------------------------------

echo "[3] embedded dylib missing from the bundle"
missing="$(make_fixture missing no-runtime)"
if [[ -z "$missing" ]]; then
    bad "could not build the fixture"
else
    rm -f "${missing}/Contents/Frameworks/libfixture.dylib"
    output="$(verify "$missing")"
    if [[ $? -eq 0 ]]; then
        bad "the verifier passed a bundle missing a dylib it loads"
    elif [[ "$output" == *"resolves to nothing on its rpath"* ]]; then
        ok "the verifier reports the unresolvable @rpath dependency"
    else
        bad "the verifier rejected it for the wrong reason:"
        echo "$output" | sed 's/^/      /'
    fi
fi

# --- 4. An unsigned embedded dylib --------------------------------------------

echo "[4] embedded dylib left unsigned"
unsigned="$(make_fixture unsigned no-runtime)"
if [[ -z "$unsigned" ]]; then
    bad "could not build the fixture"
else
    codesign --remove-signature "${unsigned}/Contents/Frameworks/libfixture.dylib" 2>/dev/null
    output="$(verify "$unsigned")"
    if [[ $? -eq 0 ]]; then
        bad "the verifier passed a bundle with unsigned nested code"
    elif [[ "$output" == *"not validly signed"* ]]; then
        ok "the verifier reports the unsigned dylib"
    else
        bad "the verifier rejected it for the wrong reason:"
        echo "$output" | sed 's/^/      /'
    fi
fi

# --- Result -------------------------------------------------------------------

echo
if [[ $failures -eq 0 ]]; then
    echo "✅ verify_release_package.sh behaves as specified."
    exit 0
fi
echo "❌ ${failures} assertion(s) failed."
exit 1
