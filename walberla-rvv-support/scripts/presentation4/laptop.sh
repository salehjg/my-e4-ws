#!/usr/bin/env bash
# The laptop half of docs/presentation4 (all.sh is the board half). Parts, in this order (PARTS selects):
#   x86film    x86 build with upstream pystencils (commit 20d7dcf0: the x86 AVX path we did not change), then
#              the laptop film with cavity_movie.py: figures/cavity-movie/, board-logs/x86/cavity-movie.log
#   logs       the board's logs -> docs/presentation4/board-logs/board/, sha256 checked against the board
#   boardfilm  the board's film (all.sh part "movie") -> figures/cavity-movie-board/, compared with the x86 film
#   check      check_figures.py: every plotted and tabled number = the logs
#   slides     docs/presentation4/build.sh
# Usage: bash scripts/presentation4/laptop.sh            (all parts; logs/boardfilm need ssh bananapi)
#        PARTS="x86film slides" bash scripts/presentation4/laptop.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PARTS="${PARTS:-x86film logs boardfilm check slides}"
HOST="${HOST:-bananapi}"
R=/home/bananapi/saleh/presentation4
B="${REPO}/build/presentation4-x86-upstream"
want() { [[ " ${PARTS} " == *" $1 "* ]]; }
status=()

if want x86film; then
    echo "== x86film $(date +%T)"
    B="${B}" PYSTENCILS=upstream bash "${HERE}/build_x86.sh" gcc f64 SweepgenLdcCPU_explicit_cse_aa
    python3 "${HERE}/cavity_movie.py" --exe "${B}/gcc-f64/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_explicit_cse_aa" \
        --work "${B}/cavity-movie-work" --jobs "${JOBS:-16}"
    #   step 210 against all.sh's run of the same program on the board (RISC-V, GCC f64): not bit-identical
    #   across instruction sets (the last digits differ), so: relative energy difference <= 1e-12
    got="$(grep -m1 '^frame-05 steps=210 ' "${REPO}/docs/presentation4/board-logs/x86/cavity-movie.log" | grep -o 'energy=[^ ]*' | cut -d= -f2)"
    ref="$(grep -m1 'variant=SweepgenLdcCPU_explicit_cse_aa ' "${REPO}/docs/presentation4/board-logs/board/ldc-gcc-rvv-f64-1core.log" | grep -o 'energy=[^ ]*' | cut -d= -f2)"
    if python3 -c "import sys; a, b = float(sys.argv[1]), float(sys.argv[2]); sys.exit(abs(a - b) / b > 1e-12)" "${got}" "${ref}"; then
        status+=("x86film: step 210 energy ${got}, board ${ref}: agree to 1e-12")
    else
        status+=("x86film: FAIL step 210 energy ${got} against the board's ${ref}")
    fi
fi
if want logs; then
    echo "== logs $(date +%T)"
    L="${REPO}/docs/presentation4/board-logs/board"
    scp -q "${HOST}:${R}/logs/*.log" "${L}/"
    if diff <(ssh "${HOST}" "cd ${R}/logs && sha256sum *.log" | sort) <(cd "${L}" && sha256sum *.log | sort) > /dev/null; then
        status+=("logs: $(ls "${L}"/*.log | wc -l) files, sha256 equal on board and laptop")
    else
        status+=("logs: FAIL sha256 differ (or extra local files)")
    fi
fi
if want boardfilm; then
    echo "== boardfilm $(date +%T)"
    bash "${HERE}/fetch_movie_board.sh" "${HOST}" | tail -n 3
    status+=("boardfilm: fetched and compared (COMPARE_MOVIES line above)")
fi
if want check; then
    echo "== check $(date +%T)"
    line="$(python3 "${HERE}/check_figures.py" | tail -n 1)"; echo "${line}"
    status+=("check: ${line}")
fi
if want slides; then
    echo "== slides $(date +%T)"
    (cd "${REPO}/docs/presentation4" && ./build.sh | tail -n 2)
    status+=("slides: docs/presentation4/build/slides.pdf")
fi
echo; printf '   %s\n' "${status[@]}"
