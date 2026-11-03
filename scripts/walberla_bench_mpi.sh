#!/usr/bin/env bash
# Multi-core end-to-end runs of the SweepgenLbmCPU executables, after the single-core
# matrix (walberla_bench_all.sh) has finished. Production waLBerla runs use all cores. The
# cores share the memory bandwidth, so the vectorization gain can differ from one core.
#
# For every configuration's build dir, each of the six executables runs with NP MPI
# processes (one CELLS^3 block per process, ranks bound to cores 0..NP-1) for NP in NPS.
# The K1 has 8 cores in two clusters of 4: NP=4 is one cluster, NP=8 the whole chip.
#
# Start detached:
#   cd /home/bananapi/saleh && screen -dmS walberla-mpi bash -c \
#       "bash my-e4-ws/scripts/walberla_bench_mpi.sh > walberla-mpi.log 2>&1"
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(dirname "${REPO}")"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-100}"
REPS="${REPS:-2}"
NPS="${NPS:-4 8}"
export PATH="${VENV:-${BASE}/venv}/bin:${PATH}"

#   Never compete with the single-core matrix for the CPU
while screen -ls | grep -q '\.walberla-all\s'; do sleep 60; done
echo "== start $(date)"

for np in ${NPS}; do
    labels=()
    for cfg in "walberla-build gcc-f64" "walberla-build-clang-f64 clang-f64" \
               "walberla-build-gcc-f32 gcc-f32" "walberla-build-clang-f32 clang-f32"; do
        read -r dir name <<< "${cfg}"
        appdir="${BASE}/${dir}/apps/benchmarks/SweepgenLbmCPU"
        log="${BASE}/walberla-mpi-np${np}-${name}.log"
        : > "${log}"
        for v in scalar scalar_cse autovec autovec_cse explicit explicit_cse; do
            exe="${appdir}/SweepgenLbmCPU_${v}"
            [[ -x "${exe}" ]] || continue
            for r in $(seq 1 "${REPS}"); do
                mpirun -np "${np}" --bind-to core --map-by core "${exe}" "${CELLS}" "${STEPS}" 10 2>&1 \
                    | grep '^SweepgenLbmCPU' >> "${log}"
            done
        done
        labels+=("${name}=${log}")
        echo "== np=${np} ${name} done $(date +%T)"
    done
    echo
    echo "### ${np} MPI processes, ${CELLS}^3 cells per process, ${STEPS} steps"
    python "${REPO}/scripts/walberla_bench_summary.py" "${labels[@]}"
    echo
done
echo "== ALL DONE $(date)"
