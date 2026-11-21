#!/usr/bin/env bash
# presentation6: read-only report on a machine, for setup.sh and the other presentation6 scripts. It installs
# nothing, downloads nothing and changes nothing; it only reads system information about this machine and our
# own allocation, and compiles and runs a few small test programs in a temporary directory that it deletes again.
#
# monte3, on the login node (x86-64), in <base>/my-e4-ws:
#     bash scripts/presentation6/recon.sh 2>&1 | tee ../recon-2.txt
#   prints the partition's limits, then submits itself as a batch job through peak.sbatch (one whole peak node,
#   64 tasks, at most 20 min), waits for it and prints its output. Paste the whole output back.
# Already on a peak node, or on bananapi:  bash scripts/presentation6/recon.sh --node
#   (MPI tests with 8 processes need an allocation with at least 8 tasks)
# Environment: MODULES (compiler modules to try, default "gcc-14.2.0"), MPI_MODULES (default "openmpi-5.0.6")
#
# Round 1 (2026-11-20) found: openEuler 24.03, VLEN 128, Python 3.11 at most, system Open MPI 4.1.5, network
# to PyPI works. Round 2 looks at: the GCC 14 module (round 1 loaded it in a subshell, so it was never tested),
# its C++ runtime, both MPIs inside a batch allocation, and the headers needed to build Python 3.12 from source.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
MODULES="${MODULES:-gcc-14.2.0}"
MPI_MODULES="${MPI_MODULES:-openmpi-5.0.6}"

s() { printf '\n######## %s\n' "$*"; }
t() { printf '  %-14s %s\n' "$1" "$(command -v "$1" 2>/dev/null || echo MISSING)"; }
v() { "$@" 2>&1 | head -1; }   # first line of a version command
# a command with a time limit, its first lines and its exit status
r() { local to="$1"; shift; echo "\$ $*"; timeout "${to}" "$@" 2>&1 | head -24; echo "  -> exit ${PIPESTATUS[0]}"; }

login_side() {
    s "login node: partition peak"
    echo "host $(hostname), $(uname -srm), $(v sinfo --version)"
    sinfo -p peak -N -o '%N %c %m %T %l' 2>&1
    scontrol show partition peak 2>&1 | tr -s ' ' '\n' | grep -E '^(MaxTime|DefaultTime|Nodes|OverSubscribe|MaxNodes|DefMemPerCPU|DefMemPerNode|MaxMemPerNode|State)=' | tr '\n' ' '; echo
}

node_side() {
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/p6-recon.XXXXXX")"
    trap 'rm -rf "${TMP}"' EXIT

    s "host and allocation"
    echo "host $(hostname), $(uname -srm)"
    grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null
    echo "date -u: $(date -u '+%F %T'), load: $(cut -d' ' -f1-3 /proc/loadavg)"
    env | grep -E '^SLURM_(JOB_ID|JOB_NODELIST|NTASKS|TASKS_PER_NODE|CPUS_ON_NODE|JOB_CPUS_PER_NODE)=' | sort | tr '\n' ' '; echo
    echo "nproc $(nproc), $(grep Cpus_allowed_list /proc/self/status | tr -s '\t' ' ')"
    echo "repo files dated in the future (clock behind the laptop): $(find "${REPO}" -newermt now 2>/dev/null | wc -l)"
    echo "free space: $(df -h --output=avail "${BASE}" | tail -1) in ${BASE}, $(df -h --output=avail /tmp | tail -1) in /tmp"

    s "tools in the default environment"
    local x
    for x in gcc g++ clang clang++ cmake make ninja mpirun mpicc llvm-objdump objdump taskset tmux; do t "${x}"; done
    for x in gcc clang cmake; do command -v "${x}" >/dev/null && echo "  ${x}: $(v "${x}" --version)"; done

    s "environment modules"
    set +u
    # shellcheck disable=SC1091
    source /usr/share/Modules/init/bash 2>/dev/null || source /etc/profile.d/modules.sh 2>/dev/null
    set -u
    type module > /dev/null 2>&1 || { echo "no environment modules on this machine"; module() { return 1; }; }
    local m
    for m in ${MODULES} ${MPI_MODULES}; do
        echo "-- module show ${m}:"; module show "${m}" 2>&1 | grep -E 'prepend-path|setenv|module load|prereq' | head -8
    done

    cat > "${TMP}/vlen.c" <<'C'
#include <stdio.h>
#include <riscv_vector.h>
int main(void) {
    unsigned long vlenb;
    __asm__ volatile("csrr %0, vlenb" : "=r"(vlenb));
    printf("VLEN %lu bits (vlenb register), vsetvlmax_e8m1 %zu lanes\n", vlenb * 8, (size_t)__riscv_vsetvlmax_e8m1());
    return 0;
}
C
    cat > "${TMP}/rt.cpp" <<'C'
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <vector>
int main() {
    std::vector<double> a(100003);
    for (std::size_t i = 0; i < a.size(); ++i) a[i] = std::sqrt(double(i)) * 0.5 + 1.0;
    double s = 0; for (double x : a) s += x;
    std::thread t([] {}); t.join();
    try { throw std::runtime_error("ok"); } catch (const std::exception &e) { std::printf("exception %s, ", e.what()); }
    std::printf("sum %.17g\n", s);
}
C
    cat > "${TMP}/mpi.c" <<'C'
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
    compiler_test() {   # compiler_test <cc> <label>: VLEN probe, configured defaults, C++ runtime
        local cc="$1" f="${TMP}/$2" cxx=g++
        [[ "${cc}" == clang ]] && cxx=clang++
        echo "-- $2: $(command -v "${cc}"): $(v "${cc}" --version)"
        if "${cc}" -O2 -march=rv64gcv "${TMP}/vlen.c" -o "${f}" 2> "${f}.err"; then echo "  $("${f}")"; else echo "  RVV probe does not compile: $(head -2 "${f}.err" | tr '\n' ' ')"; fi
        echo "  configured: $("${cc}" -v 2>&1 | grep -o -E -- '--with-(arch|abi|tune)=[^ ]*|Selected GCC installation: .*' | tr '\n' ' ')"
        if "${cxx}" -O3 -march=rv64gcv_zvl128b "${TMP}/rt.cpp" -o "${f}-rt" -pthread 2> "${f}-rt.err"; then
            echo "  C++ runtime test: $("${f}-rt" 2>&1 | head -2 | tr '\n' ' ')(libstdc++: $(ldd "${f}-rt" | grep -o '/[^ ]*libstdc++[^ ]*'))"
        else echo "  C++ runtime test does not compile: $(head -3 "${f}-rt.err" | tr '\n' ' ')"; fi
    }
    s "compilers"
    command -v gcc > /dev/null && compiler_test gcc system-gcc
    command -v clang > /dev/null && compiler_test clang system-clang
    for m in ${MODULES}; do
        (
            set +u; module load "${m}" > "${TMP}/mod.out" 2>&1
            module is-loaded "${m}" && echo "-- module ${m}: loaded" || echo "-- module ${m}: NOT LOADED: $(head -3 "${TMP}/mod.out")"; set -u
            compiler_test gcc "module-${m}"
            echo "  objdump with this module: $(command -v objdump) ($(v objdump --version))"
        )
    done

    mpi_tests() {   # mpi_tests <label>: the current environment's MPI inside this allocation
        echo "-- MPI $1: $(command -v mpirun) ($(v mpirun --version)), mpicc: $(mpicc --showme 2>&1 | head -1)"
        if ! mpicc -O2 "${TMP}/mpi.c" -o "${TMP}/mpi-$1" 2> "${TMP}/mpi.err"; then echo "  mpicc failed: $(head -5 "${TMP}/mpi.err")"; return; fi
        export P6_TEST_VAR=seen
        r 60 mpirun -np 8 --bind-to core --map-by core --report-bindings "${TMP}/mpi-$1"
        r 60 taskset -c 2 "${TMP}/mpi-$1"
        r 60 mpirun -np 1 --bind-to none taskset -c 2 "${TMP}/mpi-$1"
    }
    s "MPI (allocation: ${SLURM_NTASKS:-no slurm} tasks)"
    ( mpi_tests system )
    for m in ${MPI_MODULES}; do
        (
            set +u; for c in ${MODULES}; do module load "${c}" > /dev/null 2>&1; done
            module load "${m}" > "${TMP}/mod.out" 2>&1
            module is-loaded "${m}" && echo "-- module ${m}: loaded" || echo "-- module ${m}: NOT LOADED: $(head -3 "${TMP}/mod.out")"; set -u
            mpi_tests "module-${m}"
        )
    done

    s "building Python 3.12 from source: compiler and headers present?"
    rpm -q gcc make openssl-devel zlib-devel libffi-devel bzip2-devel xz-devel sqlite-devel readline-devel ncurses-devel libuuid-devel 2>&1 | sed 's/^/  /'
}

echo "presentation6 recon, $(date -u '+%F %T') UTC, $(hostname), $(uname -m)"
if [[ "${1:-}" == --node || "$(uname -m)" == riscv64 ]]; then
    node_side
elif command -v sbatch > /dev/null; then
    login_side
    mkdir -p "${BASE}/presentation6/logs"
    s "node side: batch job through peak.sbatch (whole peak node, 64 tasks, at most 20 min); waiting for it"
    out="$(cd "${REPO}" && sbatch --wait --parsable -J p6-recon --time=00:20:00 scripts/presentation6/peak.sbatch recon.sh --node)"
    echo "job ${out%%;*} done"
    cat "${BASE}/presentation6/logs/p6-recon-${out%%;*}.out" 2>&1
else
    node_side
fi
echo; echo "== RECON DONE $(date -u '+%F %T')"
