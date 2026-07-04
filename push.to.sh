#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

VALID_MACHINES=( bananapi )

declare -A REMOTE_PATHS=(
    [bananapi]="/home/bananapi/saleh"
)

ARCHIVE="my-e4-ws.zip"
SOURCE_DIR="my-e4-ws"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $(basename "$0") <machine>"
    echo
    echo "Available machines:"
    for m in "${VALID_MACHINES[@]}"; do
        printf "  %-12s  %s\n" "$m" "${REMOTE_PATHS[$m]}"
    done
    exit 1
}

# ─── Argument validation ──────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Error: machine name is required." >&2
    echo
    usage
fi

MACHINE="$1"

is_valid=false
for m in "${VALID_MACHINES[@]}"; do
    [[ "$MACHINE" == "$m" ]] && { is_valid=true; break; }
done

if ! $is_valid; then
    echo "Error: '$MACHINE' is not a recognised machine." >&2
    echo
    usage
fi

REMOTE_PATH="${REMOTE_PATHS[$MACHINE]}"

# ─── Step 1: Create archive ───────────────────────────────────────────────────

PARENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Creating archive: ${ARCHIVE}"
(
    cd "$PARENT_DIR"
    rm -f "$ARCHIVE"
    zip -r "$ARCHIVE" "$SOURCE_DIR"
)
echo "    Done."

# ─── Step 2: rsync with progress and speed report ────────────────────────────

echo "==> Transferring to ${MACHINE}:${REMOTE_PATH}/"
rsync \
    --progress \
    --stats \
    --human-readable \
    --compress \
    "${PARENT_DIR}/${ARCHIVE}" \
    "${MACHINE}:${REMOTE_PATH}/"
echo "    Transfer complete."

# ─── Step 3: Unzip on remote machine ─────────────────────────────────────────

echo "==> Unpacking on ${MACHINE}..."
ssh "$MACHINE" bash <<EOF
    set -euo pipefail
    cd "${REMOTE_PATH}"
    rm -rf "${SOURCE_DIR}"
    unzip -q "${ARCHIVE}"
    echo "    Unpack complete."
EOF

# ─── Step 4: Success report ───────────────────────────────────────────────────

printf "\n✓ Deployment successful.\n"
printf "  Files are at  %s  →  %s:%s/%s\n" \
    "$(pwd)/${SOURCE_DIR}" "$MACHINE" "$REMOTE_PATH" "$SOURCE_DIR"
