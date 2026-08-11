#!/bin/bash
#
# Proves a packaged build can actually run before it is published.
#
# v0.3.0 shipped a bundle whose every piece was signed, whose
# `codesign --verify --deep --strict` passed, and which could not start on any
# Mac: dyld refused `@rpath/libomp.dylib` with "mapping process and mapped file
# (non-platform) have different Team IDs". Hardened runtime turns on library
# validation; this fork has no Developer ID so it signs ad-hoc; and two
# independently ad-hoc-signed Mach-O files never share a Team ID, because an
# ad-hoc signature has none and macOS will not treat two of them as one
# identity. Signature *validity* therefore says nothing about loadability, which
# is why the release scripts call this instead of trusting `codesign --verify`.
#
# Usage:
#   Scripts/verify_release_package.sh <EchoForge.app|EchoForge.dmg>
#
# Options:
#   --expect-bundle-id ID     default com.hsuanchenlin.EchoForge
#   --expect-version V        marketing version the bundle must report
#   --require-starter-model   fail unless the SenseVoice starter weights are packaged
#   --forbid-starter-model    fail *if* they are packaged, which is what an
#                             ordinary release wants: the weights live in
#                             Application Support and survive an app
#                             replacement, so shipping them makes every update
#                             twenty times bigger for nothing
#   --no-launch               skip the launch check (static checks only)
#
# The release scripts run it automatically; run it by hand on any downloaded
# .dmg to tell a broken package from a broken installation.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kept in step with `LaunchDiagnostics.environmentKey` / `.successMarker`.
readonly LAUNCH_CHECK_ENV="ECHOFORGE_LAUNCH_CHECK"
readonly LAUNCH_CHECK_MARKER="ECHOFORGE_LAUNCH_CHECK: ok"
readonly LAUNCH_CHECK_TIMEOUT_SECONDS=60

# Same folder name `Scripts/package_starter_model.sh` writes.
readonly STARTER_MODEL_RELATIVE_PATH="Contents/Resources/StarterModel/sensevoice-small"

expect_bundle_id="com.hsuanchenlin.EchoForge"
expect_version=""
require_starter_model=false
forbid_starter_model=false
run_launch_check=true
artifact=""

failures=0
checks=0

fail() { printf '  ✗ %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf '  ✓ %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
section() { checks=$((checks + 1)); printf '\n[%d] %s\n' "$checks" "$*"; }

usage() {
    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'
    exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-bundle-id) expect_bundle_id="$2"; shift 2 ;;
        --expect-version) expect_version="$2"; shift 2 ;;
        --require-starter-model) require_starter_model=true; shift ;;
        --forbid-starter-model) forbid_starter_model=true; shift ;;
        --no-launch) run_launch_check=false; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage 2 ;;
        *) artifact="$1"; shift ;;
    esac
done

[[ -n "$artifact" ]] || usage 2
[[ -e "$artifact" ]] || { echo "no such artifact: $artifact" >&2; exit 2; }

# --- Resolve the bundle -------------------------------------------------------
#
# A .dmg is mounted read-only and the app copied out, because the launch check
# has to run the binary from a normal writable location - and because verifying
# the mounted image is the only way to check what a user actually downloads.

# ${TMPDIR%/} because TMPDIR ends in a slash on macOS and the doubled
# separator would survive into every path printed below.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/echoforge-verify.XXXXXX")"
work_dir="${work_dir%/}"
mount_point=""

cleanup() {
    [[ -n "$mount_point" ]] && hdiutil detach "$mount_point" -quiet 2>/dev/null
    rm -rf "$work_dir"
}
trap cleanup EXIT

app=""
case "$artifact" in
    *.dmg)
        mount_point="${work_dir}/mnt"
        mkdir -p "$mount_point"
        if ! hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$artifact" >/dev/null; then
            echo "could not mount $artifact" >&2
            exit 2
        fi
        mounted_app="$(find "$mount_point" -maxdepth 1 -name '*.app' -print -quit)"
        if [[ -z "$mounted_app" ]]; then
            echo "no .app at the top level of $artifact" >&2
            exit 2
        fi
        app="${work_dir}/$(basename "$mounted_app")"
        # ditto, not cp: it is the only copy that preserves the signature's
        # extended attributes, and a mangled copy would fail for the wrong reason.
        ditto "$mounted_app" "$app"
        ;;
    *.app)
        app="${work_dir}/$(basename "$artifact")"
        ditto "$artifact" "$app"
        ;;
    *)
        echo "expected a .app or a .dmg, got: $artifact" >&2
        exit 2
        ;;
esac

# PlistBuddy rather than `defaults`, which caches by domain and would happily
# answer from another copy of the same bundle identifier.
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "${app}/Contents/Info.plist" 2>/dev/null
}

executable_name="$(plist_value "$app" CFBundleExecutable)"
main_executable="${app}/Contents/MacOS/${executable_name}"

echo "Verifying $(basename "$artifact")"
echo "  bundle: $(basename "$app")"

# --- 1. Identity --------------------------------------------------------------

section "Bundle identity"
bundle_id="$(plist_value "$app" CFBundleIdentifier)"
short_version="$(plist_value "$app" CFBundleShortVersionString)"
build_version="$(plist_value "$app" CFBundleVersion)"

if [[ "$bundle_id" == "$expect_bundle_id" ]]; then
    pass "bundle identifier ${bundle_id}"
else
    # Load-bearing user data lives under this identifier; see AGENTS.md.
    fail "bundle identifier is '${bundle_id}', expected '${expect_bundle_id}'"
fi

if [[ -x "$main_executable" ]]; then
    pass "executable Contents/MacOS/${executable_name}"
else
    fail "no executable at Contents/MacOS/${executable_name}"
fi

if [[ -n "$expect_version" ]]; then
    if [[ "$short_version" == "$expect_version" ]]; then
        pass "version ${short_version} (build ${build_version})"
    else
        fail "version is ${short_version}, expected ${expect_version}"
    fi
else
    pass "version ${short_version} (build ${build_version})"
fi

# --- 2. Every Mach-O is signed, and signed the same way ------------------------

section "Nested code signatures"

# Everything the loader could map, not just Contents/Frameworks: a helper tool,
# a plug-in bundle or an XPC service added later has exactly the same failure
# mode, and patching only the first library that happened to be reported is how
# this defect survives a fix.
mach_o_files=()
while IFS= read -r candidate; do
    if file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'; then
        mach_o_files+=("$candidate")
    fi
done < <(find "$app" -type f)

if [[ ${#mach_o_files[@]} -eq 0 ]]; then
    fail "found no Mach-O files at all"
fi

# `codesign -dvvv` writes to stderr.
signing_field() {
    codesign -dvvv "$1" 2>&1 | awk -F= -v key="$2" '$1 == key { print $2; exit }'
}

code_directory_flags() {
    codesign -dvvv "$1" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p'
}

main_team_id="$(signing_field "$main_executable" TeamIdentifier)"
main_flags="$(code_directory_flags "$main_executable")"

for binary in ${mach_o_files[@]+"${mach_o_files[@]}"}; do
    relative="${binary#"${app}/"}"

    if ! codesign --verify --strict "$binary" 2>/dev/null; then
        fail "${relative}: not validly signed"
        continue
    fi

    team_id="$(signing_field "$binary" TeamIdentifier)"
    if [[ "$team_id" != "$main_team_id" ]]; then
        # The exact condition AMFI rejects at load time.
        fail "${relative}: Team ID '${team_id}' differs from the app's '${main_team_id}'"
        continue
    fi

    flags="$(code_directory_flags "$binary")"
    if [[ "$flags" != "$main_flags" ]]; then
        fail "${relative}: CodeDirectory flags ${flags} differ from the app's ${main_flags}"
        continue
    fi

    pass "${relative} (${flags:-none}, team ${team_id})"
done

# --- 3. Hardened runtime and ad-hoc signing cannot be combined ----------------

section "Library validation"

embedded_code_count=$((${#mach_o_files[@]} - 1))
has_hardened_runtime=false
[[ "$main_flags" == *runtime* ]] && has_hardened_runtime=true
is_adhoc=false
[[ "$main_flags" == *adhoc* ]] && is_adhoc=true
disables_library_validation=false
if codesign -d --entitlements - --xml "$app" 2>/dev/null |
        plutil -convert xml1 -o - - 2>/dev/null |
        grep -q 'com.apple.security.cs.disable-library-validation'; then
    disables_library_validation=true
fi

if [[ "$has_hardened_runtime" == true && "$is_adhoc" == true &&
      "$disables_library_validation" == false && $embedded_code_count -gt 0 ]]; then
    fail "hardened runtime + ad-hoc signature + ${embedded_code_count} embedded librar$([[ $embedded_code_count == 1 ]] && echo y || echo ies)"
    note "Hardened runtime enables library validation, which requires every loaded"
    note "library to carry the process's Team ID. An ad-hoc signature has no Team ID,"
    note "so no embedded library can ever satisfy it and the app cannot start."
    note "Build ad-hoc releases with ENABLE_HARDENED_RUNTIME=NO (Scripts/build_release.sh),"
    note "or sign with a Developer ID so everything shares one Team ID."
else
    if [[ "$has_hardened_runtime" == true ]]; then
        pass "hardened runtime with a Team ID identity - library validation can be satisfied"
    else
        pass "no hardened runtime - library validation is not enforced"
    fi
fi

# --- 4. Every @rpath dependency resolves inside the bundle --------------------

section "Runtime library search paths"

rpaths_of() {
    otool -l "$1" | awk '/LC_RPATH/ { rpath = 1 } rpath && $1 == "path" { print $2; rpath = 0 }'
}

# Load commands, not `otool -L`: a dylib's own install name is `@rpath/…` too
# and appears first in `otool -L` output, so that would have every embedded
# library reported as depending on itself.
rpath_dependencies_of() {
    otool -l "$1" | awk '
        $1 == "cmd" { command = $2 }
        $1 == "name" && $2 ~ /^@rpath\// &&
            (command == "LC_LOAD_DYLIB" || command == "LC_LOAD_WEAK_DYLIB" ||
             command == "LC_REEXPORT_DYLIB") { print $2 }
    '
}

for binary in ${mach_o_files[@]+"${mach_o_files[@]}"}; do
    relative="${binary#"${app}/"}"
    binary_dir="$(dirname "$binary")"

    # `mapfile` would be clearer; macOS ships bash 3.2, which does not have it.
    rpaths=()
    while IFS= read -r rpath_entry; do
        [[ -n "$rpath_entry" ]] && rpaths+=("$rpath_entry")
    done < <(rpaths_of "$binary")

    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        leaf="${dependency#@rpath/}"
        resolved=""
        for rpath in ${rpaths[@]+"${rpaths[@]}"}; do
            expanded="${rpath//@executable_path/${app}/Contents/MacOS}"
            expanded="${expanded//@loader_path/${binary_dir}}"
            if [[ -e "${expanded}/${leaf}" ]]; then
                resolved="${expanded}/${leaf}"
                break
            fi
        done

        if [[ -z "$resolved" ]]; then
            fail "${relative}: ${dependency} resolves to nothing on its rpath"
            note "rpaths: ${rpaths[*]+${rpaths[*]}}"
        elif [[ "$resolved" != "${app}/"* ]]; then
            # A dependency satisfied from /opt/homebrew works on the machine
            # that built it and on no user's Mac.
            fail "${relative}: ${dependency} resolves outside the bundle (${resolved})"
        else
            # Collapse the "MacOS/../Frameworks" the rpath expansion leaves behind.
            display="$(printf '%s' "${resolved#"${app}/"}" | sed -E -e ':a' -e 's#[^/]+/\.\./##g' -e 'ta')"
            pass "${relative}: ${dependency} → ${display}"
        fi
    done < <(rpath_dependencies_of "$binary")
done

# --- 5. The seal over the whole bundle ---------------------------------------

section "Bundle seal"
if verify_output="$(codesign --verify --deep --strict "$app" 2>&1)"; then
    pass "codesign --verify --deep --strict"
else
    fail "codesign --verify --deep --strict"
    while IFS= read -r line; do note "$line"; done <<< "$verify_output"
fi

# --- 6. Packaged starter model ------------------------------------------------

section "Starter model"
if [[ -d "${app}/${STARTER_MODEL_RELATIVE_PATH}" ]]; then
    missing=()
    for entry in SenseVoicePreprocessor.mlmodelc SenseVoiceSmall_int8.mlmodelc vocab.json; do
        [[ -e "${app}/${STARTER_MODEL_RELATIVE_PATH}/${entry}" ]] || missing+=("$entry")
    done
    if [[ "$forbid_starter_model" == true ]]; then
        fail "packaged, and --forbid-starter-model was given ($(du -sh "${app}/${STARTER_MODEL_RELATIVE_PATH}" | cut -f1 | tr -d ' '))"
    elif [[ ${#missing[@]} -eq 0 ]]; then
        pass "packaged ($(du -sh "${app}/${STARTER_MODEL_RELATIVE_PATH}" | cut -f1 | tr -d ' '))"
    else
        fail "packaged but incomplete; missing: ${missing[*]}"
    fi
elif [[ "$require_starter_model" == true ]]; then
    fail "not packaged, and --require-starter-model was given"
else
    pass "not packaged - the app installs a model pack or downloads one on first run"
fi

# --- 7. Launch ----------------------------------------------------------------
#
# The only check that would have caught v0.3.0 on its own. `LaunchDiagnostics`
# makes it safe to run against a build about to be published: the process exits
# before the app touches the operator's preferences, model cache or database.

section "Launch"
if [[ "$run_launch_check" == false ]]; then
    pass "skipped (--no-launch)"
elif [[ ! -x "$main_executable" ]]; then
    fail "skipped - no executable to run"
else
    launch_log="${work_dir}/launch.log"
    env "${LAUNCH_CHECK_ENV}=1" "$main_executable" >"$launch_log" 2>&1 &
    launch_pid=$!

    waited=0
    while kill -0 "$launch_pid" 2>/dev/null && [[ $waited -lt $LAUNCH_CHECK_TIMEOUT_SECONDS ]]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$launch_pid" 2>/dev/null; then
        kill -9 "$launch_pid" 2>/dev/null
        wait "$launch_pid" 2>/dev/null
        fail "the app did not exit within ${LAUNCH_CHECK_TIMEOUT_SECONDS}s under ${LAUNCH_CHECK_ENV}=1"
        note "A build that predates the launch-check hook cannot be verified this way;"
        note "re-run with --no-launch if that is what this is."
    else
        # 2>/dev/null: a build that dies in dyld is killed by a signal, and the
        # shell's own "Abort trap: 6" line would land in the middle of the report.
        wait "$launch_pid" 2>/dev/null
        launch_status=$?
        if [[ $launch_status -ne 0 ]]; then
            fail "the app failed to start (exit ${launch_status})"
            while IFS= read -r line; do note "$line"; done < "$launch_log"
        elif ! grep -qF "$LAUNCH_CHECK_MARKER" "$launch_log"; then
            fail "the app started but did not report a launch check"
            while IFS= read -r line; do note "$line"; done < "$launch_log"
        else
            pass "started and exited cleanly"
            while IFS= read -r line; do
                [[ "$line" == loaded:* ]] && note "$line"
            done < "$launch_log"

            # Every embedded Mach-O has to appear in the report, or something in
            # the bundle is dead weight the loader never mapped.
            for binary in ${mach_o_files[@]+"${mach_o_files[@]}"}; do
                relative="${binary#"${app}/"}"
                if ! grep -qF "loaded: ${relative}" "$launch_log"; then
                    fail "${relative} is embedded but was not mapped at launch"
                fi
            done
        fi
    fi
fi

# --- Result -------------------------------------------------------------------

echo
if [[ $failures -eq 0 ]]; then
    echo "✅ $(basename "$artifact") is publishable."
    exit 0
fi
echo "❌ $(basename "$artifact") has ${failures} problem(s); do not publish it."
exit 1
