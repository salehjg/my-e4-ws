#!/usr/bin/env bash
# Out-of-tree RVV-vs-autovec experiment: generate kernels, build the variant matrix, run, report.
#
# Runs ON THE BOARD (needs the native toolchains). From the laptop:
#   bash run.on.bananapi.sh bash misc/rvv-vs-autovec/run.sh
# Output goes to BUILD, outside the synced repo (every push mirrors the repo with --delete):
#   default /home/bananapi/saleh/rvv-vs-autovec-build/{src,obj,bin,log,results.tsv,hotloops.txt,report.md}
#
# Variant matrix: {gcc, clang} x {f64, f32} x kernel (see gen.py) x build, where build is
#   scalar   generic kernel, -march=rv64gc            (no V extension: truly scalar)
#   autovec  generic kernel, -march=rv64gcv_zvl256b   (the compiler auto-vectorizes)
#   rvv      rvv kernel,     -march=rv64gcv_zvl256b   (our intrinsics)
# Optimization flags are the pystencils JIT's: GCC -Ofast, Clang -O3 -ffast-math -fhonor-infinities.
#
# To test a hypothesis by hand: edit a file in BUILD/src, then rerun with NO_GEN=1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILD="${BUILD:-$(dirname "${REPO}")/rvv-vs-autovec-build}"
SIZES="${SIZES:-200 48}"   # 200x200: the harness' periodic grid (5.9 MB f64, DRAM); 48x48: fits in L2
REPS="${REPS:-50}"
CPU="${CPU:-2}"            # pin to one core: less noise on a shared board
JOBS="${JOBS:-4}"
INC="${REPO}/submodules/pystencils/src/pystencils/include"
RVV_MARCH="-march=rv64gcv_zvl256b"

declare -A CXX=( [gcc]=g++ [clang]=clang++ )
#   GCC_EXTRA / CLANG_EXTRA: extra kernel flags for one compiler, e.g. CLANG_EXTRA=-mtune=spacemit-x60
declare -A OPT=( [gcc]="-Ofast ${GCC_EXTRA:-}" [clang]="-O3 -ffast-math -fhonor-infinities ${CLANG_EXTRA:-}" )
declare -A CTYPE=( [f64]=double [f32]=float )

if [[ -z "${NO_GEN:-}" ]]; then
    rm -rf "${BUILD}"
    mkdir -p "${BUILD}/src"
    python "${HERE}/gen.py" "${BUILD}/src" > /dev/null
fi
rm -rf "${BUILD}"/{obj,bin,log} "${BUILD}"/*.tsv
mkdir -p "${BUILD}"/{obj,bin,log}

#   ---- compile: kernel objects in parallel (the RVV sources without CSE are big), then link
compile() {   # compile <compiler> <src> <obj> <march>
    # shellcheck disable=SC2086
    ${CXX[$1]} -DNDEBUG -std=c++17 ${OPT[$1]} "$4" -I"${INC}" -c "$2" -o "$3" \
        2> "${BUILD}/log/$(basename "$3" .o).log"
}
echo "== compiling ($(date +%T))"
VARIANTS=()
for cc in gcc clang; do
    for dt in f64 f32; do
        #   The driver itself is plain scalar code; it is not what we measure
        ${CXX[$cc]} -O2 -march=rv64gc -DT=${CTYPE[$dt]} -c "${HERE}/bench.cpp" -o "${BUILD}/obj/bench-${cc}-${dt}.o"
        for kind in stream fused fused_cse fused_cse_neg fused_cse_fma fused_cse_vf; do
            for build in scalar autovec rvv; do
                case ${build} in
                    scalar)  src=generic; march="-march=rv64gc" ;;
                    autovec) src=generic; march="${RVV_MARCH}" ;;
                    rvv)     src=rvv;     march="${RVV_MARCH}" ;;
                esac
                v="${cc}-${dt}-${kind}-${build}"
                VARIANTS+=("${v}")
                while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n || true; done
                compile "${cc}" "${BUILD}/src/${dt}-${kind}-${src}.cpp" "${BUILD}/obj/${v}.o" "${march}" &
            done
        done
    done
done
wait
for v in "${VARIANTS[@]}"; do
    IFS=- read -r cc dt kind build <<< "${v}"
    [[ -s "${BUILD}/obj/${v}.o" ]] || { echo "compile failed: ${v}"; cat "${BUILD}/log/${v}.log"; exit 1; }
    #   The wrapper is its own TU (see gen.py): the kernel must not see the strides as constants
    src=generic; [[ "${build}" == rvv ]] && src=rvv
    ${CXX[$cc]} -O2 -march=rv64gc -c "${BUILD}/src/${dt}-${kind}-${src}.wrap.cpp" -o "${BUILD}/obj/${v}.wrap.o"
    ${CXX[$cc]} "${BUILD}/obj/bench-${cc}-${dt}.o" "${BUILD}/obj/${v}.wrap.o" "${BUILD}/obj/${v}.o" -o "${BUILD}/bin/${v}"
done

#   ---- instruction histogram of the hot vector loops of the vector builds (see hotloop.py)
echo "== disassembling ($(date +%T))"
python "${HERE}/hotloop.py" "${BUILD}"/bin/*-fused*-autovec "${BUILD}"/bin/*-fused*-rvv > "${BUILD}/hotloops.txt"

#   ---- run: each binary per size, pinned to one core
echo "== running ($(date +%T)), sizes: ${SIZES}, reps: ${REPS}, cpu: ${CPU}"
for v in "${VARIANTS[@]}"; do
    for n in ${SIZES}; do
        line="$(taskset -c "${CPU}" "${BUILD}/bin/${v}" "${n}" "${n}" "${REPS}")"
        printf '%s\t%s\t%s\n' "${v}" "${n}" "${line}" >> "${BUILD}/results.tsv"
    done
done

python "${HERE}/report.py" "${BUILD}" | tee "${BUILD}/report.md"
echo "== done ($(date +%T))"
