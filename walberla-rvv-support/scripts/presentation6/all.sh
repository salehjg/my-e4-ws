#!/usr/bin/env bash
# presentation6: everything on this machine, one part after the other, each with its own log in LOGDIR
# (default <base>/presentation6/logs). PARTS selects, in this order:
#   prepare   prepare.sh f64, then f32: build, audit and verify every variant this machine supports  prepare-<prec>.log
#   steps     steps_check.sh: are 60 timed steps enough here? (repeat on every new machine)          steps.log
#   matrix    matrix.sh: the timing matrix and the fair pair (part share)                            matrix.log
#   thermal   thermal_check.sh: does a long all-core run throttle?                                    thermal.log
# Default PARTS="prepare steps matrix". At the end, one status line per part.
#
# bananapi, detached (prepare about 7 h with 2 jobs; BUILD_ROOT=<base>/presentation4 PARTS="steps matrix" times the
# executables presentation4 already verified):
#   cd /home/bananapi/saleh/my-e4-ws && mkdir -p ../presentation6/logs && screen -dmS presentation6-all \
#       bash -c "bash scripts/presentation6/all.sh > ../presentation6/logs/all.log 2>&1"
# monte3: through peak.sbatch (one whole peak node), after setup.sh has passed.
# See what it would run, without running anything:  DRY_RUN=1 bash scripts/presentation6/all.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
PARTS="${PARTS:-prepare steps matrix}"
DRY_RUN="${DRY_RUN:-0}"
mkdir -p "${LOGDIR}"
echo "== presentation6 all.sh, start $(date), parts: ${PARTS}$( [[ "${DRY_RUN}" == 1 ]] && echo ', DRY RUN: nothing is run')"
p6_profile
for part in ${PARTS}; do
    case "${part}" in prepare|steps|matrix|thermal) ;; *) echo "ALL ABORTED: unknown part ${part}"; exit 1 ;; esac
done
if (( VLEN == 0 )); then echo "ALL ABORTED: VLEN not known on ${MACHINE}: run setup.sh first (it writes ${MACHINE_ENV})"; exit 1; fi

status=()
run_part() {   # run_part <name> <log> <script> [args...]
    local name="$1" log="$2"; shift 2
    echo "== part ${name}: bash scripts/presentation6/$* > ${log} $(date +%T)"
    [[ "${DRY_RUN}" == 1 ]] && return 0
    bash "${HERE}/$1" "${@:2}" > "${log}" 2>&1
    status+=("${name}: $(tail -n 1 "${log}")")
    echo "== part ${name} ended $(date +%T): $(tail -n 1 "${log}")"
}
for part in ${PARTS}; do
    case "${part}" in
        prepare) for prec in f64 f32; do run_part "prepare ${prec}" "${LOGDIR}/prepare-${prec}.log" prepare.sh "${prec}"; done ;;
        steps)   run_part steps "${LOGDIR}/steps.log" steps_check.sh ;;
        matrix)  run_part matrix "${LOGDIR}/matrix.log" matrix.sh ;;
        thermal) run_part thermal "${LOGDIR}/thermal.log" thermal_check.sh ;;
    esac
done
echo
for s in "${status[@]}"; do echo "   ${s}"; done
echo "== ALL DONE $(date)"
