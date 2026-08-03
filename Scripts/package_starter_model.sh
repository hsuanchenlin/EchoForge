#!/bin/bash
#
# Puts the starter speech model into the app bundle, when one has been supplied.
#
# EchoForge can ship with SenseVoice-Small already on board so a fresh install
# can dictate before it has downloaded anything. The weights are ~240 MB of
# third-party CoreML artifacts and are never committed to this repository, so
# they are a *build input*: the release operator stages them in a directory and
# this script copies them into Resources.
#
# Supplying them is optional and this script is a no-op without them. That is
# deliberate and load-bearing: CI (`./run.sh build`) and every developer
# checkout build without the artifact, and the app detects at runtime whether it
# has one (`StarterModel`).
#
# Usage:
#   Scripts/package_starter_model.sh                 # run by the Xcode build phase
#   Scripts/package_starter_model.sh --stage-from-cache
#       Populates StarterModel/ from this Mac's own FluidAudio cache, which is
#       how the artifact is produced reproducibly: download the model once in
#       the app, then copy the exact files the app loads.
#
# See docs/starter-model.md.

set -euo pipefail

# The cache directory name FluidAudio uses for this repository, and the entries
# SenseVoiceEngine loads. `StarterModelPackagingTests` asserts this list matches
# `SenseVoiceEngine.requiredCacheEntries` exactly, so the two cannot drift.
readonly CACHE_FOLDER="sensevoice-small"
readonly REQUIRED_ENTRIES=(
    "SenseVoicePreprocessor.mlmodelc"
    "SenseVoiceSmall_int8.mlmodelc"
    "vocab.json"
)

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly STAGING_ROOT="${STARTER_MODEL_DIR:-${REPO_ROOT}/StarterModel}"
readonly STAGING_DIR="${STAGING_ROOT}/${CACHE_FOLDER}"
readonly LIVE_CACHE="${HOME}/Library/Application Support/FluidAudio/Models/${CACHE_FOLDER}"

have_every_entry() {
    local dir="$1"
    local entry
    for entry in "${REQUIRED_ENTRIES[@]}"; do
        [[ -e "${dir}/${entry}" ]] || return 1
    done
    return 0
}

stage_from_cache() {
    if [[ ! -d "$LIVE_CACHE" ]]; then
        echo "❌ No SenseVoice cache at ${LIVE_CACHE}"
        echo "   Download the model once (Settings ▸ Model ▸ SenseVoice-Small), then re-run this."
        exit 1
    fi
    if ! have_every_entry "$LIVE_CACHE"; then
        echo "❌ ${LIVE_CACHE} is missing one of: ${REQUIRED_ENTRIES[*]}"
        echo "   The download may be incomplete, or the app may load a different encoder precision."
        exit 1
    fi

    mkdir -p "$STAGING_DIR"
    local entry
    for entry in "${REQUIRED_ENTRIES[@]}"; do
        rm -rf "${STAGING_DIR:?}/${entry}"
        ditto "${LIVE_CACHE}/${entry}" "${STAGING_DIR}/${entry}"
    done

    echo "✅ Staged the starter model in ${STAGING_DIR}"
    du -sh "$STAGING_DIR" | sed 's/^/   /'
    echo "   It is gitignored. Builds from now on will package it; see docs/starter-model.md."
    exit 0
}

if [[ "${1:-}" == "--stage-from-cache" ]]; then
    stage_from_cache
fi

# --- Build-phase mode ---------------------------------------------------------

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
    echo "note: not running inside an Xcode build; nothing to do."
    exit 0
fi

readonly DESTINATION="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/StarterModel/${CACHE_FOLDER}"

if [[ ! -d "$STAGING_DIR" ]]; then
    echo "note: no starter model staged at ${STAGING_DIR}; building without one."
    rm -rf "${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/StarterModel"
    exit 0
fi

if ! have_every_entry "$STAGING_DIR"; then
    # Loud rather than silent: a half-staged directory would produce a build
    # that claims to ship a starter model and cannot load it.
    echo "error: ${STAGING_DIR} is missing one of: ${REQUIRED_ENTRIES[*]}"
    exit 1
fi

mkdir -p "$DESTINATION"
for entry in "${REQUIRED_ENTRIES[@]}"; do
    rm -rf "${DESTINATION:?}/${entry}"
    ditto "${STAGING_DIR}/${entry}" "${DESTINATION}/${entry}"
done

echo "note: packaged the starter model from ${STAGING_DIR}"
