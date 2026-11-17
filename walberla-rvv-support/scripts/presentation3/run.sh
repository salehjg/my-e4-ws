#!/usr/bin/env bash
# Build some SweepgenLbmCPU variants (submodules/walberla/apps/benchmarks/SweepgenLbmCPU) and time
# them on the board, on one core or on several cores with MPI. Called by the three experiment
# scripts {scalar,autovec,rvv}.sh next to this one, which only choose the variants.
#
# Usage: bash scripts/presentation3/run.sh <f32|f64> <cores> <variant>...
#   cores = 1   one process, pinned to core CPU (default 2)
#   cores > 1   that many MPI processes, one per core (4 = one cluster of the K1, 8 = the whole chip)
# Every process gets its own CELLS^3 block, so the total work grows with the core count.
#
# Environment (defaults reproduce the slides): CELLS=64 STEPS=200 REPS=3 CPU=2 JOBS=2
#   REGEN=1   delete the variants' generated sources first. Make does not see changes in
#             pystencils or sweepgen, so set it after changing either.
#   SWEEPGEN_LBM_OUTPUT=last   is passed through to the app (no density/velocity output
#             except in the last step; the default writes them every step).
#
# Build dirs (GCC, configured on first use): f64 -> ../walberla-build, f32 -> ../walberla-build-gcc-f32
# Prints one result line per run, then a table with the best of REPS runs per variant.
set -u

PREC="$1"; CORES="$2"; shift 2
VARIANTS="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"                 # /home/bananapi/saleh on the board: we only write here
VENV="${VENV:-${BASE}/venv}"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-200}"
REPS="${REPS:-3}"
CPU="${CPU:-2}"
#   -j2: the heaviest waLBerla translation units need ~1.3 GB each, the board has 3.7 GB
JOBS="${JOBS:-2}"

case "${PREC}" in
    f64) BUILD="${BASE}/walberla-build";         DOUBLE=ON ;;
    f32) BUILD="${BASE}/walberla-build-gcc-f32"; DOUBLE=OFF ;;
    *)   echo "usage: $0 <f32|f64> <cores> <variant>..."; exit 1 ;;
esac
APPDIR="${BUILD}/apps/benchmarks/SweepgenLbmCPU"

export PATH="${VENV}/bin:${PATH}"
#   Code generation uses our pystencils and sweepgen from this repo
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
#   lbmpy/pystencils caches stay in our folder: the board is shared
export XDG_CACHE_HOME="${BASE}/.cache"

echo "== ${PREC}, ${CORES} core(s), ${CELLS}^3 cells per core, ${STEPS} steps, ${REPS} runs: ${VARIANTS}"
echo "== start $(date), load: $(cut -d' ' -f1-3 /proc/loadavg)"
echo "== build dir ${BUILD}"

#   The board's clock is behind the laptop's: files synced from the laptop can be "in the
#   future", and make would then rebuild them on every call. Give them the current time.
find "${REPO}/submodules" -newermt now -exec touch -c {} + 2>/dev/null

if [[ ! -f "${BUILD}/CMakeCache.txt" ]]; then
    echo "== configure ${BUILD}"
    cmake -S "${REPO}/submodules/walberla" -B "${BUILD}" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
        -DWALBERLA_DOUBLE_ACCURACY="${DOUBLE}" \
        -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON \
        -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF -DPython_EXECUTABLE="${VENV}/bin/python" \
        -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
        -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS=OFF -DWALBERLA_BUILD_TOOLS=OFF \
        -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF \
        -DWALBERLA_BUILD_SHOWCASES=OFF -DWALBERLA_BUILD_DOC=OFF > "${BUILD}.configure.log" 2>&1 \
        || { echo "CONFIGURE FAILED"; tail -20 "${BUILD}.configure.log"; exit 1; }
fi
#   Re-run cmake so that new targets in the app's CMakeLists.txt are known
cmake "${BUILD}" > "${BUILD}/configure.log" 2>&1 || { echo "CONFIGURE FAILED"; tail -20 "${BUILD}/configure.log"; exit 1; }

for v in ${VARIANTS}; do
    t="SweepgenLbmCPU_${v}"
    [[ "${REGEN:-0}" == 1 ]] && rm -f "${APPDIR}/_gen/${t}/gen/SweepgenLbmCPU."{cpp,hpp}
    echo "== build ${t} $(date +%T)"
    cmake --build "${BUILD}" --target "${t}" -j "${JOBS}" > "${BUILD}/build-${t}.log" 2>&1 \
        || { echo "BUILD FAILED ${t}"; grep -m20 -E "error|Error" "${BUILD}/build-${t}.log"; }
    #   Vector instructions in the generated sweeps: none in scalar, some in autovec and rvv.
    #   llvm-objdump, because GNU objdump 2.42 cannot decode Clang's RVV code.
    obj="$(find "${APPDIR}/CMakeFiles/${t}.dir" -name 'SweepgenLbmCPU.cpp.o' -path '*_gen*' 2>/dev/null | head -1)"
    [[ -n "${obj}" ]] && echo "   RVV instructions in the sweeps: $(llvm-objdump -d --no-show-raw-insn "${obj}" | awk '$2 ~ /^v/ {n++} END {print n+0}')"
done

echo "== run $(date)"
RESULTS="$(mktemp)"
for v in ${VARIANTS}; do
    exe="${APPDIR}/SweepgenLbmCPU_${v}"
    [[ -x "${exe}" ]] || { echo "SweepgenLbmCPU_${v}: missing"; continue; }
    for r in $(seq 1 "${REPS}"); do
        if [[ "${CORES}" == 1 ]]; then
            out="$(taskset -c "${CPU}" "${exe}" "${CELLS}" "${STEPS}" 10 2>&1)"
        else
            out="$(mpirun -np "${CORES}" --bind-to core --map-by core "${exe}" "${CELLS}" "${STEPS}" 10 2>&1)"
        fi
        line="$(grep '^SweepgenLbmCPU variant=' <<< "${out}" || echo "SweepgenLbmCPU_${v} FAILED: $(tail -3 <<< "${out}")")"
        echo "${line}" | tee -a "${RESULTS}"
    done
done

echo
python "${REPO}/scripts/common/walberla_summary.py" "${PREC}, ${CORES} core(s)=${RESULTS}"
rm -f "${RESULTS}"
echo "== done $(date)"
