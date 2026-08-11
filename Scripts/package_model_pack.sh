#!/bin/bash
#
# Builds a model pack: one engine's weights as a versioned, checksummed archive
# that the app installs into the model cache.
#
# Why this exists. The app used to get weights two ways, neither of them
# checked. Bundled into the .app, which made the shipped DMG 222 MB - and since
# the weights live in Application Support and survive an app replacement, an
# updating user downloaded 212 MB of bytes their machine already had, verified
# them, mounted them, copied them into place and never read them. Or fetched
# straight from Hugging Face at first run, with no digest, no host rule and no
# version of its own. A pack replaces both.
#
# The format is a gzipped tar of exactly one directory, named as the engine's
# cache folder. That was measured rather than assumed: a `.mlmodelc` round-trips
# through tar byte for byte and CoreML loads the extracted copy. See
# docs/model-packs.md for the measurement.
#
# Publishing must pass `--latest=false`: a pack is a GitHub release, and a new
# release becomes the repository's *latest* by default - the exact document the
# app's update check reads. A pack left as latest carries no EchoForge.dmg, so
# every running app's update check would fail. See docs/model-packs.md.
#
# Usage:
#   Scripts/package_model_pack.sh --id sensevoice-small --version 1.0.0
#       Packs this Mac's own cache for that model, and prints the JSON to paste
#       into OpenSuperWhisper/ModelPacks.json.
#
# Options:
#   --id <cache folder>    the model cache directory name, which is also the pack id
#   --version <x.y.z>      the pack's own version, independent of the app's
#   --from <dir>           pack this directory instead of the live cache
#   --out <dir>            where to write the archive (default: dist/model-packs)
#   --tag <tag>            the release tag it will be published under
#                          (default: models/<id>/<version>)

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPOSITORY="hsuanchenlin/EchoForge"
readonly FLUIDAUDIO_CACHE="${HOME}/Library/Application Support/FluidAudio/Models"

id=""
version=""
source_dir=""
out_dir="${REPO_ROOT}/dist/model-packs"
tag=""

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'
    exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id) id="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --from) source_dir="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

[[ -n "$id" ]] || { echo "❌ --id is required"; usage; }
[[ -n "$version" ]] || { echo "❌ --version is required"; usage; }
[[ -n "$source_dir" ]] || source_dir="${FLUIDAUDIO_CACHE}/${id}"
[[ -n "$tag" ]] || tag="models/${id}/${version}"

if [[ ! -d "$source_dir" ]]; then
    echo "❌ No model at ${source_dir}"
    echo "   Download it once in the app, or pass --from."
    exit 1
fi

# The engine is what decides which files count, so the pack records exactly what
# is there rather than a list this script holds an opinion about. A pack with an
# entry the engine does not load is harmless; one missing an entry it does load
# installs a cache that can never work, which is why the app re-checks the list
# after extracting.
entries=()
while IFS= read -r entry; do
    # Skip the app's own receipt, and anything hidden: the app writes the
    # receipt after installing, and packing one back up would be circular.
    [[ "$entry" == .* || "$entry" == "echoforge-pack.json" ]] && continue
    entries+=("$entry")
done < <(ls -1 "$source_dir")

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "❌ ${source_dir} is empty"
    exit 1
fi

mkdir -p "$out_dir"
readonly ARCHIVE="${out_dir}/echoforge-model-${id}-${version}.tar.gz"

echo "📦 Packing ${id} ${version} from ${source_dir}"
# `-C` so the archive contains the cache folder itself and nothing above it:
# the installer extracts into a staging directory and expects exactly one
# top-level directory named as the cache folder.
tar -czf "$ARCHIVE" -C "$(dirname "$source_dir")" "$(basename "$source_dir")"

bytes="$(stat -f%z "$ARCHIVE")"
digest="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
(cd "$out_dir" && shasum -a 256 "$(basename "$ARCHIVE")") > "${ARCHIVE}.sha256"

echo "✅ ${ARCHIVE}"
echo "   $(du -h "$ARCHIVE" | cut -f1 | tr -d ' '), sha256 ${digest}"
echo
echo "Publish it, then add this to OpenSuperWhisper/ModelPacks.json:"
echo
python3 - "$id" "$version" "$digest" "$bytes" "$tag" "$(basename "$ARCHIVE")" "$REPOSITORY" "${entries[@]}" <<'PY'
import json, sys, urllib.parse
id_, version, digest, size, tag, filename, repository, *entries = sys.argv[1:]
engines = {"sensevoice-small": "sensevoice", "paraformer-large-zh": "paraformer"}
url = (f"https://github.com/{repository}/releases/download/"
       f"{urllib.parse.quote(tag, safe='')}/{filename}")
print(json.dumps({
    "id": id_,
    "version": version,
    "engine": engines.get(id_, "REPLACE-ME"),
    "cacheFolder": id_,
    "entries": sorted(entries),
    "bytes": int(size),
    "sha256": digest,
    "url": url,
    "minimumAppVersion": "0.6.0",
}, indent=2))
PY
echo
echo "Upload with:"
echo "  gh release create '${tag}' '${ARCHIVE}' '${ARCHIVE}.sha256' --latest=false --title '${id} ${version}' --notes 'Model pack.'"
