#!/usr/bin/env bash
# presentation5: time some SweepgenLdcCPU builds on the board, interleaved. Nothing is built: it times the
# executables that scripts/presentation4/prepare.sh built and verified (the sources did not change since),
# and refuses any executable whose sha256 is not in prepare.sh's verify log.
#
# Usage: bash scripts/presentation5/run.sh <gcc|clang> <f32|f64> <cores> <variant>...
#   cores = 1   one process, pinned to core CPU (default 2)
#   cores > 1   that many MPI processes, one per core (4 = one cluster of the K1, 8 = the whole chip)
# Every process gets its own CELLS^3 block.
#
# Changes against scripts/presentation4/run.sh (docs/notes5, findings F8, F21; scripts/presentation5/steps_check.sh):
#   - 60 timed steps instead of 200 (the per-step speed and the spread are the same, steps_check.sh), so the
#     slowest experiment (RVV, f64, 8 cores) takes about 5 min instead of 15
#   - the variants run round-robin: ROUNDS rounds, each runs every variant once (not 3 runs back to back)
#   - the governor, clock, temperatures and busy cores are recorded at the start, the busy cores before
#     every round
#
# Environment: CELLS=64 STEPS=60 WARMUP=10 ROUNDS=3 CPU=2
#   SWEEPGEN_LDC_OUTPUT=last  passed through to the app (rho and u only in the last step; default: every step)
# Prints one result line per run (the same format as presentation4, so its summary.py reads it), then a
# table with the best run per variant.
set -u

CC_NAME="$1"; PREC="$2"; CORES="$3"; shift 3
VARIANTS="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"                 # /home/bananapi/saleh on the board
P4DIR="${P4DIR:-${BASE}/presentation4}"     # the verified build trees and their verify logs
VENV="${VENV:-${BASE}/venv}"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-60}"
WARMUP="${WARMUP:-10}"
ROUNDS="${ROUNDS:-3}"
CPU="${CPU:-2}"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"

case "${CC_NAME}" in gcc|clang) ;; *) echo "usage: $0 <gcc|clang> <f32|f64> <cores> <variant>..."; exit 1 ;; esac
case "${PREC}" in f32|f64) ;; *) echo "usage: $0 <gcc|clang> <f32|f64> <cores> <variant>..."; exit 1 ;; esac

exe_of() {   # exe_of <variant>: scalar variants live in the -scalar tree (every file -march=rv64gc)
    local tree="build-${CC_NAME}-${PREC}"; [[ "$1" == scalar* ]] && tree+="-scalar"
    echo "${P4DIR}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$1"
}

echo "== ${CC_NAME} ${PREC}, ${CORES} core(s), ${CELLS}^3 cells per core, ${STEPS} steps (+${WARMUP} warm-up), ${ROUNDS} interleaved rounds, output ${SWEEPGEN_LDC_OUTPUT:-every}: ${VARIANTS}"
echo "== start $(date), host $(hostname)"
env_record

vlog="${P4DIR}/logs/verify-${CC_NAME}-${PREC}.log"
grep -q "VERIFY PASS" "${vlog}" 2>/dev/null || { echo "ABORTED: ${vlog} has no VERIFY PASS"; exit 1; }
for v in ${VARIANTS}; do
    exe="$(exe_of "${v}")"
    h="$(sha256sum "${exe}" 2>/dev/null | cut -c1-16)"
    #   the same line as presentation4's run.sh: it ties the timings to the verified binary
    awk -v h="${h}" -v p="${exe}" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${vlog}" \
        && echo "   sha256 ${h} ${exe}" || { echo "ABORTED: NOT VERIFIED ${exe} (sha256 ${h:-missing})"; exit 1; }
done

echo "== run $(date)"
RESULTS="$(mktemp)"
for r in $(seq 1 "${ROUNDS}"); do
    echo "== round ${r} $(date +%T), $(busy_cores)"
    for v in ${VARIANTS}; do
        exe="$(exe_of "${v}")"
        if [[ "${CORES}" == 1 ]]; then
            out="$(taskset -c "${CPU}" "${exe}" "${CELLS}" "${STEPS}" "${WARMUP}" 2>&1)"
        else
            out="$(mpirun -np "${CORES}" --bind-to core --map-by core "${exe}" "${CELLS}" "${STEPS}" "${WARMUP}" 2>&1)"
        fi
        line="$(grep '^SweepgenLdcCPU variant=' <<< "${out}" || echo "SweepgenLdcCPU_${v} FAILED: $(tail -3 <<< "${out}")")"
        echo "${line}" | tee -a "${RESULTS}"
    done
done

echo
"${VENV}/bin/python" "${REPO}/scripts/presentation4/summary.py" "${CC_NAME} ${PREC} ${CORES}c=${RESULTS}"
rm -f "${RESULTS}"
echo "== done $(date)"
