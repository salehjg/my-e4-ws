#!/usr/bin/env bash
# Board job for docs/notes3 Loop 7 (second part). Runs ON THE BOARD, detached:
#   screen -dmS notes3-aa64 bash misc/x60-lab/queue_aa64.sh
# Waits until the screen session WAIT_FOR (default notes3-clang) has ended, then:
#   1. lab: f64 AA kernel variants + same-session f64 baselines       -> notes3/lab-aa64.log
#   2. vendor-PMU breakdown of the best f32 AA configuration           -> notes3/pmu-lab-...-aa.tsv
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
WAIT_FOR="${WAIT_FOR:-notes3-clang}"
while screen -ls | grep -q "${WAIT_FOR}"; do sleep 30; done

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
{
   echo "== lab AA f64 $(date)"
   TAG=aa64-base bash run.sh f64-generic-cse_scalar f64-rvv-cse "f64-rvv-cse+bpf=128"
   for d in "BY=2 GM=5 GP=2" "BY=2 GM=5 GP=3" "BY=2 GM=7 GP=2" "BY=1 GM=5 GP=3" "BY=1 GM=7 GP=3"; do
      defs=$(for kv in $d; do printf -- "-D%s " "$kv"; done)
      TAG=aa64 RUNENV="AA=1" HAND_DEFS="$defs" bash run.sh "f64-hand-aa@$(echo $d | tr ' =' '_-')"
   done
   echo "== done $(date)"
} > "${OUT}/lab-aa64.log" 2>&1

B=gcc-O3-f32-hand-aa@BY-2_GM-5_GP-3
AA=1 bash ../pmu_stat.sh "${OUT}/pmu-lab-${B}.tsv" 64 20 -- "${OUT}/lab/bin/${B}" > "${OUT}/pmu-aa.log" 2>&1
echo "== pmu done $(date)" >> "${OUT}/pmu-aa.log"
