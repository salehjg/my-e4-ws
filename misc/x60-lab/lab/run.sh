#!/usr/bin/env bash
# D3Q19 kernel lab: build the given variants with the given compilers/flags and run them.
#
# Runs ON THE BOARD. Kernel sources come from gen.py (generated on the laptop into
# misc/x60-lab/lab/src/ and synced, because lbmpy codegen is slow on the board).
#   bash run.sh [VARIANT ...]          (default: every src/*.cpp that is not a .wrap.cpp)
# Env: MARCH / MARCH_SCALAR override the kernel -march (default ..._zicbop_zicboz / rv64gc_zicbop)
#      CCS="gcc clang"  FLAGS="O3"  (O3 = waLBerla's -O3, Ofast = the JIT's)  N=64 STEPS=20
#      CPU=2  BUILD=/home/bananapi/saleh/notes3/lab  EXTRA="..." (extra kernel flags)
#      RUNENV="THP=1 ..." (environment for the run)  TAG=<label in results.tsv>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
BUILD="${BUILD:-/home/bananapi/saleh/notes3/lab}"
INC="${REPO}/submodules/pystencils/src/pystencils/include"
CCS="${CCS:-gcc}"; FLAGS="${FLAGS:-O3}"; N="${N:-64}"; STEPS="${STEPS:-20}"; CPU="${CPU:-2}"
TAG="${TAG:-}"
declare -A CXX=( [gcc]=g++ [clang]=clang++ )
declare -A OPT=( [O3]="-O3" [Ofast]="-Ofast" )
mkdir -p "${BUILD}"/{obj,bin,log}
cd "${HERE}/src"
#   Hand-written kernels live in ../hand/NAME.cpp and define run_kernel themselves (no wrapper).
#   HAND_DEFS="-DBY=4 ..." are extra -D flags for them; NAME may carry a @label suffix for the results.
VARIANTS=("$@")
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
   for f in *.cpp; do [[ "$f" == *.wrap.cpp ]] || VARIANTS+=("${f%.cpp}"); done
fi
for cc in ${CCS}; do
  for fl in ${FLAGS}; do
    for v in "${VARIANTS[@]}"; do
      dt=${v%%-*}; ct=float; [[ $dt == f64 ]] && ct=double
      tgt=$(echo "$v" | cut -d- -f2)   # generic / rvv / hand
      march=${MARCH:--march=rv64gcv_zvl256b_zicbop_zicboz}
      [[ $tgt == generic && $v == *scalar* ]] && march=${MARCH_SCALAR:--march=rv64gc_zicbop}
      name="${cc}-${fl}-${v}"
      base="${v%%@*}"
      ${CXX[$cc]} -O2 -march=rv64gc -DT=$ct -c "${HERE}/driver.cpp" -o "${BUILD}/obj/driver-${cc}-${dt}.o"
      if [[ -f "${HERE}/hand/${base}.cpp" ]]; then
         ${CXX[$cc]} -DNDEBUG -std=c++20 ${OPT[$fl]} $march ${EXTRA:-} ${HAND_DEFS:-} -c "${HERE}/hand/${base}.cpp" -o "${BUILD}/obj/${name}.o" 2> "${BUILD}/log/${name}.log" \
            || { cat "${BUILD}/log/${name}.log"; exit 1; }
         ${CXX[$cc]} "${BUILD}/obj/driver-${cc}-${dt}.o" "${BUILD}/obj/${name}.o" -o "${BUILD}/bin/${name}"
      else
         ${CXX[$cc]} -DNDEBUG -std=c++17 ${OPT[$fl]} $march ${EXTRA:-} -I"${INC}" -c "$v.cpp" -o "${BUILD}/obj/${name}.o" 2> "${BUILD}/log/${name}.log" \
            || { cat "${BUILD}/log/${name}.log"; exit 1; }
         ${CXX[$cc]} -O2 -march=rv64gc -c "$v.wrap.cpp" -o "${BUILD}/obj/${name}.wrap.o"
         ${CXX[$cc]} "${BUILD}/obj/driver-${cc}-${dt}.o" "${BUILD}/obj/${name}.wrap.o" "${BUILD}/obj/${name}.o" -o "${BUILD}/bin/${name}"
      fi
      line="$(env ${RUNENV:-} taskset -c "${CPU}" "${BUILD}/bin/${name}" "${N}" "${STEPS}")"
      printf '%s\t%s\t%s\t%s\n' "${name}" "${TAG}" "${RUNENV:-} ${HAND_DEFS:-}" "${line}" | tee -a "${BUILD}/results.tsv"
    done
  done
done
