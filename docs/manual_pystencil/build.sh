#!/usr/bin/env bash
# =============================================================================
#  Build the pystencils manual.
#
#  Usage:  ./build.sh [command]
#
#    pdf        (default) build build/pystencils-manual.pdf with latexmk
#    listings   re-run all examples/ and refresh the captured outputs in generated/
#               (needs Python + pystencils; extra arguments select examples, e.g. ex01)
#    all        listings, then pdf
#    watch      rebuild continuously whenever a source file changes
#    clean      remove the build/ directory
#    help       show this text
#
#  Environment overrides for 'listings':
#    PYTHON          Python interpreter      (default: <repo>/.venv-rvv/bin/python, else python3)
#    PYSTENCILS_SRC  pystencils source tree  (default: <repo>/submodules/pystencils/src)
#
#  The PDF build itself needs only a TeX distribution (pdflatex, latexmk, biber):
#  the captured listings in generated/ are part of the repository.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD_DIR="build"
MAIN="main"
PDF_NAME="pystencils-manual.pdf"

cd "$HERE"

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found in PATH" >&2; exit 1; }
}

latexmk_args() {
    echo -pdf -interaction=nonstopmode -halt-on-error -file-line-error -outdir="$BUILD_DIR"
}

prepare_build_dir() {
    # pdflatex writes the .aux file of every \include'd file into the matching
    # sub-directory of the output directory, which must already exist.
    mkdir -p "$BUILD_DIR/chapters" "$BUILD_DIR/appendices"
}

build_pdf() {
    need latexmk; need pdflatex; need biber
    prepare_build_dir
    # shellcheck disable=SC2046
    if ! latexmk $(latexmk_args) "$MAIN.tex" >"$BUILD_DIR/latexmk.out" 2>&1; then
        echo "error: LaTeX build failed; last lines of the log:" >&2
        grep -n -A3 -E '^(.*:[0-9]+:|!)' "$BUILD_DIR/$MAIN.log" | head -40 >&2 || tail -40 "$BUILD_DIR/latexmk.out" >&2
        exit 1
    fi
    cp "$BUILD_DIR/$MAIN.pdf" "$BUILD_DIR/$PDF_NAME"
    local warnings
    warnings=$(grep -cE 'LaTeX Warning|Package .* Warning' "$BUILD_DIR/$MAIN.log" || true)
    echo "built $BUILD_DIR/$PDF_NAME ($warnings warning(s) in $BUILD_DIR/$MAIN.log)"
}

build_listings() {
    local py="${PYTHON:-}"
    if [[ -z "$py" ]]; then
        if [[ -x "$REPO/.venv-rvv/bin/python" ]]; then py="$REPO/.venv-rvv/bin/python"; else py="python3"; fi
    fi
    local src="${PYSTENCILS_SRC:-$REPO/submodules/pystencils/src}"
    [[ -d "$src/pystencils" ]] || { echo "error: no pystencils sources at $src" >&2; exit 1; }
    PYTHONPATH="$src${PYTHONPATH:+:$PYTHONPATH}" "$py" -B tools/gen_listings.py "$@"
}

cmd="${1:-pdf}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
    pdf)      build_pdf ;;
    listings) build_listings "$@" ;;
    all)      build_listings "$@"; build_pdf ;;
    watch)    need latexmk; prepare_build_dir
              # shellcheck disable=SC2046
              latexmk $(latexmk_args) -pvc -view=none "$MAIN.tex" ;;
    clean)    rm -rf "$BUILD_DIR"; echo "removed $BUILD_DIR/" ;;
    help|-h|--help) awk 'NR > 2 && /^# =+$/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0" ;;
    *)        echo "unknown command '$cmd' (try ./build.sh help)" >&2; exit 2 ;;
esac
