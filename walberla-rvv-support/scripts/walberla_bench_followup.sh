#!/usr/bin/env bash
# Follow-up after walberla_bench_all.sh: rerun the configurations whose builds failed in
# the first pass, then print the combined summary again and run the multi-core runs
# (walberla_bench_mpi.sh).
#
# Why: both Clang configurations failed in the first pass.
#   - clang-f64: waLBerla's v8 halo exchange header deduced the arguments of an alias
#     template (C++20), which Clang 18 does not implement. Fixed in GenericFieldPackInfos.hpp.
#   - clang-f32: the benchmark app narrowed double to float in a braced initializer, which
#     GCC only warns about. Fixed in SweepgenLbmCPU.cpp.
# The build dirs are reused, so the waLBerla core libraries are not rebuilt.
#
# Start detached:
#   cd /home/bananapi/saleh && screen -dmS walberla-followup bash -c \
#       "bash my-e4-ws/scripts/walberla_bench_followup.sh > walberla-followup.log 2>&1"
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(dirname "${REPO}")"
RERUN="${RERUN:-clang-f64 clang-f32}"

#   Never compete with the main chain for the CPU
while screen -ls | grep -q '\.walberla-all\s'; do sleep 60; done
echo "== start $(date)"

for name in ${RERUN}; do
    echo "== rerun ${name} $(date)"
    WALBERLA_BUILD="${BASE}/walberla-build-${name}" bash "${REPO}/scripts/walberla_lbm_bench.sh" 64 200 3 \
        > "${BASE}/walberla-bench-${name}.log" 2>&1
    tail -12 "${BASE}/walberla-bench-${name}.log"
done

echo
python "${REPO}/scripts/walberla_bench_summary.py" \
    "gcc-f64=${BASE}/walberla-bench.log" \
    "clang-f64=${BASE}/walberla-bench-clang-f64.log" \
    "gcc-f32=${BASE}/walberla-bench-gcc-f32.log" \
    "clang-f32=${BASE}/walberla-bench-clang-f32.log"

echo
echo "== multi-core runs $(date)"
bash "${REPO}/scripts/walberla_bench_mpi.sh"
echo "== FOLLOWUP DONE $(date)"
