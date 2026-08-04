#!/bin/bash
#
# Builds, signs, notarizes and packages a release with a Developer ID.
#
# Kept as the name upstream and the release notes use; the work is done by
# `Scripts/build_release.sh`, which is also what the ad-hoc path this fork
# actually ships uses. Having one script for both is the point: the two paths
# differing in an unwritten-down way is what broke v0.3.0.
#
# Usage:
#   ./notarize_app.sh "Developer ID Application: Your Name (TEAMID)" [keychain-profile]
#
# This fork has neither a Developer ID certificate nor a notarytool profile, so
# this script cannot run here - use `Scripts/build_release.sh` with no arguments
# for the ad-hoc build, and see docs/release_build.md.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODE_SIGN_IDENTITY="${1:-}"
KEYCHAIN_PROFILE="${2:-Slava}"

if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    echo "❌ Usage: $0 \"Developer ID Application: Your Name (TEAMID)\" [keychain-profile]" >&2
    exit 2
fi

exec "${REPO_ROOT}/Scripts/build_release.sh" \
    --sign-identity "$CODE_SIGN_IDENTITY" \
    --notarize-profile "$KEYCHAIN_PROFILE"
