#!/usr/bin/env bash
# All the whole-program numbers of docs/presentation3 in one session: the scalar, autovec and
# rvv experiments, in f32 and f64, on 1, 4 and 8 cores (GCC, 64^3 cells per core, best of 3
# runs of 200 steps). The first pass of each experiment regenerates its kernels from the
# current pystencils and sweepgen. Takes about 4 hours on the board.
#
# Start it on the board, detached, so it survives a lost connection:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS walberla-presentation bash -c \
#       "bash scripts/presentation3/all.sh > ../walberla-presentation.log 2>&1"
# One log per experiment in LOGDIR (default ../presentation-logs):
#   walberla-<scalar|autovec|rvv>-<f32|f64>-<1|4|8>core.log
# and the combined table at the end of this script's output.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
LOGDIR="${LOGDIR:-$(dirname "${REPO}")/presentation-logs}"
mkdir -p "${LOGDIR}"
echo "== start $(date)"

for prec in f32 f64; do
    for cores in 1 4 8; do
        for exp in scalar autovec rvv; do
            log="${LOGDIR}/walberla-${exp}-${prec}-${cores}core.log"
            echo "== ${exp} ${prec} ${cores} core(s) $(date +%T) -> ${log}"
            #   Regenerate the kernels once per build dir, in the first (one core) pass
            regen=0; [[ "${cores}" == 1 ]] && regen=1
            REGEN="${regen}" bash "${HERE}/${exp}.sh" "${prec}" "${cores}" > "${log}" 2>&1
        done
    done
done

echo
labels=()
for cores in 1 4 8; do
    for prec in f32 f64; do
        for exp in scalar autovec rvv; do
            labels+=("${prec} ${cores}c=${LOGDIR}/walberla-${exp}-${prec}-${cores}core.log")
        done
    done
done
python3 "${REPO}/scripts/common/walberla_summary.py" "${labels[@]}"
echo "== ALL DONE $(date)"
