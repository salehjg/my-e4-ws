#!/usr/bin/env bash
# presentation6: the whole-program timing matrix of presentation5 on the machine profile of machine.sh:
# {scalar, autovec, rvv} x COMPILERS x {f32, f64} x CORE_LIST, with run.sh's protocol (60 timed steps, variants
# interleaved, machine state recorded), plus part "share": the fair pair of the slide "What the vectors
# themselves add" (best scalar and the two fastest RVV builds, rho and u written only in the last step and in
# every step, interleaved), one core. The rvv group and part share need the explicit variants, so they are
# skipped where machine.sh says these cannot run (VLEN below pystencils' RVV_VLEN).
# Times the verified executables of prepare.sh; builds nothing.
#   bananapi (GCC and Clang, 1/4/8 cores): about 1 h 45 min, share about 15 min (presentation5's estimate)
#   monte3: not measured yet
#
# bananapi, detached:
#   cd /home/bananapi/saleh/my-e4-ws && mkdir -p ../presentation6/logs && screen -dmS presentation6-matrix \
#       bash -c "bash scripts/presentation6/matrix.sh > ../presentation6/logs/matrix.log 2>&1"
# monte3: part "matrix" of all.sh, through peak.sbatch
# Environment: PARTS="matrix share", LOGDIR (machine.sh), CORE_LIST, COMPILERS, and run.sh's (STEPS, ROUNDS, ...)
# Logs: LOGDIR/ldc-<cc>-<scalar|autovec|rvv>-<prec>-<cores>core.log, LOGDIR/share-<cc>-<prec>-<every|last>.log
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
PARTS="${PARTS:-matrix share}"
mkdir -p "${LOGDIR}"

declare -A GROUP=([scalar]="${SCALAR_VARIANTS}" [autovec]="${AUTOVEC_VARIANTS}" [rvv]="${EXPLICIT_VARIANTS}")
EXPS="scalar autovec"; [[ "${EXPLICIT_OK}" == 1 ]] && EXPS+=" rvv"
p6_wait_turn presentation6-matrix
echo "== start $(date), parts: ${PARTS}"
p6_profile
[[ "${EXPLICIT_OK}" == 1 ]] || echo "== group rvv and part share skipped: explicit variants need VLEN >= ${RVV_VLEN}, this machine has ${VLEN}"

if [[ " ${PARTS} " == *" matrix "* ]]; then
    labels=()
    for cc in ${COMPILERS}; do
        for prec in f32 f64; do
            for cores in ${CORE_LIST}; do
                for exp in ${EXPS}; do
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
    "${PY}" "${HERE}/summary.py" "${labels[@]}"
fi

if [[ " ${PARTS} " == *" share "* && "${EXPLICIT_OK}" == 1 ]]; then
    labels=()
    for cc in ${COMPILERS}; do
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
    "${PY}" "${HERE}/summary.py" "${labels[@]}"
fi
echo "== MATRIX DONE $(date)"
