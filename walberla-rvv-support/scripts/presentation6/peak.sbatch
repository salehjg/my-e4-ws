#!/usr/bin/env bash
#SBATCH --job-name=presentation6
#SBATCH --partition=peak
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=64
#SBATCH --mem=0
#SBATCH --time=12:00:00
#SBATCH --output=../presentation6/logs/%x-%j.out
# presentation6 on monte3: run one presentation6 script on one whole peak node, as the cluster's guide describes
# (sbatch, then mpirun inside the allocation). 64 tasks, so that slurm grants mpirun up to 64 processes;
# exclusive, so that no other job disturbs the timings. Submit from <base>/my-e4-ws on the login node (the
# output path above is relative to it); the first argument is the script, default all.sh:
#   mkdir -p ../presentation6/logs
#   sbatch -J p6-setup --time=01:00:00 scripts/presentation6/peak.sbatch setup.sh   # first, until SETUP PASS
#   sbatch scripts/presentation6/peak.sbatch                                         # all.sh: prepare, steps, matrix
#   sbatch --export=ALL,PARTS="steps" --time=02:00:00 scripts/presentation6/peak.sbatch   # only some parts
# recon.sh submits itself through this file (job name p6-recon, 20 min).
# There is only ONE peak node for us: every job runs on that single node (never ask for more), jobs queue behind
# each other, and an exclusive job blocks the node for everyone else, so ask for a realistic --time (split all.sh
# into parts with PARTS if the whole run is long).
# Follow it:  squeue -u $USER;  tail -f ../presentation6/logs/<job name>-<job id>.out ../presentation6/logs/<part>.log
set -u
cd "${SLURM_SUBMIT_DIR:?submit with sbatch}" || exit 1
HERE="${SLURM_SUBMIT_DIR}/scripts/presentation6"
SCRIPT="${1:-all.sh}"; shift || true
case "${SCRIPT}" in */*|"") echo "give a script of scripts/presentation6 by name, e.g. setup.sh"; exit 1 ;; esac
[[ -f "${HERE}/${SCRIPT}" ]] || { echo "submit from <base>/my-e4-ws: ${HERE}/${SCRIPT} not found"; exit 1; }
echo "== presentation6 job ${SLURM_JOB_ID} on $(hostname), $(date): ${SCRIPT} $*${PARTS:+, parts: ${PARTS}}"
exec bash "${HERE}/${SCRIPT}" "$@"
