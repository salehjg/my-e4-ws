# presentation6: the machine profile, sourced by every presentation6 script. The same scripts run on both
# machines; everything that differs between them is set here:
#
#   bananapi   Banana Pi BPI-F3, SpacemiT K1: 8 X60 cores (2 clusters of 4), VLEN 256, 3.8 GB, no batch system,
#              system compilers (GCC 14.2, Clang 18), jobs run detached in screen
#   monte3     Monte Cimone (University of Bologna), slurm partition "peak", ONE node available to us (never more
#              than one per job; round 1 ran on mc-peak-2): Sophgo SG2044,
#              64 C920v2 cores at 2.6 GHz, VLEN 128, 2 MB L2 per 4 cores, 64 MB L3, 1 NUMA node, 124 GB; openEuler
#              24.03; x86-64 login node; GCC 14.2 from the module gcc-14.2.0 (system GCC 12 has no RVV intrinsics),
#              system Clang 17.0.6, cmake 3.27.9 and Open MPI 4.1.5; Python 3.12 built from source by setup.sh
#              (the system has 3.11); every job runs through sbatch (peak.sbatch: whole node, 64 tasks)
#
# The machine is recognized from /proc/cpuinfo and the host name; P6_MACHINE=<name> overrides (not MACHINE: some
# shells set that to the host name). setup.sh writes
# what it found and tested on the machine (modules to load, VLEN measured with a test program, the compilers
# and the MPI launch that work) to <base>/presentation6/machine.env. This file reads it first, so every
# script runs in the environment that setup.sh checked. Without machine.env the defaults below apply
# (enough on bananapi, whose venv and compilers presentation4 already used).
#
# The caller sets HERE (this folder) before sourcing. Sets:
#   REPO BASE P6DIR LOGDIR BUILD_ROOT VENV PY   paths; BUILD_ROOT holds the build trees and, in logs/, their
#               verify logs (bananapi: BUILD_ROOT=<base>/presentation4 times presentation4's verified executables)
#   MACHINE ALL_CORES CPU JOBS CORE_LIST COMPILERS
#   VLEN        the hardware vector register width in bits (0: not known, run setup.sh)
#   RVV_VLEN    the width pystencils' RVV backend generates code for (RVV_VLEN in its rvv.py)
#   EXPLICIT_OK 1 if the explicit variants (RVV intrinsics) are correct here, i.e. VLEN >= RVV_VLEN
#   VECTOR_MARCH   the last -march of the vector trees' compile commands (check_build.py checks it)
#   VECTOR_FLAGS   extra cmake arguments of a vector tree (empty: waLBerla's own flags, as in presentation4)
#   OBJDUMP     the disassembler that counts vector instructions
#   MPIRUN MPIRUN_ARGS   the MPI launch; p6_mpirun <np> <exe> <args...> runs it
#   RUN_PREFIX  put before every single-process run; empty on bananapi (as presentation4/5); "mpirun -np 1
#               --bind-to none" where setup.sh finds that a process started on its own cannot initialise MPI
#               inside the allocation; p6_single <exe> <args...> runs one process, pinned to core CPU
#   LINK_FLAGS  extra linker flags of every build tree (monte3: -Wl,-rpath-link,... because the gcc-14.2.0
#               module's linker does not find libmpi's own dependencies; link-time search only)
#   SCALAR_VARIANTS AUTOVEC_VARIANTS EXPLICIT_VARIANTS   the 11 variants of presentation4
# Functions: p6_mpirun, p6_single, p6_exe <cc> <prec> <variant>, p6_supported <variant>, p6_vector_variants,
#   p6_profile (prints the profile; every log starts with it), p6_wait_turn <own screen name>,
#   p6_in_verify_log <log> <hash> <exe>

REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P6DIR="${P6DIR:-${BASE}/presentation6}"
LOGDIR="${LOGDIR:-${P6DIR}/logs}"
BUILD_ROOT="${BUILD_ROOT:-${P6DIR}}"
VENV="${VENV:-${BASE}/venv}"
PY="${PY:-${VENV}/bin/python}"
MACHINE_ENV="${MACHINE_ENV:-${P6DIR}/machine.env}"

#   What setup.sh found on this machine. Module init scripts are not written for `set -u`.
P6_MACHINE_ENV_READ=none
if [[ -f "${MACHINE_ENV}" && "${P6_NO_MACHINE_ENV:-0}" != 1 ]]; then
    case $- in *u*) _p6_u=1 ;; *) _p6_u=0 ;; esac
    set +u
    # shellcheck disable=SC1090
    source "${MACHINE_ENV}"
    [[ "${_p6_u}" == 1 ]] && set -u
    P6_MACHINE_ENV_READ="${MACHINE_ENV}"
fi

p6_detect_machine() {
    local uarch host
    uarch="$(grep -m1 '^uarch' /proc/cpuinfo 2>/dev/null)"
    host="$(hostname)"
    if [[ "${uarch}" == *spacemit,x60* ]]; then echo bananapi
    elif [[ "${host}" == mc-peak-* ]]; then echo monte3
    else echo "other-$(uname -m)"; fi
}
MACHINE="${P6_MACHINE:-${P6_ENV_MACHINE:-$(p6_detect_machine)}}"
ALL_CORES="$(nproc)"

case "${MACHINE}" in
    bananapi)
        _p6_vlen=256; _p6_cores="1 4 8"; _p6_jobs=2; _p6_cc="gcc clang" ;;
    monte3)
        #   jobs: about 2 GB per compiler process (the heaviest waLBerla files need ~1.3 GB), at most one per core
        _p6_jobs="$(awk -v n="${ALL_CORES}" '/^MemTotal/ {j = int($2 / 2097152); if (j > n) j = n; if (j < 1) j = 1; print j}' /proc/meminfo)"
        _p6_vlen=0; _p6_cores="1 4 8 16 32 64"; _p6_cc="gcc" ;;
    *)
        _p6_vlen=0; _p6_cores="1"; _p6_jobs=2; _p6_cc="gcc" ;;
esac
VLEN="${VLEN:-${P6_ENV_VLEN:-${_p6_vlen}}}"
COMPILERS="${COMPILERS:-${P6_ENV_COMPILERS:-${_p6_cc}}}"
CPU="${CPU:-2}"
JOBS="${JOBS:-${_p6_jobs}}"
CORE_LIST="${CORE_LIST:-${_p6_cores}}"
#   only the core counts this allocation has
_p6_list=""; for _c in ${CORE_LIST}; do (( _c <= ALL_CORES )) && _p6_list+="${_p6_list:+ }${_c}"; done
CORE_LIST="${_p6_list}"

RVV_VLEN="$(sed -n 's/^RVV_VLEN = \([0-9]*\).*/\1/p' "${REPO}/submodules/pystencils/src/pystencils/backend/platforms/rvv.py" 2>/dev/null)"
RVV_VLEN="${RVV_VLEN:-0}"
EXPLICIT_OK=0
(( VLEN > 0 && RVV_VLEN > 0 && VLEN >= RVV_VLEN )) && EXPLICIT_OK=1

#   waLBerla's configure (cmake/compileroptions/{GNU,Clang}.cmake) adds -march=rv64gcv_zvl256b whenever the
#   ISA has V. That is right only at VLEN 256; anywhere else the vector trees get our -march instead, through
#   CMAKE_<LANG>_FLAGS_RELEASE, which come after waLBerla's flags on every compile line (as the scalar trees).
VECTOR_MARCH="-march=rv64gcv_zvl${VLEN}b"
(( VLEN > 0 )) || VECTOR_MARCH="(VLEN not known)"
VECTOR_FLAGS=()
if (( VLEN > 0 && VLEN != 256 )); then
    VECTOR_FLAGS=(-DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG ${VECTOR_MARCH}" -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG ${VECTOR_MARCH}")
fi

OBJDUMP="${OBJDUMP:-${P6_ENV_OBJDUMP:-$(command -v llvm-objdump || command -v objdump || echo llvm-objdump)}}"
MPIRUN="${MPIRUN:-${P6_ENV_MPIRUN:-mpirun}}"
MPIRUN_ARGS="${MPIRUN_ARGS:-${P6_ENV_MPIRUN_ARGS:---bind-to core --map-by core}}"
RUN_PREFIX="${RUN_PREFIX:-${P6_ENV_RUN_PREFIX:-}}"
LINK_FLAGS="${LINK_FLAGS:-${P6_ENV_LINK_FLAGS:-}}"
export OBJDUMP VECTOR_MARCH

SCALAR_VARIANTS="scalar scalar_cse scalar_cse_aa"
AUTOVEC_VARIANTS="autovec autovec_cse autovec_cse_aa"
EXPLICIT_VARIANTS="explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"

p6_mpirun() {   # p6_mpirun <np> <exe> <args...>
    local np="$1"; shift
    # shellcheck disable=SC2086
    ${MPIRUN} -np "${np}" ${MPIRUN_ARGS} "$@"
}

p6_single() {   # p6_single <exe> <args...>: one process, pinned to core CPU
    # shellcheck disable=SC2086
    ${RUN_PREFIX} taskset -c "${CPU}" "$@"
}

p6_exe() {   # p6_exe <cc> <prec> <variant>: scalar variants live in the -scalar tree (every file -march=rv64gc)
    local tree="build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"
    echo "${BUILD_ROOT}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"
}

p6_supported() {   # p6_supported <variant>: 0 if the variant gives correct results on this machine
    [[ "$1" != explicit* || "${EXPLICIT_OK}" == 1 ]]
}

p6_vector_variants() {   # the vector-tree variants that this machine supports
    echo "${AUTOVEC_VARIANTS}$( [[ "${EXPLICIT_OK}" == 1 ]] && echo " ${EXPLICIT_VARIANTS}")"
}

p6_in_verify_log() {   # p6_in_verify_log <verify log> <sha256 prefix> <exe>: prepare.sh verified this executable
    awk -v h="$2" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "$1" 2>/dev/null
}

p6_wait_turn() {   # p6_wait_turn <own screen name>: wait until no other timing job runs (bananapi: screen sessions;
                   # inside screen, STY names our own session, e.g. all.sh's). monte3: an exclusive node, no screen.
    local me="${STY:-$1}"
    while screen -ls 2>/dev/null | grep -E "presentation[456]|notes5" | grep -v -F -- "${me}" | grep -q .; do
        echo "waiting for: $(screen -ls | grep -E 'presentation[456]|notes5' | grep -v -F -- "${me}" | tr -s ' \t' ' ')"; sleep 30
    done
}

p6_profile() {
    local why
    if [[ "${EXPLICIT_OK}" == 1 ]]; then why="yes"
    elif (( VLEN == 0 )); then why="no: VLEN not known (run setup.sh)"
    else why="no: they need VLEN >= ${RVV_VLEN}"; fi
    echo "== machine ${MACHINE} (host $(hostname), $(uname -m)${SLURM_JOB_ID:+, slurm job ${SLURM_JOB_ID}}), ${ALL_CORES} cores usable"
    echo "   VLEN ${VLEN}, pystencils RVV backend ${RVV_VLEN} -> explicit variants: ${why}"
    echo "   compilers: ${COMPILERS}; vector trees ${VECTOR_MARCH} ($( (( ${#VECTOR_FLAGS[@]} )) && echo "set by presentation6" || echo "waLBerla's own flags"))"
    echo "   jobs ${JOBS}, core counts ${CORE_LIST}; one process: ${RUN_PREFIX:+${RUN_PREFIX} }taskset -c ${CPU}; MPI: ${MPIRUN} -np N ${MPIRUN_ARGS}"
    echo "   link flags: ${LINK_FLAGS:-none}"
    echo "   objdump ${OBJDUMP}; cmake $(cmake --version 2>/dev/null | sed -n 's/^cmake version //p'); python ${PY} ($( [[ -x "${PY}" ]] && "${PY}" --version 2>&1 | cut -d' ' -f2 || echo "missing: run setup.sh"))"
    echo "   repo ${REPO}, builds ${BUILD_ROOT}, logs ${LOGDIR}, venv ${VENV}, machine.env: ${P6_MACHINE_ENV_READ}"
}
