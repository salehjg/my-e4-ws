#!/usr/bin/env bash
# presentation4 stages 2 and 3 on the board: build every SweepgenLdcCPU variant with GCC and Clang for
# one precision, audit the builds, and check the results. Run this (and pass it) before all.sh: all.sh
# times exactly the executables built and verified here (the logs record their sha256).
#
# Usage: bash scripts/presentation4/prepare.sh <f32|f64> [gcc|clang ...]   (default: both compilers)
# Start it on the board, detached, so it survives a lost connection:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-prepare bash -c \
#       "bash scripts/presentation4/prepare.sh f64 > ../presentation4/logs/prepare-f64.log 2>&1"
#
# Steps per compiler, each with a log in LOGDIR (default <base>/presentation4/logs):
#   build-<cc>-<prec>.log        REGEN=1 BUILD_ONLY=1 run.sh: configure, generate, compile all 11 variants
#   check-<cc>-<prec>.log        check_build.py on the scalar and the vector tree, check_walls.py
#   verify-<cc>-<prec>.log       verify.sh (oracle and decomposition checks; dumps in <base>/presentation4/verify)
# Then, if both compilers ran, the GCC and Clang fields against each other: compilers-<prec>.log.
# The last line says PREPARE PASS or PREPARE FAIL.
set -u

PREC="$1"; shift
COMPILERS="${*:-gcc clang}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
VENV="${VENV:-${BASE}/venv}"
PY="${VENV}/bin/python"
mkdir -p "${LOGDIR}" "${P4DIR}/verify"

SCALAR="scalar scalar_cse scalar_cse_aa"
VECTOR="autovec autovec_cse autovec_cse_aa explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
fails=0
echo "== prepare ${PREC}: ${COMPILERS}, start $(date)"

for cc in ${COMPILERS}; do
    st="${P4DIR}/build-${cc}-${PREC}-scalar"
    vt="${P4DIR}/build-${cc}-${PREC}"
    echo "== ${cc} ${PREC}: build $(date +%T)"
    REGEN=1 BUILD_ONLY=1 bash "${HERE}/run.sh" "${cc}" "${PREC}" 1 ${SCALAR} ${VECTOR} > "${LOGDIR}/build-${cc}-${PREC}.log" 2>&1
    grep -E "BUILD FAILED|CONFIGURE FAILED|RVV instructions|compile:" "${LOGDIR}/build-${cc}-${PREC}.log"
    if grep -q -E "BUILD FAILED|CONFIGURE FAILED" "${LOGDIR}/build-${cc}-${PREC}.log"; then
        echo "FAIL build ${cc} ${PREC}"; fails=$((fails + 1)); continue
    fi

    echo "== ${cc} ${PREC}: build audit $(date +%T)"
    {
        "${PY}" "${HERE}/check_build.py" "${st}" scalar "${cc}" $(for v in ${SCALAR}; do echo "SweepgenLdcCPU_${v}"; done)
        "${PY}" "${HERE}/check_build.py" "${vt}" vector "${cc}" $(for v in ${VECTOR}; do echo "SweepgenLdcCPU_${v}"; done)
        "${PY}" "${HERE}/check_walls.py" "${st}"/apps/benchmarks/SweepgenLdcCPU/_gen/*/gen/SweepgenLdcCPU.cpp \
                                         "${vt}"/apps/benchmarks/SweepgenLdcCPU/_gen/*/gen/SweepgenLdcCPU.cpp
    } > "${LOGDIR}/check-${cc}-${PREC}.log" 2>&1
    grep -E "^(PASS|FAIL|INFO|CHECK_)" "${LOGDIR}/check-${cc}-${PREC}.log"
    #   Pass only with both build audits and the wall check passed (a crashed check prints no PASS line)
    if grep -q -E "^FAIL|CHECK_BUILD FAIL|CHECK_WALLS FAIL" "${LOGDIR}/check-${cc}-${PREC}.log" \
       || [[ "$(grep -c "^CHECK_BUILD PASS" "${LOGDIR}/check-${cc}-${PREC}.log")" != 2 ]] \
       || ! grep -q "^CHECK_WALLS PASS" "${LOGDIR}/check-${cc}-${PREC}.log"; then
        echo "FAIL audit ${cc} ${PREC}"; fails=$((fails + 1))
    fi

    echo "== ${cc} ${PREC}: verify $(date +%T)"
    exes=()
    for v in ${SCALAR}; do exes+=("${st}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"); done
    for v in ${VECTOR}; do exes+=("${vt}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"); done
    rm -rf "${P4DIR}/verify/${cc}-${PREC}"
    MPIRUN_ARGS="--bind-to core --map-by core" PY="${PY}" \
        bash "${HERE}/verify.sh" "${P4DIR}/verify/${cc}-${PREC}" "${PREC}" "${exes[@]}" > /dev/null 2>&1
    cp "${P4DIR}/verify/${cc}-${PREC}/verify.log" "${LOGDIR}/verify-${cc}-${PREC}.log"
    cp "${P4DIR}/verify/${cc}-${PREC}/results.log" "${LOGDIR}/verify-${cc}-${PREC}-results.log"
    grep -E "^(PASS|FAIL|RUN FAILED|VERIFY)" "${LOGDIR}/verify-${cc}-${PREC}.log"
    grep -q "VERIFY PASS" "${LOGDIR}/verify-${cc}-${PREC}.log" || { echo "FAIL verify ${cc} ${PREC}"; fails=$((fails + 1)); }
done

#   GCC against Clang: every Clang build's fields against the GCC scalar build, for each oracle case.
#   Not bit-identical (the compilers contract multiply-adds differently); both must agree with the
#   oracle, so they agree with each other within twice the oracle tolerance.
if [[ "${COMPILERS}" == *gcc* && "${COMPILERS}" == *clang* ]]; then
    {
        for d in "${P4DIR}/verify/gcc-${PREC}"/oracle-*; do
            c="${P4DIR}/verify/clang-${PREC}/$(basename "${d}")"
            [[ -d "${c}" ]] || continue
            echo "== $(basename "${d}"): GCC scalar against all Clang builds"
            others=("${c}/SweepgenLdcCPU_scalar")
            for f in "${c}"/SweepgenLdcCPU_*.rank0.bin; do
                [[ "${f}" == */SweepgenLdcCPU_scalar.rank0.bin ]] || others+=("${f%.rank0.bin}")
            done
            if [[ "${PREC}" == f64 ]]; then cmp=(--tol 2e-12 --inv-tol 1e-12); else cmp=(--calibrate 2); fi
            # f32: calibrated on the Clang scalar build (listed first among the others)
            "${PY}" "${HERE}/compare_fields.py" "${cmp[@]}" --label-width 60 "${d}/SweepgenLdcCPU_scalar" "${others[@]}" \
                && echo "PASS compilers $(basename "${d}")" || echo "FAIL compilers $(basename "${d}")"
        done
    } > "${LOGDIR}/compilers-${PREC}.log" 2>&1
    grep -E "^(PASS|FAIL)" "${LOGDIR}/compilers-${PREC}.log"
    #   One PASS per oracle case of verify.sh, no FAIL
    ncases="$(ls -d "${P4DIR}/verify/gcc-${PREC}"/oracle-* 2>/dev/null | wc -l)"
    if grep -q "^FAIL" "${LOGDIR}/compilers-${PREC}.log" || [[ "${ncases}" == 0 ]] \
       || [[ "$(grep -c "^PASS compilers" "${LOGDIR}/compilers-${PREC}.log")" != "${ncases}" ]]; then
        echo "FAIL compilers ${PREC}"; fails=$((fails + 1))
    fi
fi

echo "== prepare ${PREC} done $(date): ${fails} failure(s)"
[[ "${fails}" == 0 ]] && echo "PREPARE PASS" || echo "PREPARE FAIL"
