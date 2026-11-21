#!/usr/bin/env bash
# presentation6: time some SweepgenLdcCPU builds, interleaved (presentation5's run.sh on the machine profile of
# machine.sh). Nothing is built: it times the executables that prepare.sh built and verified, and refuses any
# executable whose sha256 is not in prepare.sh's verify log.
#
# Usage: bash scripts/presentation6/run.sh <gcc|clang> <f32|f64> <cores> <variant>...
#   cores = 1   one process, pinned to core CPU (default 2)
#   cores > 1   that many MPI processes, one per core (machine.sh's MPI launch; bananapi: 4 = one cluster of
#               the K1, 8 = the whole chip)
# Every process gets its own CELLS^3 block.
#
# Protocol (presentation5, scripts/presentation5/steps_check.sh): 60 timed steps after 10 warm-up steps; the
# variants run round-robin, ROUNDS rounds; the machine's state (governor, clock, temperatures, busy cores) is
# recorded at the start and the busy cores before every round.
#
# Environment: CELLS=64 STEPS=60 WARMUP=10 ROUNDS=3 CPU=2, BUILD_ROOT (machine.sh)
#   SWEEPGEN_LDC_OUTPUT=last  passed through to the app (rho and u only in the last step; default: every step)
# Prints one result line per run (the format of presentation4, so summary.py reads it), then a table with the
# best run per variant.
set -u

CC_NAME="$1"; PREC="$2"; CORES="$3"; shift 3
VARIANTS="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-60}"
WARMUP="${WARMUP:-10}"
ROUNDS="${ROUNDS:-3}"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"

usage() { echo "usage: $0 <gcc|clang> <f32|f64> <cores> <variant>..."; exit 1; }
case "${CC_NAME}" in gcc|clang) ;; *) usage ;; esac
case "${PREC}" in f32|f64) ;; *) usage ;; esac
(( CORES >= 1 && CORES <= ALL_CORES )) || { echo "ABORTED: ${CORES} cores asked, ${ALL_CORES} usable"; exit 1; }

echo "== ${CC_NAME} ${PREC}, ${CORES} core(s), ${CELLS}^3 cells per core, ${STEPS} steps (+${WARMUP} warm-up), ${ROUNDS} interleaved rounds, output ${SWEEPGEN_LDC_OUTPUT:-every}: ${VARIANTS}"
echo "== start $(date), host $(hostname)"
p6_profile
env_record

vlog="${BUILD_ROOT}/logs/verify-${CC_NAME}-${PREC}.log"
grep -q "VERIFY PASS" "${vlog}" 2>/dev/null || { echo "ABORTED: ${vlog} has no VERIFY PASS"; exit 1; }
for v in ${VARIANTS}; do
    p6_supported "${v}" || { echo "ABORTED: ${v} needs VLEN >= ${RVV_VLEN}, this machine has ${VLEN}"; exit 1; }
    exe="$(p6_exe "${CC_NAME}" "${PREC}" "${v}")"
    h="$(sha256sum "${exe}" 2>/dev/null | cut -c1-16)"
    #   the same line as presentation4's run.sh: it ties the timings to the verified binary
    p6_in_verify_log "${vlog}" "${h}" "${exe}" \
        && echo "   sha256 ${h} ${exe}" || { echo "ABORTED: NOT VERIFIED ${exe} (sha256 ${h:-missing})"; exit 1; }
done

echo "== run $(date)"
RESULTS="$(mktemp)"
for r in $(seq 1 "${ROUNDS}"); do
    echo "== round ${r} $(date +%T), $(busy_cores)"
    for v in ${VARIANTS}; do
        exe="$(p6_exe "${CC_NAME}" "${PREC}" "${v}")"
        if [[ "${CORES}" == 1 ]]; then
            out="$(p6_single "${exe}" "${CELLS}" "${STEPS}" "${WARMUP}" 2>&1)"
        else
            out="$(p6_mpirun "${CORES}" "${exe}" "${CELLS}" "${STEPS}" "${WARMUP}" 2>&1)"
        fi
        line="$(grep '^SweepgenLdcCPU variant=' <<< "${out}" || echo "SweepgenLdcCPU_${v} FAILED: $(tail -3 <<< "${out}")")"
        echo "${line}" | tee -a "${RESULTS}"
    done
done

echo
"${PY}" "${HERE}/summary.py" "${CC_NAME} ${PREC} ${CORES}c=${RESULTS}"
rm -f "${RESULTS}"
echo "== done $(date)"
