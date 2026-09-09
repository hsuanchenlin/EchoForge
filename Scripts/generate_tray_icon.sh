#!/bin/bash
# Regenerate the three menu-bar icons from their vector source in
# Scripts/GenerateTrayIcon.swift.
#
# Run it after changing the artwork; the PDFs are committed, so the build never
# depends on this script - which is exactly why `TrayIconArtworkTests` reads the
# committed files rather than the source.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swift "${REPO_ROOT}/Scripts/GenerateTrayIcon.swift" "${REPO_ROOT}/OpenSuperWhisper"
