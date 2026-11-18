#!/usr/bin/env bash
# All the whole-program numbers of docs/presentation4 in one session: the scalar, autovec and rvv
# experiments of SweepgenLdcCPU (lid-driven cavity), with GCC and Clang, in f32 and f64, on 1, 4 and
# 8 cores (64^3 cells per core, best of 3 runs of 200 steps after 10 warm-up steps).
#
# Run prepare.sh <f32|f64> first (both must end with PREPARE PASS): it builds and verifies the
# executables, and all.sh times exactly those. all.sh runs run.sh with SKIP_BUILD=1 (no cmake, no
# build), and it refuses to start unless every executable's sha256 appears in prepare.sh's verify
# log (verify-<cc>-<prec>.log, which must say VERIFY PASS); at the end it checks the sha256 that
# every timing log recorded against the same verify logs.
#
# After the timing matrix it runs every other board job of docs/presentation4, one after the other, each
# exactly as when started alone and with its own log in LOGDIR (PARTS selects; default: all, in this order):
#   matrix   the timing matrix above (about 4 h 40 min)                      ldc-*.log
#   streams  streams_check.sh: stream test and the program's counters (4 min) streams*.log
#   speedup  speedup_check.sh: plain scalar against RVV, interleaved (17 min)  speedup*.log
#   extras   extras.sh: warm-up 10 / 2000, scalar builds in the vector tree (about 3 h)  extras*.log
#   recheck  recheck.sh: the extras' comparisons interleaved (47 min)          recheck*.log
#   movie    cavity_movie_board.sh: the film, all 8 cores (about 2 to 2.5 h)  movie.log, cavity-movie-board.log
# In all about 11 hours. The film comes last because it uses every core. At the end: one status line per part.
#
# Start it on the board, detached, so it survives a lost connection:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-all bash -c \
#       "bash scripts/presentation4/all.sh > ../presentation4/logs/all.log 2>&1"
# Only some parts:  PARTS="streams movie" bash scripts/presentation4/all.sh ...
# See what it would run, without running anything (the verify check still runs):  DRY_RUN=1 bash scripts/presentation4/all.sh
# One log per experiment of the matrix in LOGDIR (default <base>/presentation4/logs):
#   ldc-<gcc|clang>-<scalar|autovec|rvv>-<f32|f64>-<1|4|8>core.log
# and the combined tables in this script's output.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
VENV="${VENV:-${BASE}/venv}"
PARTS="${PARTS:-matrix streams speedup extras recheck movie}"
DRY_RUN="${DRY_RUN:-0}"
mkdir -p "${LOGDIR}"
echo "== start $(date), parts: ${PARTS}$( [[ "${DRY_RUN}" == 1 ]] && echo ', DRY RUN: nothing is run')"
for part in ${PARTS}; do
    case "${part}" in matrix|streams|speedup|extras|recheck|movie) ;; *) echo "ALL ABORTED: unknown part ${part}"; exit 1 ;; esac
done
want() { [[ " ${PARTS} " == *" $1 "* ]]; }
#   run_part <name> <log> <script>: one of the other board jobs, as when started alone
run_part() {
    echo "== part $1: bash scripts/presentation4/$3 > $2 $(date +%T)"
    [[ "${DRY_RUN}" == 1 ]] && return 0
    bash "${HERE}/$3" > "$2" 2>&1
    echo "== part $1 ended $(date +%T): $(tail -n 1 "$2")"
}

SCALAR="scalar scalar_cse scalar_cse_aa"
VECTOR="autovec autovec_cse autovec_cse_aa explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
#   in_verify_log <log> <hash> <exe>: prepare.sh's verify log lists this executable with this hash
in_verify_log() {
    awk -v h="$2" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "$1"
}
bad=0
for cc in gcc clang; do
    for prec in f32 f64; do
        vlog="${LOGDIR}/verify-${cc}-${prec}.log"
        grep -q "VERIFY PASS" "${vlog}" 2>/dev/null || { echo "NOT VERIFIED: ${vlog} has no VERIFY PASS"; bad=1; continue; }
        for v in ${SCALAR} ${VECTOR}; do
            tree="build-${cc}-${prec}"; [[ "${v}" == scalar* ]] && tree+="-scalar"
            exe="${P4DIR}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"
            h="$(sha256sum "${exe}" 2>/dev/null | cut -c1-16)"
            in_verify_log "${vlog}" "${h}" "${exe}" && echo "   verified ${h} ${exe}" \
                || { echo "NOT VERIFIED: ${exe} (sha256 ${h:-missing})"; bad=1; }
        done
    done
done
[[ "${bad}" == 0 ]] || { echo "ALL ABORTED: run prepare.sh f32 and f64 (PREPARE PASS) first"; exit 1; }

if want matrix; then
for cc in gcc clang; do
    for prec in f32 f64; do
        for cores in 1 4 8; do
            for exp in scalar autovec rvv; do
                log="${LOGDIR}/ldc-${cc}-${exp}-${prec}-${cores}core.log"
                echo "== ${cc} ${exp} ${prec} ${cores} core(s) $(date +%T) -> ${log}"
                [[ "${DRY_RUN}" == 1 ]] && continue
                SKIP_BUILD=1 bash "${HERE}/${exp}.sh" "${cc}" "${prec}" "${cores}" > "${log}" 2>&1
                grep -E "FAILED|missing" "${log}"
            done
        done
    done
done

if [[ "${DRY_RUN}" != 1 ]]; then
echo
labels=()
for cores in 1 4 8; do
    for cc in gcc clang; do
        for prec in f32 f64; do
            for exp in scalar autovec rvv; do
                labels+=("${cc} ${prec} ${cores}c=${LOGDIR}/ldc-${cc}-${exp}-${prec}-${cores}core.log")
            done
        done
    done
done
"${VENV}/bin/python" "${HERE}/summary.py" "${labels[@]}"

#   Every timed executable (the sha256 line run.sh prints before its runs) is a verified one
echo
unverified=0
for cc in gcc clang; do
    for prec in f32 f64; do
        for log in "${LOGDIR}"/ldc-${cc}-*-${prec}-*core.log; do
            while read -r _ h exe; do
                in_verify_log "${LOGDIR}/verify-${cc}-${prec}.log" "${h}" "${exe}" \
                    || { echo "UNVERIFIED in $(basename "${log}"): ${h} ${exe}"; unverified=$((unverified + 1)); }
            done < <(grep -E "^   sha256 " "${log}")
        done
    done
done
echo "== timed executables not in a verify log: ${unverified}"
matrix_status="timed executables not in a verify log: ${unverified}"
fi   # not a dry run
fi   # matrix

#   the other board jobs, one after the other (none starts before the previous one has ended)
want streams && run_part streams "${LOGDIR}/streams.log" streams_check.sh
want speedup && run_part speedup "${LOGDIR}/speedup.log" speedup_check.sh
want extras && run_part extras "${LOGDIR}/extras.log" extras.sh
want recheck && run_part recheck "${LOGDIR}/recheck.log" recheck.sh
want movie && run_part movie "${LOGDIR}/movie.log" cavity_movie_board.sh

#   one status line per part (the last line each job writes; the film's says MOVIE PASS or MOVIE FAIL)
echo
echo "== status of the parts (logs in ${LOGDIR})"
for part in ${PARTS}; do
    case "${part}" in
        matrix)  line="${matrix_status:-}" ;;
        streams) line="$(tail -n 1 "${LOGDIR}/streams.log" 2>/dev/null)" ;;
        speedup) line="$(tail -n 1 "${LOGDIR}/speedup.log" 2>/dev/null)" ;;
        extras)  line="$(tail -n 1 "${LOGDIR}/extras.log" 2>/dev/null)" ;;
        recheck) line="$(tail -n 1 "${LOGDIR}/recheck.log" 2>/dev/null)" ;;
        movie)   line="$(grep -h '^MOVIE ' "${LOGDIR}/movie.log" 2>/dev/null | tail -n 1)" ;;
    esac
    [[ "${DRY_RUN}" == 1 ]] && line="(dry run)"
    echo "   ${part}: ${line:-no status line}"
done
echo "== ALL DONE $(date)"
