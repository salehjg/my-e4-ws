#!/usr/bin/env bash
# Configure and build SweepgenLdcCPU on the local x86 machine (docs/presentation4, stage 1 checks and the film).
#
# Usage: bash scripts/presentation4/build_x86.sh <gcc|clang> <f32|f64> [target ...]
#   default targets: the 9 variants that can be generated on x86 (the _pf variants need the RVV target:
#   pystencils' prefetch pass is RISC-V only, so they are built on the board only)
# Environment:
#   B=<dir>     build root, default <repo>/build/presentation4-x86 (ignored by git); the tree is <B>/<cc>-<prec>
#   PY=<python> a Python with numpy, sympy and lbmpy 2.1.1 (pystencils and sweepgen come from this repo),
#               default <repo>/../.venv-rvv/bin/python (the one used for presentation4)
#   JOBS=<n>    parallel compile jobs, default: all cores
#   TESTS=ON    also configure waLBerla's tests (default OFF; stage 1 ran ctest in a tree with ON)
#   PYSTENCILS=upstream  generate with upstream pystencils (commit 20d7dcf0, the last one before our RVV
#               work), exported from this repository's submodule into <B>/pystencils-upstream; default: our fork
#
# The settings are those of the trees used for presentation4 (CMakeCache.txt of build/presentation4-x86/*):
# Ninja, Release, WALBERLA_OPTIMIZE_FOR_LOCALHOST=ON, MPI, v8 core and sweepgen with an external Python.
# pystencils-sfg 0.1.1 is installed once into <B>/sfg (pip --target, no dependencies).
set -euo pipefail

CC_NAME="${1:?usage: $0 <gcc|clang> <f32|f64> [target ...]}"; PREC="${2:?usage: $0 <gcc|clang> <f32|f64> [target ...]}"
shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
B="$(realpath -m "${B:-${REPO}/build/presentation4-x86}")"   # absolute: code generation runs inside the tree
PY="${PY:-$(dirname "${REPO}")/.venv-rvv/bin/python}"
JOBS="${JOBS:-$(nproc)}"
TESTS="${TESTS:-OFF}"
PS_SRC="${REPO}/submodules/pystencils/src"
case "${CC_NAME}" in gcc) CC=gcc; CXX=g++ ;; clang) CC=clang; CXX=clang++ ;; *) echo "compiler: gcc or clang"; exit 1 ;; esac
case "${PREC}" in f64) DOUBLE=ON ;; f32) DOUBLE=OFF ;; *) echo "precision: f32 or f64"; exit 1 ;; esac
TARGETS="${*:-SweepgenLdcCPU_scalar SweepgenLdcCPU_scalar_cse SweepgenLdcCPU_scalar_cse_aa SweepgenLdcCPU_autovec
SweepgenLdcCPU_autovec_cse SweepgenLdcCPU_autovec_cse_aa SweepgenLdcCPU_explicit_cse SweepgenLdcCPU_explicit_cse_aa
SweepgenLdcCPU_explicit_cse_aa_split}"

[[ -x "${PY}" ]] || { echo "no Python at ${PY} (set PY=...)"; exit 1; }
mkdir -p "${B}"
if [[ ! -d "${B}/sfg/pystencilssfg" ]]; then
    echo "== installing pystencils-sfg 0.1.1 into ${B}/sfg"
    "${PY}" -m pip install --quiet --target "${B}/sfg" --no-deps pystencilssfg==0.1.1
fi
if [[ "${PYSTENCILS:-fork}" == upstream ]]; then
    PS_SRC="${B}/pystencils-upstream/src"
    if [[ ! -d "${PS_SRC}" ]]; then
        mkdir -p "${B}/pystencils-upstream"
        git -C "${REPO}/submodules/pystencils" archive 20d7dcf0 src | tar -x -C "${B}/pystencils-upstream"
    fi
    echo "== pystencils: upstream 20d7dcf0 (${PS_SRC})"
fi
export PYTHONPATH="${B}/sfg:${PS_SRC}:${REPO}/submodules/walberla/sweepgen/src"
export PATH="${B}/sfg/bin:${PATH}"

T="${B}/${CC_NAME}-${PREC}"
echo "== configure ${T} $(date +%T)"
cmake -G Ninja -S "${REPO}/submodules/walberla" -B "${T}" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DWALBERLA_DOUBLE_ACCURACY="${DOUBLE}" \
    -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF \
    -DPython_EXECUTABLE="${PY}" -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
    -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS="${TESTS}" -DWALBERLA_BUILD_TOOLS=OFF \
    -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF -DWALBERLA_BUILD_SHOWCASES=OFF \
    -DWALBERLA_BUILD_DOC=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON > "${T}.configure.log" 2>&1 \
    || { echo "CONFIGURE FAILED, see ${T}.configure.log"; tail -5 "${T}.configure.log"; exit 1; }
echo "== build ${TARGETS//$'\n'/ } $(date +%T)"
# shellcheck disable=SC2086
ninja -C "${T}" -j "${JOBS}" ${TARGETS} > "${T}.build.log" 2>&1 \
    || { echo "BUILD FAILED, see ${T}.build.log"; grep -m10 -E "error" "${T}.build.log"; exit 1; }
echo "== done $(date +%T): executables in ${T}/apps/benchmarks/SweepgenLdcCPU/"
