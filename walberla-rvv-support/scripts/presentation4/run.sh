#!/usr/bin/env bash
# Build some SweepgenLdcCPU variants (submodules/walberla/apps/benchmarks/SweepgenLdcCPU) and time them
# on the board, on one core or on several cores with MPI. Called by {scalar,autovec,rvv}.sh next to
# this one, which only choose the variants. Adapted from scripts/presentation3/run.sh (left unchanged).
#
# Usage: bash scripts/presentation4/run.sh <gcc|clang> <f32|f64> <cores> <variant>...
#   cores = 1   one process, pinned to core CPU (default 2)
#   cores > 1   that many MPI processes, one per core (4 = one cluster of the K1, 8 = the whole chip)
# Every process gets its own CELLS^3 block, so the cavity grows with the core count.
#
# Build trees (configured on first use, under P4DIR = <base>/presentation4):
#   build-<compiler>-<precision>          waLBerla's flags for this host (-O3, -march=rv64gcv_zvl256b,
#                                         and -mtune=spacemit-x60 if the compiler accepts it): the
#                                         autovec and explicit variants
#   build-<compiler>-<precision>-scalar   the same, but every file (waLBerla's libraries included) is
#                                         compiled with -march=rv64gc: the scalar variants, so the
#                                         scalar executables contain no vector instruction at all
#
# Environment (defaults = the presentation4 protocol, the same as presentation3's):
#   CELLS=64 STEPS=200 WARMUP=10 REPS=3 CPU=2 JOBS=2
#   REGEN=1       delete the variants' generated sources first (make does not see pystencils/sweepgen changes)
#   TREE_KIND=vector  build and run the scalar variants in the vector tree too (only the app's own
#                 files get -march=rv64gc there, as in presentation3)
#   BUILD_ONLY=1  configure and build, record flags and vector-instruction counts, do not run
#   SKIP_BUILD=1  no cmake, no build: time the executables exactly as they are (all.sh, after
#                 prepare.sh has built and verified them)
#   SWEEPGEN_LDC_OUTPUT=last  passed through to the app (default: rho and u written in every step)
# Prints one result line per run, then a table with the best of REPS runs per variant.
set -u

CC_NAME="$1"; PREC="$2"; CORES="$3"; shift 3
VARIANTS="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"                 # /home/bananapi/saleh on the board: we only write here
P4DIR="${P4DIR:-${BASE}/presentation4}"
VENV="${VENV:-${BASE}/venv}"
CELLS="${CELLS:-64}"
STEPS="${STEPS:-200}"
WARMUP="${WARMUP:-10}"
REPS="${REPS:-3}"
CPU="${CPU:-2}"
#   -j2: the heaviest waLBerla translation units need ~1.3 GB each, the board has 3.7 GB
JOBS="${JOBS:-2}"

case "${CC_NAME}" in
    gcc)   CC=gcc;   CXX=g++ ;;
    clang) CC=clang; CXX=clang++ ;;
    *)     echo "usage: $0 <gcc|clang> <f32|f64> <cores> <variant>..."; exit 1 ;;
esac
case "${PREC}" in
    f64) DOUBLE=ON ;;
    f32) DOUBLE=OFF ;;
    *)   echo "usage: $0 <gcc|clang> <f32|f64> <cores> <variant>..."; exit 1 ;;
esac

export PATH="${VENV}/bin:${PATH}"
#   Code generation uses our pystencils and sweepgen from this repo
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
#   lbmpy/pystencils caches stay in our folder: the board is shared
export XDG_CACHE_HOME="${BASE}/.cache"

tree_of() {   # tree_of <variant>: the build tree of a variant (TREE_KIND=vector: always the vector tree)
    if [[ "$1" == scalar* && "${TREE_KIND:-}" != vector ]]; then echo "${P4DIR}/build-${CC_NAME}-${PREC}-scalar"
    else echo "${P4DIR}/build-${CC_NAME}-${PREC}"; fi
}

configure() {   # configure <tree> <scalar|vector>
    local tree="$1" kind="$2" extra=()
    if [[ "${kind}" == scalar ]]; then
        #   CMAKE_<LANG>_FLAGS_RELEASE come after waLBerla's CMAKE_<LANG>_FLAGS on every compile line,
        #   so this -march=rv64gc wins over waLBerla's -march=rv64gcv_zvl256b in every file
        extra=(-DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc" -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc")
    fi
    if [[ ! -f "${tree}/CMakeCache.txt" ]]; then
        echo "== configure ${tree} (${CC_NAME}, ${PREC}, ${kind})"
        mkdir -p "${P4DIR}"
        cmake -S "${REPO}/submodules/walberla" -B "${tree}" \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" "${extra[@]}" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DWALBERLA_DOUBLE_ACCURACY="${DOUBLE}" \
            -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON \
            -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF -DPython_EXECUTABLE="${VENV}/bin/python" \
            -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
            -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS=OFF -DWALBERLA_BUILD_TOOLS=OFF \
            -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF \
            -DWALBERLA_BUILD_SHOWCASES=OFF -DWALBERLA_BUILD_DOC=OFF > "${tree}.configure.log" 2>&1 \
            || { echo "CONFIGURE FAILED ${tree}"; tail -20 "${tree}.configure.log"; return 1; }
    fi
    #   Re-run cmake so that new targets in the app's CMakeLists.txt are known
    cmake "${tree}" > "${tree}/configure.log" 2>&1 || { echo "CONFIGURE FAILED ${tree}"; tail -20 "${tree}/configure.log"; return 1; }
}

echo "== ${CC_NAME} ${PREC}, ${CORES} core(s), ${CELLS}^3 cells per core, ${STEPS} steps (+${WARMUP} warm-up), ${REPS} runs: ${VARIANTS}"
echo "== start $(date), host $(hostname), load: $(cut -d' ' -f1-3 /proc/loadavg)"
echo "== $("${CXX}" --version | head -1)"

#   The board's clock is behind the laptop's: files synced from the laptop can be "in the
#   future", and make would then rebuild them on every call. Give them the current time.
find "${REPO}/submodules" "${REPO}/scripts" -newermt now -exec touch -c {} + 2>/dev/null

declare -A configured=()
for v in ${VARIANTS}; do
    [[ "${SKIP_BUILD:-0}" == 1 ]] && { echo "== SKIP_BUILD=1: no configure, no build"; break; }
    tree="$(tree_of "${v}")"
    if [[ -z "${configured[${tree}]:-}" ]]; then
        kind=vector; [[ "${tree}" == *-scalar ]] && kind=scalar
        configure "${tree}" "${kind}" || exit 1
        configured[${tree}]=1
    fi
    appdir="${tree}/apps/benchmarks/SweepgenLdcCPU"
    t="SweepgenLdcCPU_${v}"
    [[ "${REGEN:-0}" == 1 ]] && rm -f "${appdir}/_gen/${t}/gen/SweepgenLdcCPU."{cpp,hpp}
    echo "== build ${t} in $(basename "${tree}") $(date +%T)"
    cmake --build "${tree}" --target "${t}" -j "${JOBS}" > "${tree}/build-${t}.log" 2>&1 \
        || { echo "BUILD FAILED ${t}"; grep -m20 -E "error|Error" "${tree}/build-${t}.log"; continue; }
    #   The exact compile line of the generated sweeps (flags evidence: -O3, -march, -mtune)
    "${VENV}/bin/python" - "${tree}/compile_commands.json" "${t}" <<'EOF'
import json, sys
for e in json.load(open(sys.argv[1])):
    if f"_gen/{sys.argv[2]}/gen/SweepgenLdcCPU.cpp" in e["file"]:
        cmd = e.get("command") or " ".join(e["arguments"])
        print("   compile:", " ".join(a for a in cmd.split() if a.startswith(("-O", "-march", "-mtune", "-f", "-std"))))
EOF
    #   Vector instructions: the whole executable (scalar must be 0) and the generated sweeps' object.
    #   llvm-objdump, because GNU objdump 2.42 cannot decode Clang's RVV code.
    exe="${appdir}/${t}"
    obj="$(find "${appdir}/CMakeFiles/${t}.dir" -name 'SweepgenLdcCPU.cpp.o' -path '*_gen*' 2>/dev/null | head -1)"
    nexe="$(llvm-objdump -d --no-show-raw-insn "${exe}" | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    nobj="$( [[ -n "${obj}" ]] && llvm-objdump -d --no-show-raw-insn "${obj}" | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    echo "   RVV instructions: executable ${nexe}, generated sweeps ${nobj:-?}"
done

[[ "${BUILD_ONLY:-0}" == 1 ]] && { echo "== build only, done $(date)"; exit 0; }

echo "== run $(date)"
RESULTS="$(mktemp)"
for v in ${VARIANTS}; do
    exe="$(tree_of "${v}")/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"
    [[ -x "${exe}" ]] || { echo "SweepgenLdcCPU_${v}: missing"; continue; }
    #   The executable's checksum ties these timings to the verified binary (verify.sh prints it too)
    echo "   sha256 $(sha256sum "${exe}" | cut -c1-16) ${exe}"
    for r in $(seq 1 "${REPS}"); do
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
"${VENV}/bin/python" "${HERE}/summary.py" "${CC_NAME} ${PREC} ${CORES}c=${RESULTS}"
rm -f "${RESULTS}"
echo "== done $(date)"
