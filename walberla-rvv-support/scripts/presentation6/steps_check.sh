#!/usr/bin/env bash
# presentation6: can the timed runs be shorter than 200 steps without more noise? (presentation5's steps_check.sh
# on the machine profile of machine.sh.) presentation5 found 60 steps enough on the K1; a faster machine (monte3)
# finishes 60 steps sooner, so the check has to be repeated there.
#
# Times the verified executables of prepare.sh (sha256 checked against the verify logs, nothing is built) with
# STEP_LIST timed steps, interleaved: in every round each build runs once per step count, and the order of the
# step counts rotates from round to round. Compare, per build: the median MLUP/s of each step count against the
# 200-step median (the per-step cost must not change), and the spread (max - min) / median over the rounds (must
# not grow). steps_table.py prints both.
#
# Builds (compiler: GCC): one core (core CPU): plain scalar, best scalar (scalar_cse_aa), and RVV in place +
# prefetch and RVV split loop where the explicit variants run, else best autovec (autovec_cse_aa); f32 and f64.
# All cores of the profile (the last of CORE_LIST; bananapi 8): f64 plain scalar, and RVV CSE and RVV in place +
# prefetch, else best autovec.
#
# bananapi, detached (about 45 min):
#   cd /home/bananapi/saleh/my-e4-ws && mkdir -p ../presentation6/logs && screen -dmS presentation6-steps \
#       bash -c "bash scripts/presentation6/steps_check.sh > ../presentation6/logs/steps.log 2>&1"
# monte3: part "steps" of all.sh, through peak.sbatch
# Environment: ROUNDS=4 STEP_LIST="200 60 30" WARMUP=10 CELLS=64 CPU=2 CC_NAME=gcc
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
ROUNDS="${ROUNDS:-4}"
STEP_LIST="${STEP_LIST:-200 60 30}"
WARMUP="${WARMUP:-10}"
CELLS="${CELLS:-64}"
CC_NAME="${CC_NAME:-gcc}"
mkdir -p "${LOGDIR}"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"

p6_wait_turn presentation6-steps
echo "== start $(date), rounds ${ROUNDS}, steps ${STEP_LIST}, warm-up ${WARMUP}, ${CELLS}^3 cells per core"
p6_profile
env_record

check_verified() {   # check_verified <prec> <exe>: the executable is one that prepare.sh verified
    local h; h="$(sha256sum "$2" | cut -c1-16)"
    p6_in_verify_log "${BUILD_ROOT}/logs/verify-${CC_NAME}-$1.log" "${h}" "$2" \
        && echo "   verified ${h} $2" || { echo "ABORT: NOT VERIFIED ${h} $2"; exit 1; }
}

#   configurations: <cores>:<prec>:<variant>
if [[ "${EXPLICIT_OK}" == 1 ]]; then one="explicit_cse_aa_pf explicit_cse_aa_split"; many="explicit_cse explicit_cse_aa_pf"
else one="autovec_cse_aa"; many="autovec_cse_aa"; fi
MAXC="${CORE_LIST##* }"
CONFIGS=""
for prec in f32 f64; do
    for v in scalar scalar_cse_aa ${one}; do CONFIGS+=" 1:${prec}:${v}"; done
done
(( MAXC > 1 )) && for v in scalar ${many}; do CONFIGS+=" ${MAXC}:f64:${v}"; done
for c in ${CONFIGS}; do IFS=: read -r cores prec v <<< "${c}"; check_verified "${prec}" "$(p6_exe "${CC_NAME}" "${prec}" "${v}")"; done

read -r -a steps_arr <<< "${STEP_LIST}"
n="${#steps_arr[@]}"
LOG="${LOGDIR}/steps-runs.log"; : > "${LOG}"
for round in $(seq 1 "${ROUNDS}"); do
    echo "== round ${round} $(date +%T): $(busy_cores)"
    for c in ${CONFIGS}; do
        IFS=: read -r cores prec v <<< "${c}"
        exe="$(p6_exe "${CC_NAME}" "${prec}" "${v}")"
        for k in $(seq 0 $((n - 1))); do
            steps="${steps_arr[$(( (k + round - 1) % n ))]}"
            t0="$(date +%s%N)"
            if [[ "${cores}" == 1 ]]; then
                out="$(p6_single "${exe}" "${CELLS}" "${steps}" "${WARMUP}" 2>&1)"
            else
                out="$(p6_mpirun "${cores}" "${exe}" "${CELLS}" "${steps}" "${WARMUP}" 2>&1)"
            fi
            wall="$(awk -v a="${t0}" -v b="$(date +%s%N)" 'BEGIN {printf "%.3f", (b - a) / 1e9}')"
            line="$(grep '^SweepgenLdcCPU variant=' <<< "${out}" || echo "FAILED: $(tail -3 <<< "${out}")")"
            echo "round=${round} cores=${cores} cc=${CC_NAME} wall=${wall} ${line}" | tee -a "${LOG}"
        done
    done
done
echo "== end of runs $(date)"
env_record
"${PY}" "${HERE}/steps_table.py" "${LOG}"
echo "== STEPS DONE $(date)"
