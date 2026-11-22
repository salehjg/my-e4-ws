#!/usr/bin/env bash
# presentation6: prepare a machine for the presentation6 scripts and check that it is ready. Safe to re-run:
# what is already there is checked, not rebuilt (RECREATE_VENV=1 rebuilds the venv).
#
# monte3: as a batch job on a whole peak node (the login node is x86-64; the MPI test needs 8 tasks of slurm's).
# From <base>/my-e4-ws on the login node:
#     mkdir -p ../presentation6/logs && sbatch -J p6-setup --time=01:00:00 scripts/presentation6/peak.sbatch setup.sh
#   output: ../presentation6/logs/p6-setup-<job id>.out
# bananapi: bash scripts/presentation6/setup.sh   (the venv of presentation4 is only checked, not changed)
#
# Steps, each printed as PASS / FAIL / INFO; the last line says SETUP PASS or SETUP FAIL:
#   1. modules    load MODULES (monte3 default: gcc-14.2.0 openmpi-5.0.6, in this order; elsewhere none). The
#                 milkv Open MPI 5.0.6, not the system Open MPI 4.1.5: its helper thread spins and halves every
#                 core, and some runs hang (docs/notes7)
#   2. compilers  GCC >= 14 and, if present, Clang >= 17: each compiles and runs a test program with RVV intrinsics
#                 that reads VLEN from the vlenb register (all must agree), and accepts -march=rv64gc and the
#                 vector trees' -march=rv64gcv_zvl<VLEN>b
#   3. objdump    llvm-objdump (else GNU objdump) finds the test programs' vector instructions
#   4. smoke      per compiler, a C++ loop program built with -O3 for this VLEN gives the same result as built
#                 with -march=rv64gc, and the vector build has vector instructions (proves both the compiler's
#                 vector code at this VLEN and its C++ runtime on this CPU). INFO: the same program built for
#                 VLEN 256 (waLBerla's default -march), to show what that does here.
#   5. mpi        mpicc builds a test program with each compiler (if the linker cannot find the MPI libraries'
#                 own dependencies, as the gcc-14.2.0 module's binutils 2.42 on monte3 cannot, again with
#                 -Wl,-rpath-link,<MPI lib dir>:<system lib dir>: link-time search only, the program does not
#                 change; then LINK_FLAGS for the builds); mpirun starts 8 processes on 8 different cores inside the
#                 allocation (slurm must grant at least 8 tasks: peak.sbatch asks for 64); a single process pinned
#                 to core CPU initialises MPI, started on its own (as on bananapi) or else through mpirun -np 1
#   6. python     a Python >= 3.12 (lbmpy 2.1.1 needs it): PYTHON, or one on PATH, or one built earlier into
#                 <base>/python; else CPython PY_SRC_VERSION is built from python.org's source tarball into
#                 <base>/python/<version> with the system GCC (needs openssl, zlib and libffi headers)
#   7. venv       <base>/venv: numpy (no riscv64 wheel on PyPI: built from source, several minutes), sympy 1.14.0,
#                 appdirs, joblib, packaging, pyyaml, fasteners, py-cpuinfo; lbmpy 2.1.1 and pystencilssfg 0.1.1
#                 without their dependencies, so that PyPI's pystencils never shadows the repo's (it comes in by
#                 PYTHONPATH); cmake from pip if the machine's is older than 3.26. Installs only what is missing.
#   8. imports    with build.sh's PYTHONPATH: the repo's pystencils and sweepgen, lbmpy, pystencilssfg import;
#                 pystencils lists RISCV_RVV among this machine's vector targets
#   9. cmake      >= 3.26 (waLBerla's minimum), with the venv first on PATH as in build.sh
# On SETUP PASS it writes <base>/presentation6/machine.env (machine.sh reads it: modules, VLEN, compilers,
# objdump, MPI launch, single-run prefix, link flags) and prints the profile; on FAIL it writes machine.env.failed.
#
# Environment: MODULES, PYTHON (an interpreter >= 3.12 to use), PY_SRC_VERSION (default 3.12.11), RECREATE_VENV=1,
#   PIP_ARGS (extra pip arguments, e.g. "--no-index --find-links <dir>"), SYSTEM_SITE=1 (the venv sees the
#   system's site-packages), CPU (default 2)
# Writes only: <base>/venv, <base>/python, <base>/presentation6/{machine.env,setup/}, <base>/.cache
# Network: python.org (the Python source tarball, only if no Python >= 3.12 exists) and PyPI (pip)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
#   the profile's defaults only: this script is about to write machine.env
P6_NO_MACHINE_ENV=1
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
W="${P6DIR}/setup"
PYDIR="${BASE}/python"
mkdir -p "${W}" "${LOGDIR}"
export XDG_CACHE_HOME="${BASE}/.cache"
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
info() { echo "INFO $*"; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }   # ver_ge <a> <b>: a >= b
count_v() { "$1" -d --no-show-raw-insn "$2" 2> /dev/null | awk '$2 ~ /^v[a-z]/ {n++} END {print n + 0}'; }

echo "== presentation6 setup, $(date), host $(hostname), machine ${MACHINE}, $(uname -m)${SLURM_JOB_ID:+, slurm job ${SLURM_JOB_ID}}"
if [[ "$(uname -m)" != riscv64 ]]; then
    echo "setup.sh must run on the RISC-V machine itself (this is $(uname -m)). On monte3, from the login node:"
    echo "  mkdir -p ../presentation6/logs && sbatch -J p6-setup --time=01:00:00 scripts/presentation6/peak.sbatch setup.sh"
    exit 1
fi
grep -m1 '^isa' /proc/cpuinfo

# ---- 1. modules ---------------------------------------------------------------------------------------------
case "${MACHINE}" in monte3) MODULES="${MODULES-gcc-14.2.0 openmpi-5.0.6}" ;; *) MODULES="${MODULES-}" ;; esac
MODULE_INIT=""
if [[ -n "${MODULES}" ]]; then
    for f in /usr/share/Modules/init/bash /etc/profile.d/modules.sh /usr/share/lmod/lmod/init/bash; do
        [[ -f "${f}" ]] && { MODULE_INIT="${f}"; break; }
    done
    set +u
    # shellcheck disable=SC1090
    [[ -n "${MODULE_INIT}" ]] && source "${MODULE_INIT}"
    for m in ${MODULES}; do
        module load "${m}" > "${W}/module.out" 2>&1
        if module is-loaded "${m}" 2> /dev/null; then pass "module ${m}"; else fail "module ${m}: $(head -3 "${W}/module.out" | tr '\n' ' ')"; fi
    done
    set -u
else
    info "no modules to load"
fi

# ---- 2. compilers and VLEN ------------------------------------------------------------------------------------
cat > "${W}/vlen.c" <<'C'
#include <stdio.h>
#include <riscv_vector.h>
int main(void) {
    unsigned long vlenb;
    __asm__ volatile("csrr %0, vlenb" : "=r"(vlenb));
    printf("%lu %zu\n", vlenb * 8, (size_t)__riscv_vsetvlmax_e8m1() * 8);
    return 0;
}
C
echo 'int p6_empty;' > "${W}/empty.cpp"
VLEN_SEEN=""; CC_OK=""
for cc in gcc clang; do
    cxx=g++; min=14; [[ "${cc}" == clang ]] && { cxx=clang++; min=17; }
    if ! command -v "${cc}" > /dev/null || ! command -v "${cxx}" > /dev/null; then
        if [[ "${cc}" == gcc ]]; then fail "gcc/g++ not found"; else info "clang/clang++ not found: GCC only"; fi
        continue
    fi
    v="$("${cc}" -dumpversion 2> /dev/null)"
    where="$(command -v "${cxx}") ${v}"
    if ! ver_ge "${v}" "${min}"; then
        if [[ "${cc}" == gcc ]]; then fail "${cc} ${where}: older than ${min} (monte3: module gcc-14.2.0)"; else info "${cc} ${where}: older than ${min}, not used"; fi
        continue
    fi
    if ! "${cc}" -O2 -march=rv64gcv "${W}/vlen.c" -o "${W}/vlen-${cc}" 2> "${W}/vlen-${cc}.err"; then
        fail "${cc} ${where}: RVV test program does not compile: $(head -2 "${W}/vlen-${cc}.err" | tr '\n' ' ')"; continue
    fi
    read -r vl_csr vl_set <<< "$("${W}/vlen-${cc}")"
    if [[ -z "${vl_csr}" || "${vl_csr}" != "${vl_set}" ]]; then
        fail "${cc}: RVV test program gives VLEN '${vl_csr}' (vlenb) and '${vl_set}' (vsetvlmax)"; continue
    fi
    [[ -n "${VLEN_SEEN}" && "${VLEN_SEEN}" != "${vl_csr}" ]] && fail "${cc}: VLEN ${vl_csr}, other compiler ${VLEN_SEEN}"
    VLEN_SEEN="${vl_csr}"
    ok=1
    for march in "rv64gcv_zvl${vl_csr}b" rv64gc; do
        "${cxx}" -O3 -march="${march}" -c "${W}/empty.cpp" -o "${W}/empty.o" 2> /dev/null || { fail "${cxx}: rejects -march=${march}"; ok=0; }
    done
    [[ "${ok}" == 1 ]] && { pass "${cc} ${where}: VLEN ${vl_csr} bits, accepts -march=rv64gcv_zvl${vl_csr}b and rv64gc"; CC_OK+="${CC_OK:+ }${cc}"; }
done
VLEN="${VLEN_SEEN:-0}"
if (( VLEN > 0 )); then
    if (( VLEN >= RVV_VLEN )); then pass "VLEN ${VLEN} >= ${RVV_VLEN} (pystencils RVV backend): explicit variants can run"
    else info "VLEN ${VLEN} < ${RVV_VLEN} (pystencils RVV backend): the explicit variants are skipped on this machine"; fi
fi

# ---- 3. objdump -----------------------------------------------------------------------------------------------
OBJDUMP_OK=""
for d in llvm-objdump objdump; do
    command -v "${d}" > /dev/null || continue
    good=1
    for cc in ${CC_OK}; do (( $(count_v "${d}" "${W}/vlen-${cc}") > 0 )) || good=0; done
    [[ "${good}" == 1 ]] && { OBJDUMP_OK="$(command -v "${d}")"; break; }
done
if [[ -z "${CC_OK}" ]]; then fail "objdump: no working compiler to test it with"
elif [[ -n "${OBJDUMP_OK}" ]]; then pass "objdump ${OBJDUMP_OK} decodes the vector instructions of: ${CC_OK}"
else fail "no objdump decodes the vector instructions of the test programs (llvm-objdump or GNU objdump)"; fi

# ---- 4. smoke test: vector code for this VLEN, and the C++ runtime ----------------------------------------------
cat > "${W}/smoke.cpp" <<'C'
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>
int main() {
    const int n = 1000003;   // not a multiple of any vector length: the loop tails run too
    std::vector<double> a(n), b(n), c(n, 0.0);
    std::vector<float> f(n);
    for (int i = 0; i < n; ++i) { a[i] = 0.5 * i; b[i] = 1.0 / (i + 1); }
    for (int r = 0; r < 3; ++r)
        for (int i = 0; i < n; ++i) c[i] = a[i] * b[i] + std::sqrt(a[i]) - 0.25 * c[i];
    for (int i = 0; i < n; ++i) f[i] = float(c[i]) * 0.5f + float(b[i]);
    double s = 0; float fs = 0;
    for (int i = 0; i < n; ++i) { s += c[i]; fs += f[i]; }
    try { throw std::runtime_error("x"); } catch (const std::exception &) {}
    std::printf("%.15e %.7e\n", s, fs);
}
C
for cc in ${CC_OK}; do
    cxx=g++; [[ "${cc}" == clang ]] && cxx=clang++
    if ! "${cxx}" -O3 -march=rv64gc "${W}/smoke.cpp" -o "${W}/smoke-${cc}-scalar" 2> "${W}/smoke.err" \
       || ! "${cxx}" -O3 -march="rv64gcv_zvl${VLEN}b" "${W}/smoke.cpp" -o "${W}/smoke-${cc}-vector" 2>> "${W}/smoke.err"; then
        fail "${cxx}: smoke test does not compile: $(head -3 "${W}/smoke.err" | tr '\n' ' ')"; continue
    fi
    rs="$("${W}/smoke-${cc}-scalar" 2>&1)"; rv="$("${W}/smoke-${cc}-vector" 2>&1)"
    nv="$( [[ -n "${OBJDUMP_OK}" ]] && count_v "${OBJDUMP_OK}" "${W}/smoke-${cc}-vector")"
    #   same up to rounding: the compilers may contract multiply-adds differently in scalar and vector code
    if awk -v a="${rs}" -v b="${rv}" 'BEGIN {split(a, x, " "); split(b, y, " "); if (x[1] == "" || y[1] == "") exit 1;
            for (i = 1; i <= 2; i++) { d = x[i] - y[i]; if (d < 0) d = -d; m = x[i] < 0 ? -x[i] : x[i]; if (d > 1e-5 * m) exit 1 } }' \
       && (( ${nv:-0} > 0 )); then
        pass "${cxx} smoke test: vector build for VLEN ${VLEN} (${nv} vector instructions) = scalar build: ${rv}"
    else
        fail "${cxx} smoke test: scalar '${rs}', vector for VLEN ${VLEN} '${rv}' (${nv:-?} vector instructions)"
    fi
    #   evidence only: what a build for VLEN 256 (waLBerla's default -march) does on this machine
    if (( VLEN != 256 )) && "${cxx}" -O3 -march=rv64gcv_zvl256b "${W}/smoke.cpp" -o "${W}/smoke-${cc}-256" 2> /dev/null; then
        r256="$(timeout 60 "${W}/smoke-${cc}-256" 2>&1 | head -1)"
        info "${cxx} smoke test built for VLEN 256, run at VLEN ${VLEN}: '${r256}' (scalar: '${rs}')"
    fi
done

# ---- 5. MPI ---------------------------------------------------------------------------------------------------
cat > "${W}/mpi.c" <<'C'
#define _GNU_SOURCE
#include <mpi.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    int rank, size;
    MPI_Init(&argc, &argv); MPI_Comm_rank(MPI_COMM_WORLD, &rank); MPI_Comm_size(MPI_COMM_WORLD, &size);
    const char *e = getenv("P6_TEST_VAR");
    printf("rank %d/%d cpu %d env %s\n", rank, size, sched_getcpu(), e ? e : "unset");
    MPI_Finalize(); return 0;
}
C
MPI_OK=""; MPI_ARGS_OK="--bind-to core --map-by core"; RUN_PREFIX_OK=""; single_ok=0; LINK_FLAGS_OK=""
mpi_link() {   # build the MPI test program with every working compiler; sets LINK_FLAGS_OK if the linker needs it
    local cc libdirs sysdir d first="${CC_OK:-gcc}"
    first="${first%% *}"
    try() {   # try <link flags>: every compiler links the test program
        for cc in ${CC_OK:-gcc}; do
            # shellcheck disable=SC2086
            OMPI_CC="${cc}" mpicc -O2 "${W}/mpi.c" -o "${W}/mpi-${cc}" $1 > "${W}/mpi.err" 2>&1 || return 1
        done
        cp "${W}/mpi-${first}" "${W}/mpi"
    }
    try "" && return 0
    grep -q 'rpath-link' "${W}/mpi.err" || return 1
    #   the linker does not search the MPI library directory and the system library directory for the
    #   libraries that libmpi itself needs (warnings "... not found (try using -rpath or -rpath-link)")
    libdirs="$(mpicc --showme:link 2> /dev/null | tr ' ' '\n' | sed -n 's/^-L//p' | paste -sd: -)"
    [[ -n "${libdirs}" ]] || libdirs="$(mpicc --showme:libdirs 2> /dev/null | tr ' ' ':')"
    for d in /usr/lib64 /lib64 /usr/lib; do [[ -e "${d}/libm.so.6" ]] && { sysdir="${d}"; break; }; done
    LINK_FLAGS_OK="-Wl,-rpath-link,${libdirs:+${libdirs}:}${sysdir:-/usr/lib64}"
    info "MPI link: the linker ($("${first}" -print-prog-name=ld 2> /dev/null)) misses libmpi's own dependencies; again with ${LINK_FLAGS_OK}"
    if try "${LINK_FLAGS_OK}"; then
        pass "MPI link with ${LINK_FLAGS_OK} (${CC_OK:-gcc}): the builds get it as LINK_FLAGS"; return 0
    fi
    LINK_FLAGS_OK=""; return 1
}
if [[ -n "${SLURM_JOB_ID:-}" ]] && (( ${SLURM_NTASKS:-1} < 8 )); then
    fail "MPI: this allocation has ${SLURM_NTASKS:-1} task(s), the test needs 8: run setup.sh through peak.sbatch (64 tasks)"
elif ! command -v mpicc > /dev/null || ! command -v mpirun > /dev/null; then
    fail "mpicc/mpirun not found"
elif ! mpi_link; then
    fail "mpicc cannot build the MPI test program: $(grep -v -i warning "${W}/mpi.err" | head -3 | tr '\n' ' ') (full output: ${W}/mpi.err)"
else
    info "MPI: $(command -v mpirun), $(mpirun --version 2>&1 | head -1)${SLURM_NTASKS:+, allocation of ${SLURM_NTASKS} tasks}"
    # shellcheck disable=SC2086
    out="$(P6_TEST_VAR=seen timeout 120 mpirun -np 8 ${MPI_ARGS_OK} "${W}/mpi" 2>&1)"
    ranks="$(grep -c '^rank [0-7]/8 .* env seen$' <<< "${out}")"
    cpus="$(grep '^rank [0-7]/8 ' <<< "${out}" | awk '{print $4}' | sort -u | wc -l)"
    if [[ "${ranks}" == 8 && "${cpus}" == 8 ]]; then
        MPI_OK=mpirun; pass "MPI: mpirun -np 8 ${MPI_ARGS_OK}: 8 ranks on 8 different cores, environment passed on"
    else
        fail "MPI: mpirun -np 8 ${MPI_ARGS_OK}: ${ranks} ranks on ${cpus} cores: $(grep -v '^rank ' <<< "${out}" | grep -v '^-*$' | head -3 | tr '\n' ' ')"
    fi
    for p in "" "mpirun -np 1 --bind-to none"; do
        # shellcheck disable=SC2086
        out="$(P6_TEST_VAR=seen timeout 60 ${p} taskset -c "${CPU}" "${W}/mpi" 2>&1)"
        if grep -q -x "rank 0/1 cpu ${CPU} env seen" <<< "${out}"; then
            RUN_PREFIX_OK="${p}"; single_ok=1; pass "one process: ${p:+${p} }taskset -c ${CPU}: MPI starts, runs on core ${CPU}"; break
        fi
        info "one process: ${p:+${p} }taskset -c ${CPU}: $(grep -v '^-*$' <<< "${out}" | head -3 | tr '\n' ' ')"
    done
    [[ "${single_ok}" == 1 ]] || fail "one process: no way found to start a single MPI process on core ${CPU}"
fi

# ---- 6. Python >= 3.12 ----------------------------------------------------------------------------------------
PY_SRC_VERSION="${PY_SRC_VERSION:-3.12.11}"
py_ok() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2> /dev/null; }
pick_python() {
    local p
    if [[ -n "${PYTHON:-}" ]]; then echo "${PYTHON}"; return; fi
    for p in python3.14 python3.13 python3.12 python3; do
        command -v "${p}" > /dev/null && py_ok "${p}" && { command -v "${p}"; return; }
    done
    for p in "${PYDIR}"/3.1[2-9]*/bin/python3; do [[ -x "${p}" ]] && py_ok "${p}" && { echo "${p}"; return; }; done
}
build_python() {   # CPython PY_SRC_VERSION from python.org's source tarball into PYDIR/<version>; log in W
    local v="${PY_SRC_VERSION}" cc
    cc="$(command -v /usr/bin/gcc || command -v gcc)"   # the system GCC: Python must not depend on a module
    (
        set -e
        mkdir -p "${W}/python-src"; cd "${W}/python-src"
        [[ -f "Python-${v}.tgz" ]] || curl -fsSLO "https://www.python.org/ftp/python/${v}/Python-${v}.tgz"
        rm -rf "Python-${v}"; tar xzf "Python-${v}.tgz"; cd "Python-${v}"
        ./configure --prefix="${PYDIR}/${v}" --with-ensurepip=install CC="${cc}"
        make -j "${JOBS}"
        make install
    ) > "${W}/python-build.out" 2>&1
}
read -r -a pip_args <<< "${PIP_ARGS:-}"
if [[ "${RECREATE_VENV:-0}" == 1 && -d "${VENV}" ]]; then info "RECREATE_VENV=1: removing ${VENV}"; rm -rf "${VENV}"; fi
if [[ ! -x "${PY}" ]]; then
    py="$(pick_python)"
    if [[ -z "${py}" ]]; then
        info "no Python >= 3.12 here: building CPython ${PY_SRC_VERSION} from source into ${PYDIR}/${PY_SRC_VERSION} (a few minutes)"
        t0="$(date +%s)"
        if build_python && py_ok "${PYDIR}/${PY_SRC_VERSION}/bin/python3"; then
            py="${PYDIR}/${PY_SRC_VERSION}/bin/python3"; info "Python built in $(( $(date +%s) - t0 )) s"
        else
            fail "building Python ${PY_SRC_VERSION}: $(grep -i -E 'error|fail' "${W}/python-build.out" | tail -3 | tr '\n' ' ') (full output: ${W}/python-build.out)"
        fi
    fi
    if [[ -n "${py}" ]]; then
        #   pip needs ssl and zlib; the rest is reported
        mods="$("${py}" -c 'import importlib.util as u; print(" ".join(m for m in ("ssl", "zlib", "ctypes", "bz2", "lzma", "sqlite3", "readline") if not u.find_spec(m)))')"
        if [[ " ${mods} " == *" ssl "* || " ${mods} " == *" zlib "* || " ${mods} " == *" ctypes "* ]]; then
            fail "python ${py}: modules missing: ${mods} (ssl, zlib and ctypes are needed; their -devel headers were missing at build time)"
        else
            pass "python ${py} ($("${py}" --version 2>&1))${mods:+; optional modules missing: ${mods}}"
            site=(); [[ "${SYSTEM_SITE:-0}" == 1 ]] && site=(--system-site-packages)
            "${py}" -m venv "${site[@]}" "${VENV}" > "${W}/venv.out" 2>&1 \
                && info "venv ${VENV} created" || fail "${py} -m venv ${VENV}: $(tail -3 "${W}/venv.out" | tr '\n' ' ')"
        fi
    fi
fi

# ---- 7. venv packages -----------------------------------------------------------------------------------------
#   as in build.sh: the venv first on PATH, the repo's pystencils and sweepgen on PYTHONPATH (lbmpy imports pystencils)
export PATH="${VENV}/bin:${PATH}"
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
PKGS=(numpy "sympy==1.14.0" appdirs joblib packaging pyyaml fasteners py-cpuinfo)
NODEPS=("lbmpy==2.1.1" "pystencilssfg==0.1.1")
IMPORTS="numpy sympy appdirs joblib packaging yaml fasteners cpuinfo lbmpy pystencilssfg"
if [[ -x "${PY}" ]]; then
    py_ok "${PY}" || fail "venv ${VENV} has $("${PY}" --version 2>&1); lbmpy 2.1.1 needs >= 3.12 (RECREATE_VENV=1)"
    missing=""
    for m in ${IMPORTS}; do "${PY}" -c "import ${m}" 2> /dev/null || missing+=" ${m}"; done
    cmake_ok=0; command -v cmake > /dev/null && ver_ge "$(cmake --version | sed -n 's/^cmake version \([0-9.]*\).*/\1/p')" 3.26 && cmake_ok=1
    [[ -x "${VENV}/bin/cmake" ]] && cmake_ok=1
    if [[ -z "${missing}" && "${cmake_ok}" == 1 ]]; then
        info "venv ${VENV} has every package already"
    else
        info "installing into ${VENV}:${missing}$( [[ "${cmake_ok}" == 0 ]] && echo " cmake") (numpy from source if there is no wheel: several minutes)"
        t0="$(date +%s)"
        "${PY}" -m pip install -q "${pip_args[@]}" --upgrade pip > "${W}/pip.out" 2>&1 || info "pip upgrade failed (continuing)"
        extra=(); [[ "${cmake_ok}" == 0 ]] && extra=("cmake>=3.26,<4")
        #   CC/CXX: extensions built from source (numpy) use the compilers checked above
        if CC=gcc CXX=g++ "${PY}" -m pip install "${pip_args[@]}" "${PKGS[@]}" "${extra[@]}" >> "${W}/pip.out" 2>&1 \
           && "${PY}" -m pip install "${pip_args[@]}" --no-deps "${NODEPS[@]}" >> "${W}/pip.out" 2>&1; then
            info "pip install done in $(( $(date +%s) - t0 )) s"
        else
            fail "pip install: $(grep -i -E 'error|could not|no matching' "${W}/pip.out" | head -4 | tr '\n' ' ') (full output: ${W}/pip.out)"
        fi
    fi
    "${PY}" -m pip list 2> /dev/null | grep -i -E '^(numpy|sympy|lbmpy|pystencils|pystencilssfg|cmake|py-cpuinfo|mpmath) ' | sed 's/^/   /'
    "${PY}" -m pip list 2> /dev/null | grep -q -i '^pystencils ' && fail "PyPI's pystencils is in ${VENV}: it must not be (pip uninstall pystencils)"
fi

# ---- 8. imports -----------------------------------------------------------------------------------------------
if [[ -x "${PY}" ]]; then
    out="$("${PY}" - "${REPO}" <<'PY' 2>&1
import sys, os
repo = sys.argv[1]
import numpy, sympy, lbmpy, pystencilssfg, sweepgen, pystencils
from pystencils import Target
for m in (numpy, sympy, lbmpy, pystencilssfg, sweepgen, pystencils):
    print(f"   {m.__name__:14s} {getattr(m, '__version__', '?'):22s} {os.path.dirname(m.__file__)}")
ok_path = os.path.realpath(pystencils.__file__).startswith(os.path.realpath(repo))
targets = [t.name for t in Target.available_vector_cpu_targets()]
print(f"   vector targets: {targets}")
print("PY_OK" if ok_path and "RISCV_RVV" in targets else f"PY_BAD repo_pystencils={ok_path}")
PY
)"
    echo "${out}" | grep -v -E '^PY_'
    if grep -q '^PY_OK' <<< "${out}"; then pass "imports: the repo's pystencils and sweepgen, lbmpy, pystencilssfg; RISCV_RVV detected"
    else fail "imports: $(grep -E '^PY_BAD|Error' <<< "${out}" | head -3 | tr '\n' ' ')"; fi
    sfgv="$("${PY}" -m pystencilssfg version --no-newline 2>&1)" && pass "python -m pystencilssfg version: ${sfgv}" || fail "python -m pystencilssfg: ${sfgv}"
fi

# ---- 9. cmake and tools ---------------------------------------------------------------------------------------
if command -v cmake > /dev/null; then
    cv="$(cmake --version | sed -n 's/^cmake version \([0-9.]*\).*/\1/p')"
    if ver_ge "${cv}" 3.26; then pass "cmake $(command -v cmake) ${cv} >= 3.26"; else fail "cmake $(command -v cmake) ${cv} < 3.26"; fi
else
    fail "cmake not found"
fi
for x in make sha256sum taskset awk; do command -v "${x}" > /dev/null || fail "${x} not found"; done

# ---- machine.env ----------------------------------------------------------------------------------------------
target="${MACHINE_ENV}"; [[ "${fails}" == 0 ]] || target="${MACHINE_ENV}.failed"
{
    echo "# Written by scripts/presentation6/setup.sh on $(hostname), $(date). Read by machine.sh."
    echo "# Do not edit: run setup.sh again. ${fails} failure(s)."
    printf 'P6_ENV_MACHINE=%q\nP6_ENV_VLEN=%q\nP6_ENV_COMPILERS=%q\nP6_ENV_OBJDUMP=%q\n' "${MACHINE}" "${VLEN}" "${CC_OK}" "${OBJDUMP_OK}"
    printf 'P6_ENV_MPIRUN=%q\nP6_ENV_MPIRUN_ARGS=%q\nP6_ENV_RUN_PREFIX=%q\nP6_ENV_LINK_FLAGS=%q\nP6_ENV_SETUP_HOST=%q\n' \
        "${MPI_OK:-mpirun}" "${MPI_ARGS_OK}" "${RUN_PREFIX_OK}" "${LINK_FLAGS_OK}" "$(hostname)"
    if [[ -n "${MODULES}" ]]; then
        [[ -n "${MODULE_INIT}" ]] && printf 'source %q\n' "${MODULE_INIT}"
        echo "module load ${MODULES}"
    fi
} > "${target}"
[[ "${target}" == "${MACHINE_ENV}" ]] || rm -f "${MACHINE_ENV}"
echo "== wrote ${target}:"; sed 's/^/   /' "${target}"

if [[ "${fails}" == 0 ]]; then
    unset P6_NO_MACHINE_ENV VLEN COMPILERS OBJDUMP MPIRUN MPIRUN_ARGS RUN_PREFIX LINK_FLAGS
    # shellcheck source=machine.sh
    source "${HERE}/machine.sh"
    p6_profile
fi
echo "== setup done $(date): ${fails} failure(s)"
[[ "${fails}" == 0 ]] && echo "SETUP PASS" || echo "SETUP FAIL"
