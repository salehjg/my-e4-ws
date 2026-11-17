#!/usr/bin/env bash
# Sync this workspace to a remote board with rsync.
#
# Usage:  bash push.to.sh <machine>
#
# Why rsync (and not the former zip + rm -rf + unzip):
#   * incremental -- only changed files travel, so a push takes seconds;
#   * the heavy local-only directories (.git, .venv-rvv, caches) are excluded,
#     the old archive carried ~330 MB of them on every push;
#   * `--delete` keeps the remote copy an exact mirror (same effect as the old
#     wipe-and-unzip; `--delete-excluded` also drops excluded leftovers), but
#     leaves the directory itself in place, so anything
#     pointing into it (e.g. a walberla build dir) survives a push.
#
# The board is a SHARED machine: everything stays under REMOTE_PATHS[<machine>].
set -euo pipefail

VALID_MACHINES=( bananapi )

declare -A REMOTE_PATHS=(
    [bananapi]="/home/bananapi/saleh"
)

SOURCE_DIR="my-e4-ws"

usage() {
    echo "Usage: $(basename "$0") <machine>"
    echo
    echo "Available machines:"
    for m in "${VALID_MACHINES[@]}"; do
        printf "  %-12s  %s\n" "$m" "${REMOTE_PATHS[$m]}"
    done
    exit 1
}

if [[ $# -lt 1 ]]; then
    echo "Error: machine name is required." >&2
    usage
fi

MACHINE="$1"
if [[ -z "${REMOTE_PATHS[$MACHINE]+x}" ]]; then
    echo "Error: '$MACHINE' is not a recognised machine." >&2
    usage
fi
REMOTE_PATH="${REMOTE_PATHS[$MACHINE]}"

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Syncing ${HERE}/ -> ${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR}/"
# Trailing slashes matter: copy the *contents* of HERE into the remote dir.
rsync -az --delete --delete-excluded \
    --exclude '.git' \
    --exclude '.venv-rvv' \
    --exclude '.idea' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude 'scripts/.perfcache' \
    --exclude '*.zip' \
    "${HERE}/" "${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR}/"

echo "✓ ${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR} is up to date."
