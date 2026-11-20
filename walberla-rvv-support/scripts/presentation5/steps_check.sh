#!/usr/bin/env bash
# presentation5: can the timed runs be shorter than 200 steps without more noise?
#
# The presentation4 timing matrix (all.sh) runs 64^3 cells per core, 10 warm-up steps + 200 timed steps, best
# of 3 runs; its slowest experiment (RVV, f64, 8 cores: 5 builds x 3 runs) takes 15 min. About 60 steps would
# bring it to about 5 min. This job times the same verified presentation4 executables (sha256 checked against
# prepare.sh's verify logs, nothing is built) with STEP_LIST timed steps, interleaved: in every round each build
# runs once per step count, and the order of the step counts rotates from round to round.
#
# Compare, per build: the median MLUP/s of each step count against the 200-step median (the per-step cost must
# not change), and the spread (max - min) / median over the rounds (must not grow). steps_table.py prints both.
#
# Builds: GCC, one core (core CPU): plain scalar, best scalar (scalar_cse_aa), RVV in place + prefetch, RVV
# split loop, f32 and f64; 8 cores (MPI): f64 plain scalar, RVV CSE, RVV in place + prefetch (the builds of
# the slowest presentation4 experiments).
#
# Start on the board, detached (about 45 min):
#   cd /home/bananapi/saleh/my-e4-ws && mkdir -p ../presentation5/logs && screen -dmS presentation5-steps \
#       bash -c "bash scripts/presentation5/steps_check.sh > ../presentation5/logs/steps.log 2>&1"
# Environment: ROUNDS=4 STEP_LIST="200 60 30" WARMUP=10 CELLS=64 CPU=2
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
OUT="${OUT:-${BASE}/presentation5/logs}"
ROUNDS="${ROUNDS:-4}"
STEP_LIST="${STEP_LIST:-200 60 30}"
WARMUP="${WARMUP:-10}"
CELLS="${CELLS:-64}"
CPU="${CPU:-2}"
mkdir -p "${OUT}"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"

#   No other timing job may run at the same time (timing noise)
while screen -ls 2>/dev/null | grep -E "presentation4|notes5|presentation5" | grep -v presentation5-steps | grep -q .; do
    echo "waiting for: $(screen -ls | grep -E 'presentation4|notes5|presentation5' | grep -v presentation5-steps)"; sleep 30
done
echo "== start $(date), rounds ${ROUNDS}, steps ${STEP_LIST}, warm-up ${WARMUP}, ${CELLS}^3 cells per core"
env_record

exe_of() {   # exe_of <cc> <prec> <variant>
    local tree="build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"
    echo "${P4DIR}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"
}
check_verified() {   # check_verified <cc> <prec> <exe>: the executable is one that prepare.sh verified
    local h; h="$(sha256sum "$3" | cut -c1-16)"
    awk -v h="${h}" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4DIR}/logs/verify-$1-$2.log" \
        && echo "   verified ${h} $3" || { echo "ABORT: NOT VERIFIED ${h} $3"; exit 1; }
}

#   configurations: <cores>:<cc>:<prec>:<variant>
CONFIGS=""
for prec in f32 f64; do
    for v in scalar scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do CONFIGS+=" 1:gcc:${prec}:${v}"; done
done
for v in scalar explicit_cse explicit_cse_aa_pf; do CONFIGS+=" 8:gcc:f64:${v}"; done
for c in ${CONFIGS}; do IFS=: read -r cores cc prec v <<< "${c}"; check_verified "${cc}" "${prec}" "$(exe_of "${cc}" "${prec}" "${v}")"; done

read -r -a steps_arr <<< "${STEP_LIST}"
n="${#steps_arr[@]}"
LOG="${OUT}/steps-runs.log"; : > "${LOG}"
for round in $(seq 1 "${ROUNDS}"); do
    echo "== round ${round} $(date +%T): $(busy_cores)"
    for c in ${CONFIGS}; do
        IFS=: read -r cores cc prec v <<< "${c}"
        exe="$(exe_of "${cc}" "${prec}" "${v}")"
        for k in $(seq 0 $((n - 1))); do
            steps="${steps_arr[$(( (k + round - 1) % n ))]}"
            t0="$(date +%s.%N)"
            if [[ "${cores}" == 1 ]]; then
                out="$(taskset -c "${CPU}" "${exe}" "${CELLS}" "${steps}" "${WARMUP}" 2>&1)"
            else
                out="$(mpirun -np "${cores}" --bind-to core --map-by core "${exe}" "${CELLS}" "${steps}" "${WARMUP}" 2>&1)"
            fi
            wall="$(echo "$(date +%s.%N) - ${t0}" | bc)"
            line="$(grep '^SweepgenLdcCPU variant=' <<< "${out}" || echo "FAILED: $(tail -3 <<< "${out}")")"
            echo "round=${round} cores=${cores} cc=${cc} wall=${wall} ${line}" | tee -a "${LOG}"
        done
    done
done
echo "== end of runs $(date)"
env_record
python3 "${HERE}/steps_table.py" "${LOG}"
echo "== STEPS DONE $(date)"
