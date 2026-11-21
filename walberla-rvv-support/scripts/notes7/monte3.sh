#!/usr/bin/env bash
# notes7: build, verify and time the SweepgenLdcCPU lid-driven cavity on monte3, driven from the laptop.
#
# monte3 = Monte Cimone (University of Bologna), slurm partition "peak": one Sophgo SG2044 node (64 cores,
# RVV 1.0, VLEN 128), reached with `ssh monte3` (x86-64 login node). Plan: docs/notes7/rvv-vlen128-plan-opus5.5.md.
# Self-contained: besides this file it uses only push.to.sh (repo root) and the two helpers next to it,
# ldc_reference.py (NumPy reference solution) and compare_fields.py (field comparison).
#
# On the laptop, from the repo root (walberla-rvv-support):
#   bash scripts/notes7/monte3.sh start [all|build|time]   push the repo, submit the slurm jobs
#   bash scripts/notes7/monte3.sh status                    the jobs and the last lines of their logs
#   bash scripts/notes7/monte3.sh fetch                     copy the logs to 00_private_data/monte3/
#   bash scripts/notes7/monte3.sh help                      what each step does, the rules it follows
# The slurm jobs run this same file on the peak node (modes job-build and job-time).
# Environment (laptop): TIME_BUILD and TIME_RUN, the jobs' time limits (default 06:00:00 each).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
#   Inside a slurm job, sbatch runs a copy of this file from slurm's spool folder, so $0 does not point into the
#   repo there. submit() starts sbatch from the repo root, which slurm passes on as SLURM_SUBMIT_DIR.
if [[ "${1:-}" == job-* && -n "${SLURM_SUBMIT_DIR:-}" ]]; then
    REPO="${SLURM_SUBMIT_DIR}"
    HERE="${REPO}/scripts/notes7"
fi
MACHINE=monte3
REMOTE_REPO=02_ws/my-e4-ws    # push.to.sh's REMOTE_PATHS[monte3] (~/02_ws) + my-e4-ws, relative to the remote home
REMOTE_OUT=02_ws/notes7       # on monte3: build trees, verify dumps, logs/<run>/
LOCAL_OUT="${REPO}/00_private_data/monte3"
STATE="${LOCAL_OUT}/last-run.txt"
TIME_BUILD="${TIME_BUILD:-06:00:00}"
TIME_RUN="${TIME_RUN:-06:00:00}"

SCALAR_VARIANTS="scalar scalar_cse scalar_cse_aa"
VECTOR_VARIANTS="autovec autovec_cse autovec_cse_aa explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
COMPILERS="gcc clang"
PRECISIONS="f64 f32"
CORE_COUNTS="1 4 8 16 32 64"

usage() {
    cat <<EOF
Usage (on the laptop, from the repo root):
  bash scripts/notes7/monte3.sh start [all|build|time]
      all    (default) push the repo to monte3 (push.to.sh), then submit two slurm jobs on the peak node:
             the build job (build, audit, verify; limit ${TIME_BUILD}) and the timing job (limit ${TIME_RUN}),
             which starts only if the build job succeeds
      build  only the build job
      time   only the timing job (times the executables of the last successful build job)
  bash scripts/notes7/monte3.sh status   the jobs (squeue) and the last lines of this run's job logs
  bash scripts/notes7/monte3.sh fetch    copy monte3:${REMOTE_OUT}/logs/ to 00_private_data/monte3/
  bash scripts/notes7/monte3.sh help
EOF
}

cmd_help() {
    usage
    cat <<EOF

What the jobs do (each on the one peak node: sbatch --partition=peak --nodes=1 --exclusive --ntasks-per-node=64):
  build job  load the gcc-14.2.0 module; build Python 3.12.11 from python.org source and the venv in ~/02_ws if
             they are missing; build the 11 SweepgenLdcCPU variants with GCC 14.2 and Clang 17, in f64 and f32
             (scalar variants with -march=rv64gc everywhere; vector variants with waLBerla's flags, whose
             VLEN CMake measures on the node: 128); audit each (last -march, vector instruction counts); verify
             each against the NumPy reference solution and the 1-block/8-block decomposition check; compare
             GCC with Clang. Log: build-<job>.out, details in verify-<cc>-<prec>.log.
  time job   time every verified executable: 60 steps after 10 warm-up steps, 3 interleaved rounds, at 1, 4, 8,
             16, 32 and 64 MPI processes (one 64^3 block each), plus the fair pair (output only in the last
             step); refuses executables that the build job did not verify. Log: time-<job>.out, ldc-*.log.

Rules it follows (monte3 is a public cluster supervised by professors): only sbatch jobs that request what they
use, with time limits; mpirun only inside the job's allocation; writes only under ~/02_ws on monte3; never reads
or sets anything related to power, frequency or temperature; never looks at other users' jobs, processes or
files; network only for the first setup (python.org, PyPI).

Results: 00_private_data/monte3/<run>/ after 'fetch' (logs only; the build trees stay on monte3). Any
publication or report using these data must acknowledge the Monte Cimone project and cite
DOI 10.1007/978-3-032-07612-0_44.
EOF
}

#   =============================== laptop side ===============================

submit() {   # submit <job name> <time limit> <run> <mode> [sbatch options...]: prints the job id
    local name=$1 limit=$2 run=$3 mode=$4; shift 4
    # shellcheck disable=SC2029
    ssh "${MACHINE}" "cd ${REMOTE_REPO} && mkdir -p ../notes7/logs/${run} && sbatch --parsable --job-name=${name} \
        --partition=peak --nodes=1 --exclusive --ntasks-per-node=64 --mem=0 --time=${limit} $* \
        --output=../notes7/logs/${run}/${name#n7-}-%j.out scripts/notes7/monte3.sh ${mode} ${run}" | cut -d';' -f1
}

cmd_start() {
    local what="${1:-all}" run build_job="" time_job=""
    case "${what}" in all|build|time) ;; *) usage; exit 1 ;; esac
    run="$(date +%Y%m%d-%H%M%S)"
    echo "== push the repo to ${MACHINE} (push.to.sh)"
    bash "${REPO}/push.to.sh" "${MACHINE}" || { echo "push failed: nothing submitted"; exit 1; }
    echo "== submit run ${run}"
    if [[ "${what}" != time ]]; then
        build_job="$(submit n7-build "${TIME_BUILD}" "${run}" job-build)"
        [[ "${build_job}" =~ ^[0-9]+$ ]] || { echo "sbatch of the build job failed: ${build_job}"; exit 1; }
        echo "   build job ${build_job} (limit ${TIME_BUILD})"
    fi
    if [[ "${what}" != build ]]; then
        #   --kill-on-invalid-dep: if the build job fails, slurm cancels the timing job instead of keeping it queued
        time_job="$(submit n7-time "${TIME_RUN}" "${run}" job-time ${build_job:+--dependency=afterok:${build_job} --kill-on-invalid-dep=yes})"
        [[ "${time_job}" =~ ^[0-9]+$ ]] || { echo "sbatch of the timing job failed: ${time_job}"; exit 1; }
        echo "   timing job ${time_job} (limit ${TIME_RUN}${build_job:+, starts after the build job succeeds})"
    fi
    mkdir -p "${LOCAL_OUT}"
    printf 'run=%s\nbuild_job=%s\ntime_job=%s\n' "${run}" "${build_job}" "${time_job}" > "${STATE}"
    cat <<EOF

Next:
  bash scripts/notes7/monte3.sh status   (whether the jobs are waiting, running or done; last log lines)
  bash scripts/notes7/monte3.sh fetch    (when they are done, or any time for what is there so far)
Logs on monte3: ~/${REMOTE_OUT}/logs/${run}/
EOF
}

cmd_status() {
    [[ -f "${STATE}" ]] || { echo "No run started from this laptop yet: bash scripts/notes7/monte3.sh start"; exit 1; }
    local run build_job time_job
    # shellcheck disable=SC1090
    source "${STATE}"
    echo "== run ${run}: build job ${build_job:-none}, timing job ${time_job:-none}"
    # shellcheck disable=SC2029,SC2016
    ssh "${MACHINE}" "squeue -u \$USER -o '%.10i %.12j %.9T %.10M %.10l %R'; \
        for f in ${REMOTE_OUT}/logs/${run}/*.out; do [ -f \"\$f\" ] && { echo; echo \"== \$f\"; tail -n 6 \"\$f\"; }; done"
    cat <<EOF

A job missing from the squeue list above has ended; its last log line says how (BUILD PASS/FAIL, TIME DONE).
Next: bash scripts/notes7/monte3.sh fetch
EOF
}

cmd_fetch() {
    mkdir -p "${LOCAL_OUT}"
    echo "== copy ${MACHINE}:~/${REMOTE_OUT}/logs/ to ${LOCAL_OUT}/"
    rsync -a --info=stats1 "${MACHINE}:${REMOTE_OUT}/logs/" "${LOCAL_OUT}/" || exit 1
    cat <<EOF

Results: ${LOCAL_OUT}/<run>/ (one folder per 'start'):
  build-<job>.out   the build job: audit and verification lines, BUILD PASS/FAIL at the end
  verify-*.log      the reference-solution and decomposition checks, with the sha256 of every executable
  time-<job>.out    the timing job, with a best-of table at the end; ldc-*.log, share-*.log: every run
Reports using these data must acknowledge the Monte Cimone project and cite DOI 10.1007/978-3-032-07612-0_44.
EOF
}

#   =============================== node side (inside the slurm jobs) ===============================

node_env() {   # paths, modules, Python environment of the jobs
    RUN="$1"
    BASE="$(dirname "${REPO}")"            # ~/02_ws
    #   Never write anywhere but under the home folder, and only from the real repo copy
    case "${BASE}/" in "${HOME}"/*) ;; *) echo "REFUSED: ${BASE} is not under ${HOME}"; exit 1 ;; esac
    [[ -f "${HERE}/ldc_reference.py" && -d "${REPO}/submodules/walberla" ]] \
        || { echo "REFUSED: ${REPO} is not the repo copy (no scripts/notes7, no submodules/walberla)"; exit 1; }
    OUT="${BASE}/notes7"
    LOGS="${OUT}/logs/${RUN}"
    VERIFIED="${OUT}/verified"             # the verify logs of the last build job: what the timing job may time
    VENV="${BASE}/venv"
    PY="${VENV}/bin/python"
    #   compiler processes: at most one per core and about 2 GB each (the heaviest waLBerla files need ~1.3 GB)
    JOBS="$(awk -v n="$(nproc)" '/^MemTotal/ {j = int($2 / 2097152); print (j < n ? j : n)}' /proc/meminfo)"
    #   The gcc-14.2.0 module's own linker does not find libmpi's dependencies (libopen-rte, libm, ...);
    #   this only tells it where to look at link time, the programs do not change.
    LINK_FLAGS="-Wl,-rpath-link,/usr/lib64/openmpi/lib:/usr/lib64"
    mkdir -p "${LOGS}" "${VERIFIED}"
    set +u
    # shellcheck disable=SC1091
    source /usr/share/Modules/init/bash && module load gcc-14.2.0
    set -u
    export PATH="${VENV}/bin:${PATH}"
    export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
    export XDG_CACHE_HOME="${BASE}/.cache"
    echo "== ${RUN}: job ${SLURM_JOB_ID:-?} on $(hostname), $(date), $(nproc) cores, load $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "   $(gcc --version | head -1); $(clang --version | head -1); $(cmake --version | head -1); $(mpirun --version | head -1)"
}

ensure_python() {   # Python 3.12 (lbmpy 2.1.1 needs it; the node has 3.11) and the venv, built once in ~/02_ws
    local v=3.12.11
    local py="${BASE}/python/${v}/bin/python3"
    if [[ ! -x "${PY}" ]]; then
        if [[ ! -x "${py}" ]]; then
            echo "== build Python ${v} from python.org source into ${BASE}/python/${v} (a few minutes)"
            (
                set -e
                mkdir -p "${OUT}/python-src" && cd "${OUT}/python-src"
                [[ -f "Python-${v}.tgz" ]] || curl -fsSLO "https://www.python.org/ftp/python/${v}/Python-${v}.tgz"
                rm -rf "Python-${v}" && tar xzf "Python-${v}.tgz" && cd "Python-${v}"
                ./configure --prefix="${BASE}/python/${v}" --with-ensurepip=install CC=/usr/bin/gcc
                make -j "${JOBS}" && make install
            ) > "${LOGS}/python-build.log" 2>&1 || { echo "FAIL Python build (log ${LOGS}/python-build.log)"; return 1; }
        fi
        "${py}" -m venv "${VENV}" || return 1
    fi
    #   lbmpy and pystencilssfg without their dependencies: PyPI's pystencils must never shadow the repo's
    if ! "${PY}" -c "import numpy, sympy, appdirs, joblib, packaging, yaml, fasteners, cpuinfo, lbmpy, pystencilssfg" 2> /dev/null; then
        echo "== install the Python packages into ${VENV}"
        { CC=gcc CXX=g++ "${PY}" -m pip install numpy sympy==1.14.0 appdirs joblib packaging pyyaml fasteners py-cpuinfo \
            && "${PY}" -m pip install --no-deps lbmpy==2.1.1 pystencilssfg==0.1.1; } > "${LOGS}/pip.log" 2>&1 \
            || { echo "FAIL pip install (log ${LOGS}/pip.log)"; return 1; }
    fi
    echo "   python $("${PY}" --version 2>&1 | cut -d' ' -f2): $("${PY}" -m pip list 2> /dev/null | grep -i -E '^(numpy|sympy|lbmpy|pystencilssfg) ' | tr -s ' ' | tr '\n' ' ')"
}

exe_of() {   # exe_of <cc> <prec> <variant>: scalar variants live in the -scalar tree
    local tree="${OUT}/build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"
    echo "${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"
}

count_vector() { llvm-objdump -d --no-show-raw-insn "$1" 2> /dev/null | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}'; }

audit() {   # audit <tree> <kind> <target>: the generated sweeps' flags, and vector instructions
    local tree=$1 kind=$2 t=$3 appdir="$1/apps/benchmarks/SweepgenLdcCPU" vlen flags want obj nexe nobj ok=1
    vlen="$(sed -n 's/^WALBERLA_RISCV_VLEN:[A-Z]*=//p' "${tree}/CMakeCache.txt")"
    flags="$("${PY}" - "${tree}/compile_commands.json" "${t}" <<'EOF'
import json, sys
for e in json.load(open(sys.argv[1])):
    if f"_gen/{sys.argv[2]}/gen/SweepgenLdcCPU.cpp" in e["file"]:
        args = (e.get("command") or " ".join(e["arguments"])).split()
        print([a for a in args if a.startswith("-march=")][-1], [a for a in args if a.startswith("-O")][-1])
EOF
)"
    want="-march=rv64gcv_zvl${vlen}b -O3"; [[ "${kind}" == scalar ]] && want="-march=rv64gc -O3"
    obj="$(find "${appdir}/CMakeFiles/${t}.dir" -name 'SweepgenLdcCPU.cpp.o' -path '*_gen*' | head -1)"
    nexe="$(count_vector "${appdir}/${t}")"; nobj="$(count_vector "${obj}")"
    [[ "${flags}" == "${want}" ]] || ok=0
    [[ "${t}" == *_scalar* && "${nexe}" != 0 ]] && ok=0        # scalar: no vector instruction anywhere
    [[ "${t}" == *_explicit* && "${nobj}" == 0 ]] && ok=0      # explicit: RVV code in the generated sweeps
    echo "$( ((ok)) && echo PASS || echo FAIL) audit ${t} ($(basename "${tree}")): ${flags}, VLEN ${vlen:-none}," \
        "vector instructions: executable ${nexe}, generated sweeps ${nobj}"
    ((ok)) || fails=$((fails + 1))
}

build_tree() {   # build_tree <cc> <prec> <scalar|vector>: configure (once), then build and audit its variants
    local cc=$1 prec=$2 kind=$3 cxx=g++ tree variants t extra=()
    [[ "${cc}" == clang ]] && cxx=clang++
    tree="${OUT}/build-${cc}-${prec}"
    variants="${VECTOR_VARIANTS}"
    if [[ "${kind}" == scalar ]]; then
        #   CMAKE_<LANG>_FLAGS_RELEASE come after waLBerla's flags: -march=rv64gc wins in every file
        tree+="-scalar"; variants="${SCALAR_VARIANTS}"
        extra=(-DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc" -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=rv64gc")
    fi
    if [[ ! -f "${tree}/CMakeCache.txt" ]]; then
        cmake -S "${REPO}/submodules/walberla" -B "${tree}" -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER="${cc}" -DCMAKE_CXX_COMPILER="${cxx}" "${extra[@]}" \
            -DCMAKE_EXE_LINKER_FLAGS="${LINK_FLAGS}" -DCMAKE_SHARED_LINKER_FLAGS="${LINK_FLAGS}" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DWALBERLA_DOUBLE_ACCURACY="$([[ "${prec}" == f64 ]] && echo ON || echo OFF)" \
            -DWALBERLA_ENABLE_V8CORE=ON -DWALBERLA_ENABLE_SWEEPGEN=ON -DWALBERLA_SWEEPGEN_MANAGED_VENV=OFF \
            -DPython_EXECUTABLE="${PY}" -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=ON -DWALBERLA_BUILD_WITH_MPI=ON \
            -DWALBERLA_BUILD_BENCHMARKS=ON -DWALBERLA_BUILD_TESTS=OFF -DWALBERLA_BUILD_TOOLS=OFF \
            -DWALBERLA_BUILD_TUTORIALS=OFF -DWALBERLA_BUILD_EXAMPLES=OFF -DWALBERLA_BUILD_SHOWCASES=OFF \
            -DWALBERLA_BUILD_DOC=OFF > "${tree}.configure.log" 2>&1 \
            || { echo "FAIL configure $(basename "${tree}") (log ${tree}.configure.log)"; fails=$((fails + 1)); return; }
    fi
    #   Re-run cmake so that changed sources and new targets are seen
    cmake "${tree}" > "${tree}/reconfigure.log" 2>&1 \
        || { echo "FAIL configure $(basename "${tree}") (log ${tree}/reconfigure.log)"; fails=$((fails + 1)); return; }
    for v in ${variants}; do
        t="SweepgenLdcCPU_${v}"
        #   Regenerate: make does not see changes in pystencils or sweepgen
        rm -f "${tree}/apps/benchmarks/SweepgenLdcCPU/_gen/${t}/gen/SweepgenLdcCPU."{cpp,hpp}
        echo "== build ${t} in $(basename "${tree}") $(date +%T)"
        if cmake --build "${tree}" --target "${t}" -j "${JOBS}" > "${tree}/build-${t}.log" 2>&1; then
            audit "${tree}" "${kind}" "${t}"
        else
            echo "FAIL build ${t} (log ${tree}/build-${t}.log)"; fails=$((fails + 1))
            grep -m 10 -E "error|Error" "${tree}/build-${t}.log" | sed "s/^/   /"
        fi
    done
}

run_app() {   # run_app <np> <cells> <steps> <dump prefix> <exe>: one run; prints its result line
    local out
    if [[ "$1" == 1 ]]; then
        out="$(SWEEPGEN_LDC_DUMP="$4" "$5" "$2" "$3" 0 2>&1)"
    else
        out="$(SWEEPGEN_LDC_DUMP="$4" mpirun -np "$1" --bind-to core --map-by core -x SWEEPGEN_LDC_DUMP "$5" "$2" "$3" 0 2>&1)"
    fi
    grep '^SweepgenLdcCPU variant=' <<< "${out}" || { echo "RUN FAILED np=$1 cells=$2 steps=$3 $5: $(tail -3 <<< "${out}" | tr '\n' ' ')"; return 1; }
}

verify() {   # verify <cc> <prec>: every built executable against the NumPy reference, and the decomposition check
    local cc=$1 prec=$2 log="${LOGS}/verify-$1-$2.log" exes=() cmp dir e line np cells steps nx ny nz ref vfails=0
    [[ "${prec}" == f64 ]] && cmp=(--tol 1e-12 --inv-tol 1e-12) || cmp=(--calibrate 2)
    #   scalar first: in f32 its error against the reference calibrates the thresholds
    for v in ${SCALAR_VARIANTS} ${VECTOR_VARIANTS}; do e="$(exe_of "${cc}" "${prec}" "${v}")"; [[ -x "${e}" ]] && exes+=("${e}"); done
    {
        echo "== verify ${cc} ${prec}, $(date), $(hostname), ${#exes[@]} executables"
        for e in "${exes[@]}"; do echo "sha256 $(sha256sum "${e}" | cut -c1-16) ${e}"; done
    } > "${log}"
    for case in "1 16 100" "1 16 101" "2 16 101" "6 8 101"; do
        read -r np cells steps <<< "${case}"
        dir="${OUT}/verify/${cc}-${prec}/oracle-np${np}-c${cells}-s${steps}"
        mkdir -p "${dir}"
        local dumps=() domains="" links=""
        for e in "${exes[@]}"; do
            line="$(run_app "${np}" "${cells}" "${steps}" "${dir}/$(basename "${e}")" "${e}")" \
                || { echo "${line}" | tee -a "${log}"; vfails=$((vfails + 1)); continue; }
            dumps+=("${dir}/$(basename "${e}")")
            domains+="$(grep -o 'domain=[0-9x]*' <<< "${line}")"$'\n'
            links+="$(grep -o 'links_noslip=[0-9]* links_ubb=[0-9]*' <<< "${line}")"$'\n'
        done
        IFS=x read -r nx ny nz <<< "$(head -1 <<< "${domains}" | cut -d= -f2)"
        ref="$("${PY}" "${HERE}/ldc_reference.py" "${nx}" "${ny}" "${nz}" "${steps}" "${dir}/reference.npz" 2>&1)"
        echo "${ref}" >> "${log}"
        #   one domain for all executables; every executable's wall links are exactly the reference's
        if [[ "$(sort -u <<< "${domains%$'\n'}" | wc -l)" == 1 ]] \
           && [[ "$(sort -u <<< "${links%$'\n'}")" == "$(grep -o 'links_noslip=[0-9]* links_ubb=[0-9]*' <<< "${ref}")" ]] \
           && "${PY}" -I "${HERE}/compare_fields.py" "${cmp[@]}" --label-width 60 "${dir}/reference.npz" "${dumps[@]}" >> "${log}" 2>&1; then
            echo "PASS oracle ${cc} ${prec} np=${np} cells=${cells} steps=${steps}" | tee -a "${log}"
        else
            echo "FAIL oracle ${cc} ${prec} np=${np} cells=${cells} steps=${steps} (see ${log})" | tee -a "${log}"; vfails=$((vfails + 1))
        fi
    done
    #   1 block of 32^3 against 8 blocks of 16^3: the same cavity, bit-identical fields
    dir="${OUT}/verify/${cc}-${prec}/decomp"
    mkdir -p "${dir}"
    for e in "${exes[@]}"; do
        local v l1 l8
        v="$(basename "${e}")"
        if l1="$(run_app 1 32 61 "${dir}/${v}-np1" "${e}")" && l8="$(run_app 8 16 61 "${dir}/${v}-np8" "${e}")" \
           && [[ "$(grep -o 'fieldhash=[^ ]*' <<< "${l1}")" == "$(grep -o 'fieldhash=[^ ]*' <<< "${l8}")" ]] \
           && "${PY}" -I "${HERE}/compare_fields.py" --tol 0 --inv-tol inf --label-width 60 "${dir}/${v}-np1" "${dir}/${v}-np8" >> "${log}" 2>&1; then
            echo "PASS decomp ${cc} ${prec} ${v}" | tee -a "${log}"
        else
            echo "FAIL decomp ${cc} ${prec} ${v} (see ${log})" | tee -a "${log}"; vfails=$((vfails + 1))
        fi
    done
    [[ "${vfails}" == 0 ]] && echo "VERIFY PASS" >> "${log}" || echo "VERIFY FAIL" >> "${log}"
    fails=$((fails + vfails))
}

compare_compilers() {   # compare_compilers <prec>: Clang's fields against the GCC scalar build's, per reference case
    local prec=$1 d c others cmp
    [[ "${prec}" == f64 ]] && cmp=(--tol 2e-12 --inv-tol 1e-12) || cmp=(--calibrate 2)
    for d in "${OUT}/verify/gcc-${prec}"/oracle-*; do
        c="${OUT}/verify/clang-${prec}/$(basename "${d}")"
        #   the Clang builds that exist (a failed build is already counted), its scalar build first
        others=("${c}/SweepgenLdcCPU_scalar")
        for v in ${SCALAR_VARIANTS} ${VECTOR_VARIANTS}; do
            [[ "${v}" != scalar && -f "${c}/SweepgenLdcCPU_${v}.rank0.bin" ]] && others+=("${c}/SweepgenLdcCPU_${v}")
        done
        if "${PY}" -I "${HERE}/compare_fields.py" "${cmp[@]}" --label-width 60 "${d}/SweepgenLdcCPU_scalar" "${others[@]}" \
            >> "${LOGS}/compilers-${prec}.log" 2>&1; then
            echo "PASS compilers ${prec} $(basename "${d}")"
        else
            echo "FAIL compilers ${prec} $(basename "${d}") (see ${LOGS}/compilers-${prec}.log)"; fails=$((fails + 1))
        fi
    done
}

job_build() {
    fails=0
    node_env "$1"
    ensure_python || { echo "BUILD FAIL (environment)"; exit 1; }
    for prec in ${PRECISIONS}; do
        for cc in ${COMPILERS}; do
            build_tree "${cc}" "${prec}" scalar
            build_tree "${cc}" "${prec}" vector
            echo "== verify ${cc} ${prec} $(date +%T)"
            verify "${cc}" "${prec}"
        done
        compare_compilers "${prec}"
    done
    cp "${LOGS}"/verify-*.log "${VERIFIED}/"
    echo "== build job done $(date): ${fails} failure(s)"
    [[ "${fails}" == 0 ]] && { echo "BUILD PASS"; exit 0; } || { echo "BUILD FAIL"; exit 1; }
}

busy_cores() {   # the cores busier than 3 % over 1 s (two samples of /proc/stat)
    local a b
    a="$(grep -E '^cpu[0-9]' /proc/stat)"; sleep 1; b="$(grep -E '^cpu[0-9]' /proc/stat)"
    paste <(echo "${a}") <(echo "${b}") | awk '{
        n = (NF - 2) / 2; ta = 0; tb = 0
        for (i = 2; i <= n + 1; i++) ta += $i
        for (i = n + 3; i <= NF; i++) tb += $i
        ia = $5 + $6; ib = $(n + 6) + $(n + 7)
        busy = (tb - ta) > 0 ? 100 * (1 - (ib - ia) / (tb - ta)) : 0
        if (busy > 3) s = s sprintf(" %s=%.0f%%", $1, busy)
    } END { print "busy cores (>3 % over 1 s):" (s == "" ? " none" : s) }'
}

time_group() {   # time_group <cc> <prec> <cores> <variant>...: 3 interleaved rounds of 60 timed steps each
    local cc=$1 prec=$2 cores=$3 vlog e h r out; shift 3
    vlog="${VERIFIED}/verify-${cc}-${prec}.log"
    echo "== ${cc} ${prec}, ${cores} core(s), 64^3 cells per core, 60 steps (+10 warm-up), 3 interleaved rounds," \
        "output ${SWEEPGEN_LDC_OUTPUT:-every}: $*"
    grep -q "VERIFY PASS" "${vlog}" 2> /dev/null || { echo "SKIPPED: ${vlog} has no VERIFY PASS"; return; }
    for v in "$@"; do
        e="$(exe_of "${cc}" "${prec}" "${v}")"
        h="$(sha256sum "${e}" 2> /dev/null | cut -c1-16)"
        grep -q -x "sha256 ${h} ${e}" "${vlog}" || { echo "SKIPPED: ${e} is not the verified executable"; return; }
    done
    for r in 1 2 3; do
        echo "== round ${r} $(date +%T), load $(cut -d' ' -f1-3 /proc/loadavg), $(busy_cores)"
        for v in "$@"; do
            e="$(exe_of "${cc}" "${prec}" "${v}")"
            if [[ "${cores}" == 1 ]]; then
                out="$(taskset -c 2 "${e}" 64 60 10 2>&1)"
            else
                out="$(mpirun -np "${cores}" --bind-to core --map-by core "${e}" 64 60 10 2>&1)"
            fi
            grep '^SweepgenLdcCPU variant=' <<< "${out}" || echo "SweepgenLdcCPU_${v} FAILED: $(tail -3 <<< "${out}" | tr '\n' ' ')"
        done
    done
}

job_time() {
    node_env "$1"
    local cc prec cores group
    declare -A GROUP=([scalar]="${SCALAR_VARIANTS}" [autovec]="autovec autovec_cse autovec_cse_aa"
                      [rvv]="explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split")
    for cc in ${COMPILERS}; do
        for prec in f32 f64; do
            for cores in ${CORE_COUNTS}; do
                for group in scalar autovec rvv; do
                    echo "== ${cc} ${group} ${prec} ${cores} core(s) $(date +%T)"
                    # shellcheck disable=SC2086
                    time_group "${cc}" "${prec}" "${cores}" ${GROUP[${group}]} > "${LOGS}/ldc-${cc}-${group}-${prec}-${cores}core.log" 2>&1
                    grep -E "FAILED|SKIPPED" "${LOGS}/ldc-${cc}-${group}-${prec}-${cores}core.log"
                done
            done
            #   The fair pair: best scalar and the two fastest RVV builds, rho and u written in every step or
            #   only in the last one (the scalar build then also needs fewer memory streams)
            for mode in every last; do
                if [[ "${mode}" == last ]]; then export SWEEPGEN_LDC_OUTPUT=last; else unset SWEEPGEN_LDC_OUTPUT; fi
                time_group "${cc}" "${prec}" 1 scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split > "${LOGS}/share-${cc}-${prec}-${mode}.log" 2>&1
            done
            unset SWEEPGEN_LDC_OUTPUT
        done
    done
    echo
    echo "== best MLUP/s per experiment and variant (all cores together)"
    for f in "${LOGS}"/ldc-*.log "${LOGS}"/share-*.log; do
        awk -v f="$(basename "${f}" .log)" '/^SweepgenLdcCPU variant=/ {
            for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "variant") v = kv[2]; if (kv[1] == "mlups") m = kv[2] }
            sub("SweepgenLdcCPU_", "", v); if (m > best[v]) best[v] = m
        } END { for (v in best) printf "%-28s %-24s %8.2f\n", f, v, best[v] }' "${f}"
    done
    echo "TIME DONE $(date)"
}

#   =============================== dispatch ===============================

case "${1:-help}" in
    start)     shift; cmd_start "$@" ;;
    status)    cmd_status ;;
    fetch)     cmd_fetch ;;
    help|-h|--help) cmd_help ;;
    job-build) [[ -n "${SLURM_JOB_ID:-}" ]] || { echo "job-build runs inside a slurm job (use: start)"; exit 1; }; job_build "$2" ;;
    job-time)  [[ -n "${SLURM_JOB_ID:-}" ]] || { echo "job-time runs inside a slurm job (use: start)"; exit 1; }; job_time "$2" ;;
    *)         usage; exit 1 ;;
esac
