#!/usr/bin/env bash
# Unattended end-to-end waLBerla benchmark matrix on the board (runs for hours):
#
#   {GCC, Clang} x {f64, f32}, each in its own waLBerla build dir (the precision is a waLBerla
#   build option, WALBERLA_DOUBLE_ACCURACY), each with the six SweepgenLbmCPU executables
#   built and run by walberla_lbm_bench.sh: scalar / autovec / explicit RVV, each with and
#   without lbmpy's global CSE.
#
# After the benchmarks (so they do not disturb the timings): waLBerla's own LBM scenario
# tests in the GCC f64 build dir, a correctness check of the plain waLBerla-on-K1 path
# (Target.CurrentCPU = RISCV_RVV, not vectorized). Then a combined summary.
#
# Start it detached, so it survives a lost connection or a laptop shutdown:
#   cd /home/bananapi/saleh && screen -dmS walberla-all bash -c \
#       "bash my-e4-ws/scripts/walberla_bench_all.sh > walberla-all.log 2>&1"
# Results: /home/bananapi/saleh/walberla-bench*.log; summary at the end of walberla-all.log.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$(dirname "${REPO}")"                 # /home/bananapi/saleh: we only write here
VENV="${VENV:-${BASE}/venv}"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-200}"
REPS="${REPS:-3}"

export PATH="${VENV}/bin:${PATH}"
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
export XDG_CACHE_HOME="${BASE}/.cache"

echo "== start $(date)"

#   0. A GCC f64 run may still be going (screen session walberla-bench): wait for it, so
#      the two never compete for the CPU.
while screen -ls | grep -q '\.walberla-bench\s'; do sleep 60; done
echo "== GCC f64 run finished $(date)"

#   Configure a fresh build dir once. Only what the benchmark needs is enabled.
configure() {   # configure <build dir> <C compiler> <C++ compiler> <WALBERLA_DOUBLE_ACCURACY>
    [[ -f "$1/CMakeCache.txt" ]] && return 0
    cmake -S "${REPO}/submodules/walberla" -B "$1" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$2" -DCMAKE_CXX_COMPILER="$3" \
        -DWALBERLA_DOUBLE_ACCURACY="$4" \
        -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON \
        -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF -DPython_EXECUTABLE="${VENV}/bin/python" \
        -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
        -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS=OFF -DWALBERLA_BUILD_TOOLS=OFF \
        -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF \
        -DWALBERLA_BUILD_SHOWCASES=OFF -DWALBERLA_BUILD_DOC=OFF \
        > "$1.configure.log" 2>&1
}

#   1. The other three configurations, one after another
for cfg in "clang-f64 clang clang++ ON" "gcc-f32 gcc g++ OFF" "clang-f32 clang clang++ OFF"; do
    read -r name cc cxx dbl <<< "${cfg}"
    dir="${BASE}/walberla-build-${name}"
    echo "== ${name}: configure $(date)"
    if ! configure "${dir}" "${cc}" "${cxx}" "${dbl}"; then
        echo "CONFIGURE FAILED ${name}"; tail -20 "${dir}.configure.log"; continue
    fi
    echo "== ${name}: build + run $(date)"
    WALBERLA_BUILD="${dir}" bash "${REPO}/scripts/walberla_lbm_bench.sh" "${CELLS}" "${STEPS}" "${REPS}" \
        > "${BASE}/walberla-bench-${name}.log" 2>&1
    tail -12 "${BASE}/walberla-bench-${name}.log"
done

#   2. waLBerla's own LBM scenario tests (GCC f64 build dir, which has the tests enabled)
echo "== LbmScenarios test $(date)"
{
    cmake --build "${BASE}/walberla-build" --target TestLbmScenarios_CXX -j 2 \
        && cd "${BASE}/walberla-build" && ctest -R TestLbmScenarios --output-on-failure
    echo "== LbmScenarios exit $?"
} > "${BASE}/walberla-lbmscenarios.log" 2>&1
tail -15 "${BASE}/walberla-lbmscenarios.log"

#   3. Combined summary
echo
python "${REPO}/scripts/walberla_bench_summary.py" \
    "gcc-f64=${BASE}/walberla-bench.log" \
    "clang-f64=${BASE}/walberla-bench-clang-f64.log" \
    "gcc-f32=${BASE}/walberla-bench-gcc-f32.log" \
    "clang-f32=${BASE}/walberla-bench-clang-f32.log"
echo "== ALL DONE $(date)"
