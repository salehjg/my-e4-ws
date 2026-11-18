#!/usr/bin/env bash
# The film of docs/presentation4 made on the board (SpacemiT X60) with the exact parameters of the x86 film:
# scripts/presentation4/cavity_movie.py unchanged (frame steps 16000 (k/40)^2, k = 0..40, plus 210; 64^3
# cells; warm-up 0; lid u = 0.05, omega 1.8 as built into the program; the middle plane; the same drawing,
# video and GIF), run by the verified RISC-V executable that all.sh timed: GCC f64
# SweepgenLdcCPU_explicit_cse_aa, the same variant as the x86 film.
#
# Checks (each prints PASS or FAIL; the last line says MOVIE PASS or MOVIE FAIL):
#   1. before the runs: the executable's sha256 is listed in verify-gcc-f64.log, which says VERIFY PASS
#   2. after the runs: the frame of step 210 (warm-up 0) has the same energy and field hash as all.sh's
#      runs of this executable (10 warm-up + 200 steps, ldc-gcc-rvv-f64-1core.log): bit for bit the result
#      of the timed benchmark
#   3. every frame's run used the same executable (its result line names the variant; one program)
# Comparison with the x86 film afterwards, on the laptop: scripts/presentation4/compare_movies.py.
#
# Start it on the board, detached (all 8 cores, about 2 to 2.5 hours; do not run timing jobs meanwhile):
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-movie bash -c \
#       "bash scripts/presentation4/cavity_movie_board.sh > ../presentation4/logs/movie.log 2>&1"
# Outputs: <base>/presentation4/movie/{frame-00..41.png,cavity.avi,cavity.gif},
#   <base>/presentation4/movie-work/slices.npz (middle planes, program path, result lines),
#   LOGDIR/cavity-movie-board.log (one result line per frame), LOGDIR/movie.log (this script).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
VENV="${VENV:-${BASE}/venv}"
JOBS="${JOBS:-$(nproc)}"
EXE="${P4DIR}/build-gcc-f64/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_explicit_cse_aa"
VER="${LOGDIR}/verify-gcc-f64.log"
REF="${LOGDIR}/ldc-gcc-rvv-f64-1core.log"
RUNLOG="${LOGDIR}/cavity-movie-board.log"
ok=1

echo "== start $(date), host $(hostname), load: $(cut -d' ' -f1-3 /proc/loadavg), ${JOBS} jobs"
sha="$(sha256sum "${EXE}" | cut -c1-16)"
if grep -q "^VERIFY PASS" "${VER}" && grep -q "sha256 ${sha} ${EXE}\$" "${VER}"; then
    echo "PASS 1 executable ${sha} ${EXE} is verified (${VER})"
else
    echo "FAIL 1 executable ${sha} ${EXE} is not in a passed verify log: not running"; echo "MOVIE FAIL"; exit 1
fi
ref="$(grep -m1 "^SweepgenLdcCPU variant=SweepgenLdcCPU_explicit_cse_aa " "${REF}")"
want_e="$(grep -o 'energy=[^ ]*' <<< "${ref}")"; want_h="$(grep -o 'fieldhash=[^ ]*' <<< "${ref}")"
echo "== reference (all.sh, 10 warm-up + 200 steps): ${want_e} ${want_h}"

echo "== runs and drawing $(date +%T)"
"${VENV}/bin/python" "${HERE}/cavity_movie.py" --exe "${EXE}" --jobs "${JOBS}" --work "${P4DIR}/movie-work" \
    --out "${P4DIR}/movie" --log "${RUNLOG}" || { echo "FAIL cavity_movie.py"; echo "MOVIE FAIL"; exit 1; }
echo "== runs and drawing done $(date +%T)"

got="$(grep -m1 '^frame-05 steps=210 ' "${RUNLOG}")"
got_e="$(grep -o 'energy=[^ ]*' <<< "${got}")"; got_h="$(grep -o 'fieldhash=[^ ]*' <<< "${got}")"
if [[ -n "${got}" && "${got_e}" == "${want_e}" && "${got_h}" == "${want_h}" ]]; then
    echo "PASS 2 step 210: ${got_e} ${got_h} = all.sh"
else
    echo "FAIL 2 step 210: '${got_e} ${got_h}' against all.sh '${want_e} ${want_h}'"; ok=0
fi
nframes="$(grep -c '^frame-' "${RUNLOG}")"
nvar="$(grep '^frame-' "${RUNLOG}" | grep -o 'variant=[^ ]*' | sort -u | wc -l)"
if [[ "${nframes}" == 42 && "${nvar}" == 1 ]] && grep -q "program ${EXE}\$" "${RUNLOG}"; then
    echo "PASS 3 42 frames, one variant ($(grep -m1 -o 'variant=[^ ]*' "${RUNLOG}")), program ${EXE}"
else
    echo "FAIL 3 frames ${nframes}, variants ${nvar}"; ok=0
fi
ls -la "${P4DIR}/movie/cavity.avi" "${P4DIR}/movie/cavity.gif" "${P4DIR}/movie-work/slices.npz"
echo "== $(ls "${P4DIR}"/movie/frame-*.png | wc -l) frames, $(du -sh "${P4DIR}/movie" | cut -f1) in ${P4DIR}/movie"
if (( ok )); then echo "MOVIE PASS $(date)"; else echo "MOVIE FAIL $(date)"; fi
