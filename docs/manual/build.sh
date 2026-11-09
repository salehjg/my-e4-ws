#!/usr/bin/env bash
# =============================================================================
#  Build the manuals (all reports in one document).
#
#  Usage:  ./build.sh [command]
#
#    pdf        (default) build build/manual.pdf with latexmk
#    listings [rNN] [args...]
#               refresh a report's captured listings by running its
#               tools/listings.sh (args are passed on, e.g. ./build.sh listings r01 ex01);
#               without rNN, every report that has a tools/listings.sh
#    all        listings, then pdf
#    watch      rebuild continuously whenever a source file changes
#    clean      remove the build/ directory
#    help       show this text
#
#  The PDF build itself needs only a TeX distribution (pdflatex, latexmk, biber):
#  captured listings (e.g. reports/r01/generated/) are part of the repository.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="build"
MAIN="manual"

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
    mkdir -p "$BUILD_DIR"
    find reports -type d -not -name __pycache__ -exec mkdir -p "$BUILD_DIR/{}" \;
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
    # Duplicate or missing labels still produce a PDF, just with wrong numbers.
    grep -a -E 'LaTeX Warning: (Label|Reference)|Citation .* undefined' "$BUILD_DIR/$MAIN.log" || true
    local warnings
    warnings=$(grep -cE 'LaTeX Warning|Package .* Warning' "$BUILD_DIR/$MAIN.log" || true)
    echo "built $BUILD_DIR/$MAIN.pdf ($warnings warning(s) in $BUILD_DIR/$MAIN.log)"
}

build_listings() {
    local reports=()
    if [[ $# -gt 0 && -d "reports/$1" ]]; then
        reports=("$1"); shift
    else
        for script in reports/*/tools/listings.sh; do
            [[ -e "$script" ]] && reports+=("$(basename "$(dirname "$(dirname "$script")")")")
        done
    fi
    [[ ${#reports[@]} -gt 0 ]] || { echo "error: no report has a tools/listings.sh" >&2; exit 1; }
    for r in "${reports[@]}"; do
        [[ -x "reports/$r/tools/listings.sh" ]] || { echo "error: reports/$r has no tools/listings.sh" >&2; exit 1; }
        echo "[listings] $r"
        "reports/$r/tools/listings.sh" "$@"
    done
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
