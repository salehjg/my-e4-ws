#!/usr/bin/env bash
# =============================================================================
#  Build the slides of docs/presentation7. The numbers come from tables/, written by
#  scripts/presentation7/slide_data.py (run it first after new measurements).
#
#  Usage:  ./build.sh [command]
#
#    pdf        (default) build build/slides.pdf with latexmk; \todo notes are shown in red
#               (show it with: pdfpc build/slides.pdf; the films need build/figures/cavity-movie*/cavity.avi,
#               which every build copies there)
#    final      build build/slides.pdf with all \todo notes hidden (for presenting)
#    png        build the PDF, then render every slide to build/png/ (needs pdftoppm)
#    todos      list the open \todo notes in the sources
#    watch      rebuild continuously whenever a source file changes
#    clean      remove the build/ directory
#    help       show this text
#
#  Needs only a TeX distribution with pdflatex, latexmk, beamer, pgfplots and
#  the FiraSans font package. Everything the build writes goes into build/.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="build"
MAIN="slides"

cd "$HERE"

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found in PATH" >&2; exit 1; }
}

latexmk_args() {
    echo -pdf -interaction=nonstopmode -halt-on-error -file-line-error -outdir="$BUILD_DIR"
}

list_todos() {
    # Every \todo{...} in the sources (the macro definition itself is skipped).
    grep -n '\\todo{' "$MAIN.tex" figures/*.tex | grep -v -E 'newcommand|^[^:]+:[0-9]+:[[:space:]]*%' || true
}

build_pdf() {
    # $1 = extra TeX code run before the document (used by 'final' to hide the todos)
    need latexmk; need pdflatex
    mkdir -p "$BUILD_DIR"
    # the build-ID tables are derived from the tables of slide_data.py (make_id_tables.py)
    python3 make_id_tables.py >/dev/null
    local pretex=()
    [[ -n "${1:-}" ]] && pretex=("-usepretex=$1")
    # latexmk does not rebuild when only the pretex changes, so force it then.
    [[ -n "${1:-}" || -f "$BUILD_DIR/.final" ]] && pretex+=("-g")
    if [[ -n "${1:-}" ]]; then touch "$BUILD_DIR/.final"; else rm -f "$BUILD_DIR/.final"; fi
    # shellcheck disable=SC2046
    if ! latexmk $(latexmk_args) "${pretex[@]}" "$MAIN.tex" >"$BUILD_DIR/latexmk.out" 2>&1; then
        echo "error: LaTeX build failed; last lines of the log:" >&2
        grep -n -A3 -E '^(.*:[0-9]+:|!)' "$BUILD_DIR/$MAIN.log" | head -40 >&2 || tail -40 "$BUILD_DIR/latexmk.out" >&2
        exit 1
    fi
    # The film slide's \movie only links its videos by relative paths figures/<film>/cavity.avi
    # (pdfpc plays them), so the videos go next to the PDF as well.
    for film in cavity-movie cavity-movie-board; do     # laptop (x86) and board (RVV) film
        if [[ -f "figures/$film/cavity.avi" ]]; then
            mkdir -p "$BUILD_DIR/figures/$film"
            cp -p "figures/$film/cavity.avi" "$BUILD_DIR/figures/$film/"
        fi
    done
    # Text that runs off a slide only shows up as a warning, so list those.
    grep -a -E '^Overfull' "$BUILD_DIR/$MAIN.log" || true
    local warnings
    warnings=$(grep -cE 'LaTeX Warning|Package .* Warning' "$BUILD_DIR/$MAIN.log" || true)
    echo "built $BUILD_DIR/$MAIN.pdf ($warnings warning(s) in $BUILD_DIR/$MAIN.log)"
    local todos
    todos=$(list_todos | wc -l)
    if [[ -n "${1:-}" ]]; then
        echo "$todos \\todo note(s) hidden in this build (./build.sh todos lists them)"
    else
        echo "$todos open \\todo note(s), shown in red:"; list_todos
    fi
}

build_png() {
    need pdftoppm
    rm -rf "$BUILD_DIR/png"
    mkdir -p "$BUILD_DIR/png"
    pdftoppm -png -r 80 "$BUILD_DIR/$MAIN.pdf" "$BUILD_DIR/png/slide"
    echo "rendered $(ls "$BUILD_DIR/png" | wc -l) slide(s) into $BUILD_DIR/png/"
}

cmd="${1:-pdf}"
case "$cmd" in
    pdf)   build_pdf ;;
    final) build_pdf '\def\hidetodos{}' ;;
    png)   build_pdf; build_png ;;
    todos) list_todos ;;
    watch) need latexmk; mkdir -p "$BUILD_DIR"
           # shellcheck disable=SC2046
           latexmk $(latexmk_args) -pvc -view=none "$MAIN.tex" ;;
    clean) rm -rf "$BUILD_DIR"; echo "removed $BUILD_DIR/" ;;
    help|-h|--help) awk 'NR > 2 && /^# =+$/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0" ;;
    *)     echo "unknown command '$cmd' (try ./build.sh help)" >&2; exit 2 ;;
esac
