#!/usr/bin/env bash
# Sync this workspace to a remote board with rsync.
#
# Usage:  bash push.to.sh <machine>
#             this folder (walberla-rvv-support) -> <remote path>/my-e4-ws, without git data
#         bash push.to.sh <machine> --repo <remote folder>
#             the whole git repository (the folder above this one) with its .git, which also holds the
#             submodules' git data -> <remote path>/<remote folder>. The copy is a working git repository, so
#             branch, commit and local changes can be read there (scripts-legacy/remote.py: my-e4-ws-legacy).
#             Only what git sees goes: tracked and untracked files, nothing that git ignores (venvs, builds,
#             presentation data, ...). It also carries the whole history, commit authors included, to the shared
#             machine; the first push sends about 260 MB of git data, later ones only what changed.
#
# Why rsync (and not the former zip + rm -rf + unzip):
#   * incremental -- only changed files travel, so a push takes seconds;
#   * the heavy local-only directories (venvs, caches, local builds) and the copied results
#     (00_private_data/: never pushed back to a shared machine) are excluded,
#     the old archive carried ~330 MB of them on every push;
#   * `--delete` keeps the remote copy an exact mirror (same effect as the old
#     wipe-and-unzip; `--delete-excluded` also drops excluded leftovers), but
#     leaves the directory itself in place, so anything
#     pointing into it (e.g. a walberla build dir) survives a push.
#
# The boards are SHARED machines: everything stays under REMOTE_PATHS[<machine>].
set -euo pipefail

VALID_MACHINES=( bananapi monte3 )

declare -A REMOTE_PATHS=(
    [bananapi]="/home/bananapi/saleh"
    [monte3]="/home/sjamaligolzar/02_ws"     # UNIBO RVV 1.0 board (ssh alias in ~/.ssh/config)
)

usage() {
    echo "Usage: $(basename "$0") <machine> [--repo <remote folder>]"
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

if [[ "${2:-}" == "--repo" ]]; then
    if [[ -z "${3:-}" ]]; then
        echo "Error: --repo needs the remote folder name." >&2
        usage
    fi
    SOURCE="$(git -C "${HERE}" rev-parse --show-toplevel)"
    SOURCE_DIR="$3"
    PREFIX="$(git -C "${HERE}" rev-parse --show-prefix)"   # this folder inside the repository
    HERE_IN_SOURCE="/${PREFIX%/}"
    # Only what git sees: everything git ignores, in the repository and in each submodule, as anchored rsync
    # excludes. Git lists them itself, because rsync's own .gitignore reading gets `!` rules wrong.
    IGNORED="$(mktemp)"
    trap 'rm -f "${IGNORED}"' EXIT
    {
        git -C "${SOURCE}" ls-files --others --ignored --exclude-standard --directory | sed 's|^|/|'
        git -C "${SOURCE}" submodule --quiet foreach --recursive \
            'git ls-files --others --ignored --exclude-standard --directory | sed "s|^|/$displaypath/|"'
    } > "${IGNORED}"
    MODE_EXCLUDES=( --exclude-from "${IGNORED}" --exclude '/.claude/' )
else
    SOURCE="${HERE}"
    SOURCE_DIR="my-e4-ws"
    HERE_IN_SOURCE=""
    MODE_EXCLUDES=( --exclude '.git' )
fi

echo "==> Syncing ${SOURCE}/ -> ${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR}/"
# Trailing slashes matter: copy the *contents* of SOURCE into the remote dir.
# results-legacy/ (scripts-legacy/bench.py's runs) is neither sent nor deleted: the board's own runs stay there
# until scripts-legacy/remote.py fetch copies them back.
rsync -az --delete --delete-excluded \
    --filter "P ${HERE_IN_SOURCE}/results-legacy/" \
    --exclude "${HERE_IN_SOURCE}/results-legacy/" \
    "${MODE_EXCLUDES[@]}" \
    --exclude '.venv-rvv' \
    --exclude '.idea' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude '.perfcache' \
    --exclude '*.zip' \
    --exclude "${HERE_IN_SOURCE}/build/" \
    --exclude "${HERE_IN_SOURCE}/00_private_data/" \
    "${SOURCE}/" "${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR}/"

echo "✓ ${MACHINE}:${REMOTE_PATH}/${SOURCE_DIR} is up to date."
