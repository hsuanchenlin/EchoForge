#!/bin/bash
# Regenerate OpenSuperWhisper/AppIcon.icns, the Kongweh app icon, from its
# vector source in Scripts/GenerateAppIcon.swift.
#
# Run it after changing the artwork; the resulting .icns is committed, so the
# build never depends on this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET_DIR="$(mktemp -d)/EchoForge.iconset"
OUTPUT="${REPO_ROOT}/OpenSuperWhisper/AppIcon.icns"

trap 'rm -rf "$(dirname "${ICONSET_DIR}")"' EXIT

swift "${REPO_ROOT}/Scripts/GenerateAppIcon.swift" "${ICONSET_DIR}"
iconutil --convert icns "${ICONSET_DIR}" --output "${OUTPUT}"

echo "Wrote ${OUTPUT}"
sips -g pixelWidth -g pixelHeight "${OUTPUT}" | tail -n 2
