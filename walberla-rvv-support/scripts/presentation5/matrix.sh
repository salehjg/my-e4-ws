#!/usr/bin/env bash
# presentation5: the whole-program timing matrix of presentation4 (scripts/presentation4/all.sh, part matrix)
# with the presentation5 protocol of run.sh: 60 timed steps, variants interleaved, board state recorded.
# Same experiments as presentation4: {scalar, autovec, rvv} x {gcc, clang} x {f32, f64} x {1, 4, 8} cores, plus
# part "share": the fair pair of the slide "What the vectors themselves add" (best scalar and the two fastest RVV
# builds with rho and u written only in the last step, and every step, interleaved), one core.
# Times the verified presentation4 executables; builds nothing. The slowest experiment (rvv f64 8 cores) takes
# about 5 min, the whole matrix about 1 h 45 min, "share" about 15 min.
#
# Start on the board, detached:
#   cd /home/bananapi/saleh/my-e4-ws && mkdir -p ../presentation5/logs && screen -dmS presentation5-matrix \
#       bash -c "bash scripts/presentation5/matrix.sh > ../presentation5/logs/matrix.log 2>&1"
# Environment: PARTS="matrix share" LOGDIR=<base>/presentation5/logs, and run.sh's (STEPS, ROUNDS, ...).
# Logs: LOGDIR/ldc-<cc>-<scalar|autovec|rvv>-<prec>-<cores>core.log, LOGDIR/share-<cc>-<prec>-<every|last>.log
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
VENV="${VENV:-${BASE}/venv}"
LOGDIR="${LOGDIR:-${BASE}/presentation5/logs}"
PARTS="${PARTS:-matrix share}"
mkdir -p "${LOGDIR}"

declare -A GROUP=(
    [scalar]="scalar scalar_cse scalar_cse_aa"
    [autovec]="autovec autovec_cse autovec_cse_aa"
    [rvv]="explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
)
while screen -ls 2>/dev/null | grep -E "presentation4|notes5|presentation5" | grep -v presentation5-matrix | grep -q .; do
    echo "waiting for: $(screen -ls | grep -E 'presentation4|notes5|presentation5' | grep -v presentation5-matrix)"; sleep 30
done
echo "== start $(date), parts: ${PARTS}"

if [[ " ${PARTS} " == *" matrix "* ]]; then
    labels=()
    for cc in gcc clang; do
        for prec in f32 f64; do
            for cores in 1 4 8; do
                for exp in scalar autovec rvv; do
                    log="${LOGDIR}/ldc-${cc}-${exp}-${prec}-${cores}core.log"
                    echo "== ${cc} ${exp} ${prec} ${cores} core(s) $(date +%T) -> ${log}"
                    # shellcheck disable=SC2086
                    bash "${HERE}/run.sh" "${cc}" "${prec}" "${cores}" ${GROUP[${exp}]} > "${log}" 2>&1
                    grep -E "FAILED|ABORTED" "${log}"
                    labels+=("${cc} ${prec} ${cores}c=${log}")
                done
            done
        done
    done
    echo
    "${VENV}/bin/python" "${REPO}/scripts/presentation4/summary.py" "${labels[@]}"
fi

if [[ " ${PARTS} " == *" share "* ]]; then
    labels=()
    for cc in gcc clang; do
        for prec in f32 f64; do
            for mode in every last; do
                log="${LOGDIR}/share-${cc}-${prec}-${mode}.log"
                echo "== share ${cc} ${prec} output ${mode} $(date +%T) -> ${log}"
                if [[ "${mode}" == last ]]; then export SWEEPGEN_LDC_OUTPUT=last; else unset SWEEPGEN_LDC_OUTPUT; fi
                bash "${HERE}/run.sh" "${cc}" "${prec}" 1 scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split > "${log}" 2>&1
                grep -E "FAILED|ABORTED" "${log}"
                labels+=("${cc} ${prec} ${mode}=${log}")
            done
        done
    done
    unset SWEEPGEN_LDC_OUTPUT
    echo
    "${VENV}/bin/python" "${REPO}/scripts/presentation4/summary.py" "${labels[@]}"
fi
echo "== MATRIX DONE $(date)"
