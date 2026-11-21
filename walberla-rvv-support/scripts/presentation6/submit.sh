#!/usr/bin/env bash
# presentation6: submit one presentation6 script as a batch job on the peak node (through peak.sbatch), after
# creating the log folder: slurm does not create it, and without it the job fails at once and writes nothing.
# Run on the monte3 login node, from anywhere:
#   bash scripts/presentation6/submit.sh [--time=HH:MM:SS] <script> [args...]
#   e.g.  bash scripts/presentation6/submit.sh --time=00:30:00 setup.sh
#         bash scripts/presentation6/submit.sh --time=04:00:00 prepare.sh f64
#         PARTS="steps matrix" bash scripts/presentation6/submit.sh --time=08:00:00 all.sh
# The job is named p6-<script>[-<args>]; prints the job id and the log file. Without --time: setup.sh 30 min,
# prepare.sh 4 h, recon.sh 20 min, anything else peak.sbatch's 12 h (one shared node: ask for what is needed).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
LOGS="$(dirname "${REPO}")/presentation6/logs"
time_arg=()
[[ "${1:-}" == --time=* ]] && { time_arg=("$1"); shift; }
SCRIPT="${1:?usage: submit.sh [--time=HH:MM:SS] <script> [args...]}"; shift
[[ -f "${HERE}/${SCRIPT}" ]] || { echo "no script ${SCRIPT} in ${HERE}"; exit 1; }
if [[ ${#time_arg[@]} == 0 ]]; then
    case "${SCRIPT}" in setup.sh) time_arg=(--time=00:30:00) ;; prepare.sh) time_arg=(--time=04:00:00) ;; recon.sh) time_arg=(--time=00:20:00) ;; esac
fi
name="p6-${SCRIPT%.sh}"; [[ $# -gt 0 ]] && name+="-$(echo "$*" | tr ' /' '-_')"
mkdir -p "${LOGS}"
cd "${REPO}" || exit 1
id="$(sbatch --parsable -J "${name}" "${time_arg[@]}" --export=ALL scripts/presentation6/peak.sbatch "${SCRIPT}" "$@")" || exit 1
echo "job ${id%%;*} (${name}) submitted; log: ${LOGS}/${name}-${id%%;*}.out"
echo "follow it:  squeue -u \$USER;  tail -f ${LOGS}/${name}-${id%%;*}.out"
