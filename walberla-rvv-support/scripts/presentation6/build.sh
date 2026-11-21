#!/usr/bin/env bash
# presentation6: configure and build some SweepgenLdcCPU variants (submodules/walberla/apps/benchmarks/SweepgenLdcCPU)
# on this machine, and record each one's compile flags and vector-instruction counts. The build half of
# scripts/presentation4/run.sh; timing is run.sh's job. prepare.sh calls it, then audits and verifies.
#
# Usage: bash scripts/presentation6/build.sh <gcc|clang> <f32|f64> <variant>...
#
# Build trees, configured on first use, under BUILD_ROOT (default <base>/presentation6):
#   build-<compiler>-<precision>          the autovec and explicit variants. -O3; the -march is waLBerla's own
#                                         (rv64gcv_zvl256b, plus -mtune=<vendor>-<core> if the compiler accepts
#                                         it) when VLEN is 256, as in presentation4; at any other VLEN machine.sh's
#                                         VECTOR_FLAGS put -march=rv64gcv_zvl<VLEN>b after waLBerla's flags
#   build-<compiler>-<precision>-scalar   every file (waLBerla's libraries too) with -march=rv64gc: the scalar
#                                         variants, so the scalar executables contain no vector instruction
# Explicit variants are refused where they would give wrong results (VLEN < pystencils' RVV_VLEN, machine.sh).
#
# Environment: JOBS (machine.sh: bananapi 2, monte3 by memory), REGEN=1 (delete the variants' generated sources
#   first: make does not see pystencils/sweepgen changes), TREE_KIND=vector (scalar variants in the vector tree)
set -u
CC_NAME="$1"; PREC="$2"; shift 2
VARIANTS="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"

case "${CC_NAME}" in
    gcc)   CC=gcc;   CXX=g++ ;;
    clang) CC=clang; CXX=clang++ ;;
    *)     echo "usage: $0 <gcc|clang> <f32|f64> <variant>..."; exit 1 ;;
esac
case "${PREC}" in
    f64) DOUBLE=ON ;;
    f32) DOUBLE=OFF ;;
    *)   echo "usage: $0 <gcc|clang> <f32|f64> <variant>..."; exit 1 ;;
esac

export PATH="${VENV}/bin:${PATH}"
#   Code generation uses our pystencils and sweepgen from this repo
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
#   lbmpy/pystencils caches stay in our folder: the machines are shared
export XDG_CACHE_HOME="${BASE}/.cache"

p6_profile
echo "== build ${CC_NAME} ${PREC}: ${VARIANTS}"
echo "== start $(date), host $(hostname), load: $(cut -d' ' -f1-3 /proc/loadavg)"
echo "== $("${CXX}" --version | head -1); $(cmake --version | head -1)"
for v in ${VARIANTS}; do
    p6_supported "${v}" || { echo "BUILD REFUSED ${v}: explicit variants need VLEN >= ${RVV_VLEN}, this machine has ${VLEN}"; exit 1; }
done

#   A board clock behind the laptop's makes synced files "in the future", and make would then rebuild them
#   on every call. Give them the current time.
find "${REPO}/submodules" "${REPO}/scripts" -newermt now -exec touch -c {} + 2>/dev/null

tree_of() {   # tree_of <variant>: the build tree of a variant (TREE_KIND=vector: always the vector tree)
    if [[ "$1" == scalar* && "${TREE_KIND:-}" != vector ]]; then echo "${BUILD_ROOT}/build-${CC_NAME}-${PREC}-scalar"
    else echo "${BUILD_ROOT}/build-${CC_NAME}-${PREC}"; fi
}

configure() {   # configure <tree> <scalar|vector>
    local tree="$1" kind="$2" extra=()
    if [[ "${kind}" == scalar ]]; then
        #   CMAKE_<LANG>_FLAGS_RELEASE come after waLBerla's CMAKE_<LANG>_FLAGS on every compile line,
        #   so this -march=rv64gc wins over waLBerla's -march in every file
        extra=(-DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc" -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc")
    else
        (( VLEN > 0 )) || { echo "CONFIGURE FAILED ${tree}: VLEN not known (run setup.sh)"; return 1; }
        extra=("${VECTOR_FLAGS[@]}")
    fi
    #   link-time library search (machine.sh): the generated code and the compile lines do not change
    [[ -n "${LINK_FLAGS}" ]] && extra+=(-DCMAKE_EXE_LINKER_FLAGS="${LINK_FLAGS}" -DCMAKE_SHARED_LINKER_FLAGS="${LINK_FLAGS}")
    if [[ ! -f "${tree}/CMakeCache.txt" ]]; then
        echo "== configure ${tree} (${CC_NAME}, ${PREC}, ${kind}${extra[*]:+, ${extra[*]}})"
        mkdir -p "${BUILD_ROOT}"
        cmake -S "${REPO}/submodules/walberla" -B "${tree}" \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" "${extra[@]}" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DWALBERLA_DOUBLE_ACCURACY="${DOUBLE}" \
            -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON \
            -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF -DPython_EXECUTABLE="${PY}" \
            -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
            -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS=OFF -DWALBERLA_BUILD_TOOLS=OFF \
            -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF \
            -DWALBERLA_BUILD_SHOWCASES=OFF -DWALBERLA_BUILD_DOC=OFF > "${tree}.configure.log" 2>&1 \
            || { echo "CONFIGURE FAILED ${tree}"; tail -20 "${tree}.configure.log"; return 1; }
    fi
    #   Re-run cmake so that new targets in the app's CMakeLists.txt are known
    cmake "${tree}" > "${tree}/configure.log" 2>&1 || { echo "CONFIGURE FAILED ${tree}"; tail -20 "${tree}/configure.log"; return 1; }
}

declare -A configured=()
for v in ${VARIANTS}; do
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
    "${PY}" - "${tree}/compile_commands.json" "${t}" <<'EOF'
import json, sys
for e in json.load(open(sys.argv[1])):
    if f"_gen/{sys.argv[2]}/gen/SweepgenLdcCPU.cpp" in e["file"]:
        cmd = e.get("command") or " ".join(e["arguments"])
        print("   compile:", " ".join(a for a in cmd.split() if a.startswith(("-O", "-march", "-mtune", "-f", "-std"))))
EOF
    #   Vector instructions: the whole executable (scalar must be 0) and the generated sweeps' object.
    #   llvm-objdump where there is one: GNU objdump 2.42 cannot decode Clang's RVV code.
    exe="${appdir}/${t}"
    obj="$(find "${appdir}/CMakeFiles/${t}.dir" -name 'SweepgenLdcCPU.cpp.o' -path '*_gen*' 2>/dev/null | head -1)"
    nexe="$("${OBJDUMP}" -d --no-show-raw-insn "${exe}" | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    nobj="$( [[ -n "${obj}" ]] && "${OBJDUMP}" -d --no-show-raw-insn "${obj}" | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    echo "   RVV instructions: executable ${nexe}, generated sweeps ${nobj:-?}"
done
echo "== build done $(date)"
