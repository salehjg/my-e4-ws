#!/usr/bin/env bash
# =============================================================================
#  Re-run all examples/ of report r01 and refresh the captured outputs in
#  generated/. Normally called as `./build.sh listings r01` from docs/manual/;
#  extra arguments select examples, e.g. `./build.sh listings r01 ex01 ex08`.
#
#  Environment overrides:
#    PYTHON          Python interpreter      (default: <repo>/.venv-rvv/bin/python, else python3)
#    PYSTENCILS_SRC  pystencils source tree  (default: <repo>/submodules/pystencils/src)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$(cd "$HERE/.." && pwd)"
REPO="$(git -C "$REPORT" rev-parse --show-toplevel)"

py="${PYTHON:-}"
if [[ -z "$py" ]]; then
    if [[ -x "$REPO/.venv-rvv/bin/python" ]]; then py="$REPO/.venv-rvv/bin/python"; else py="python3"; fi
fi
src="${PYSTENCILS_SRC:-$REPO/submodules/pystencils/src}"
[[ -d "$src/pystencils" ]] || { echo "error: no pystencils sources at $src" >&2; exit 1; }

cd "$REPORT"
PYTHONPATH="$src${PYTHONPATH:+:$PYTHONPATH}" "$py" -B tools/gen_listings.py "$@"
