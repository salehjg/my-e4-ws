#!/usr/bin/env bash
# Board job queue for docs/notes3 (Loop 7 + Phase 6 tests). Runs ON THE BOARD, detached:
#   screen -dmS notes3-next bash misc/x60-lab/queue_aa_tests.sh
# Waits until the screen session WAIT_FOR (default notes3-e2e) has ended, so board jobs never
# overlap (timing noise), then:
#   1. lab: AA-pattern kernel variants + same-session baselines   -> notes3/lab-aa.log
#   2. pystencils RVV tests on the hardware                       -> notes3/pytest-rvv.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
WAIT_FOR="${WAIT_FOR:-notes3-e2e}"
while screen -ls | grep -q "${WAIT_FOR}"; do sleep 30; done

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
{
   echo "== lab AA $(date)"
   TAG=aa-base bash run.sh f32-rvv-cse "f32-rvv-cse+bpf=128" f32-generic-cse_scalar
   TAG=aa-base HAND_DEFS="-DBY=2" bash run.sh f32-hand-split@BY-2
   for d in "BY=2 GM=5 GP=2" "BY=2 GM=5 GP=3" "BY=2 GM=7 GP=2" "BY=4 GM=5 GP=2" "BY=2 GM=5 GP=1"; do
      defs=$(for kv in $d; do printf -- "-D%s " "$kv"; done)
      TAG=aa RUNENV="AA=1" HAND_DEFS="$defs" bash run.sh "f32-hand-aa@$(echo $d | tr ' =' '_-')"
   done
   echo "== done $(date)"
} > "${OUT}/lab-aa.log" 2>&1

cd "${REPO}/submodules/pystencils"
{
   echo "== pytest RVV $(date)"
   PYTHONPATH=src python -m pytest -o addopts='' -p no:cacheprovider -q \
      tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py \
      tests/nbackend/test_rvv_execution.py tests/nbackend/test_vectorization.py
   echo "== done $(date) rc=$?"
} > "${OUT}/pytest-rvv.log" 2>&1
