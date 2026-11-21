#!/usr/bin/env bash
# Correctness checks of SweepgenLdcCPU builds (copied from scripts/presentation4; docs/presentation4, plan section
# "the verification chain"). The default PY is <base>/venv/bin/python, as on both boards.
# Runs on the laptop (x86) and on the board alike.
#
# Usage: bash scripts/presentation6/verify.sh <outdir> <f32|f64> <executable>...
#   The executables are SweepgenLdcCPU_<variant> binaries of one precision and one compiler. For f32
#   the first one must be the scalar build: it calibrates the f32 thresholds.
#
# Checks, each with its own PASS/FAIL line in <outdir>/verify.log (and stdout):
#   1. oracle   each executable's fields against ldc_reference.py (NumPy, f64), cell by cell, on
#               non-cubic domains and odd and even step counts: 1 process 16^3 (100 and 101 steps),
#               2 processes of 16^3 and 6 processes of 8^3 (101 steps).
#               f64: max |d rho|, max |d u|, mass error and z-mirror asymmetry <= 1e-12.
#               f32: at most 2x the error of the scalar f32 build (compare_fields.py --calibrate 2).
#   2. decomp   each executable: 1 block of 32^3 against 8 blocks of 16^3 (same 32^3 cavity, 61 steps)
#               must give bit-identical fields.
# Every run's result line goes to <outdir>/results.log, the field dumps to <outdir>/<check>/.
#
# Environment: PY (python with numpy and lbmpy; default: the board venv if it exists, else python3),
#   MPIRUN (default mpirun), MPIRUN_ARGS (e.g. "--bind-to core --map-by core"), CORE (taskset core
#   for one-process runs; unset = no pinning), RUN_PREFIX (put before one-process runs; presentation6:
#   "mpirun -np 1 --bind-to none" on monte3).
set -u

OUT="$1"; PREC="$2"; shift 2
EXES=("$@")
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
if [[ -z "${PY:-}" ]]; then
    if [[ -x "${BASE}/venv/bin/python" ]]; then PY="${BASE}/venv/bin/python"; else PY=python3; fi
fi
MPIRUN="${MPIRUN:-mpirun}"
MPIRUN_ARGS="${MPIRUN_ARGS:-}"
export PYTHONPATH="${REPO}/submodules/pystencils/src${PYTHONPATH:+:${PYTHONPATH}}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${BASE}/.cache}"

case "${PREC}" in
    f64) CMP=(--tol 1e-12 --inv-tol 1e-12) ;;
    f32) CMP=(--calibrate 2) ;;
    *) echo "usage: $0 <outdir> <f32|f64> <executable>..."; exit 2 ;;
esac
[[ ${#EXES[@]} -gt 0 ]] || { echo "no executables given"; exit 2; }
for e in "${EXES[@]}"; do [[ -x "${e}" ]] || { echo "not executable: ${e}"; exit 2; }; done

mkdir -p "${OUT}"
LOG="${OUT}/verify.log"
RESULTS="${OUT}/results.log"
: > "${LOG}"; : > "${RESULTS}"
say() { echo "$*" | tee -a "${LOG}"; }
fails=0
say "== verify ${PREC}, $(date), $(uname -m), ${#EXES[@]} executable(s)"
for e in "${EXES[@]}"; do say "   sha256 $(sha256sum "${e}" | cut -c1-16) ${e}"; done

#   run <procs> <cells> <steps> <dump prefix> <exe>: one app run, result line to results.log
run() {
    local np="$1" cells="$2" steps="$3" dump="$4" exe="$5" out
    if [[ "${np}" == 1 ]]; then
        if [[ -n "${CORE:-}" ]]; then
            out="$(SWEEPGEN_LDC_DUMP="${dump}" ${RUN_PREFIX:-} taskset -c "${CORE}" "${exe}" "${cells}" "${steps}" 0 2>&1)"
        else
            out="$(SWEEPGEN_LDC_DUMP="${dump}" ${RUN_PREFIX:-} "${exe}" "${cells}" "${steps}" 0 2>&1)"
        fi
    else
        # shellcheck disable=SC2086
        out="$(SWEEPGEN_LDC_DUMP="${dump}" ${MPIRUN} -np "${np}" ${MPIRUN_ARGS} -x SWEEPGEN_LDC_DUMP "${exe}" "${cells}" "${steps}" 0 2>&1)"
    fi
    local line
    line="$(grep '^SweepgenLdcCPU variant=' <<< "${out}")"
    if [[ -z "${line}" ]]; then
        say "RUN FAILED np=${np} cells=${cells} steps=${steps} ${exe}:"; tail -5 <<< "${out}" | tee -a "${LOG}"
        return 1
    fi
    echo "${line}" >> "${RESULTS}"
    echo "${line}"
}

#   1. Oracle comparisons
for cfg in "1 16 100" "1 16 101" "2 16 101" "6 8 101"; do
    read -r np cells steps <<< "${cfg}"
    dir="${OUT}/oracle-np${np}-c${cells}-s${steps}"
    mkdir -p "${dir}"
    say ""
    say "== oracle: ${np} process(es), ${cells}^3 cells each, ${steps} steps"
    dumps=(); domain=""; links=()
    for e in "${EXES[@]}"; do
        v="$(basename "${e}")"
        line="$(run "${np}" "${cells}" "${steps}" "${dir}/${v}" "${e}")" || { fails=$((fails + 1)); continue; }
        d="$(grep -o 'domain=[0-9x]*' <<< "${line}" | cut -d= -f2)"
        if [[ -z "${domain}" ]]; then domain="${d}"; elif [[ "${d}" != "${domain}" ]]; then
            say "DOMAIN MISMATCH ${v}: ${d} != ${domain}"; fails=$((fails + 1)); fi
        dumps+=("${dir}/${v}")
        links+=("${v} $(grep -o 'links_noslip=[0-9]* links_ubb=[0-9]*' <<< "${line}")")
        say "   $(grep -o 'variant=[^ ]*\|links_noslip=[^ ]*\|links_ubb=[^ ]*\|fieldhash=[^ ]*' <<< "${line}" | tr '\n' ' ')"
    done
    [[ -n "${domain}" ]] || continue
    IFS=x read -r nx ny nz <<< "${domain}"
    ref="$("${PY}" "${HERE}/ldc_reference.py" "${nx}" "${ny}" "${nz}" "${steps}" "${dir}/reference.npz" 2>&1)"
    say "${ref}"
    #   The app's wall links must be exactly the oracle's (same counts per wall type)
    ref_links="$(grep -o 'links_noslip=[0-9]* links_ubb=[0-9]*' <<< "${ref}")"
    for l in "${links[@]}"; do
        if [[ "${l#* }" == "${ref_links}" && -n "${ref_links}" ]]; then :; else
            say "FAIL links ${l} != oracle ${ref_links}"; fails=$((fails + 1)); fi
    done
    if "${PY}" -I "${HERE}/compare_fields.py" "${CMP[@]}" --label-width 60 "${dir}/reference.npz" "${dumps[@]}" \
        >> "${LOG}" 2>&1; then say "PASS oracle np=${np} cells=${cells} steps=${steps}"
    else say "FAIL oracle np=${np} cells=${cells} steps=${steps} (details above in ${LOG})"; fails=$((fails + 1)); fi
done

#   2. Decomposition: 1 x 32^3 against 8 x 16^3, bit-identical
dir="${OUT}/decomp"
mkdir -p "${dir}"
say ""
say "== decomposition: 1 x 32^3 against 8 x 16^3, 61 steps, must be bit-identical"
for e in "${EXES[@]}"; do
    v="$(basename "${e}")"
    l1="$(run 1 32 61 "${dir}/${v}-np1" "${e}")" || { fails=$((fails + 1)); continue; }
    l8="$(run 8 16 61 "${dir}/${v}-np8" "${e}")" || { fails=$((fails + 1)); continue; }
    h1="$(grep -o 'fieldhash=[^ ]*' <<< "${l1}")"; h8="$(grep -o 'fieldhash=[^ ]*' <<< "${l8}")"
    if "${PY}" -I "${HERE}/compare_fields.py" --tol 0 --inv-tol inf --label-width 60 "${dir}/${v}-np1" "${dir}/${v}-np8" \
        >> "${LOG}" 2>&1 && [[ "${h1}" == "${h8}" ]]; then say "PASS decomp ${v} (${h1})"
    else say "FAIL decomp ${v} (${h1} vs ${h8})"; fails=$((fails + 1)); fi
done

say ""
say "== verify done $(date): ${fails} failure(s)"
[[ "${fails}" == 0 ]] && say "VERIFY PASS" || say "VERIFY FAIL"
exit $(( fails > 0 ))
