#!/usr/bin/env bash
# Board job for docs/notes3 Loop 11 (X60 scheduling model). Runs ON THE BOARD, detached:
#   screen -dmS notes3-lab4 bash misc/x60-lab/queue_lab4.sh
# Loop 8 found Clang 18's `-mtune=spacemit-x60` worth +24% on the hand AA kernel. This job checks
# whether the generated kernels (and the scalar baseline, for a fair ratio) gain as well:
# GCC 14 (no X60 model), Clang 18 untuned and Clang 18 with -mtune=spacemit-x60, same session.
#                                                                                     -> notes3/lab4.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
WAIT_FOR="${WAIT_FOR:-notes3-(next|clang|aa64|lab2|lab3)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 30; done

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
PULL=(f32-generic-cse_scalar "f32-rvv-cse+bpf=128+vf2" f64-generic-cse_scalar "f64-rvv-cse+bpf=128+vf2")
AAGEN=("f32-rvv-cse+aa+bpf=128+vf2" "f32-rvv-cse+aa+bpf=128" "f64-rvv-cse+aa+bpf=128+vf2")
{
   echo "== lab4: compiler scheduling models $(date)"
   for cfg in "gcc none" "clang none" "clang spacemit-x60"; do
      read -r cc tune <<< "${cfg}"
      t=""; [[ ${tune} != none ]] && t="-mtune=${tune}"
      export CCS=${cc} MARCH="-march=rv64gcv_zvl256b_zicbop ${t}" MARCH_SCALAR="-march=rv64gc_zicbop ${t}"
      TAG="lab4-${tune}" bash run.sh "${PULL[@]}"
      TAG="lab4-${tune}" RUNENV="AA=1" bash run.sh "${AAGEN[@]}"
      TAG="lab4-${tune}" RUNENV="AA=1" HAND_DEFS="-DBY=2 -DGM=5 -DGP=3" bash run.sh "f32-hand-aa@BY-2_GM-5_GP-3_tune-${tune}"
      TAG="lab4-${tune}" RUNENV="AA=1" HAND_DEFS="-DBY=1 -DGM=5 -DGP=3" bash run.sh "f64-hand-aa@BY-1_GM-5_GP-3_tune-${tune}"
   done
   echo "== done $(date)"
} > "${OUT}/lab4.log" 2>&1
