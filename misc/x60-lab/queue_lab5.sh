#!/usr/bin/env bash
# Board job for docs/notes3 Loop 12 (code generation, field alignment). Runs ON THE BOARD, detached:
#   screen -dmS notes3-lab5 bash misc/x60-lab/queue_lab5.sh
# waLBerla's v8 fields on RISC-V are aligned to __BIGGEST_ALIGNMENT__ = 16 B and x is padded to
# 16 B (68 floats per row), so about a quarter of the 32-byte vector accesses of the even AA step
# and of the pull step cross a 64-byte cache line. Lab A/B of the landed kernels (new selector,
# prefetch 128 B) with the interior origin and the row length aligned to 16 (waLBerla today),
# 32 (= VLEN/8) and 64 B (cache line); THP on top of the 32-B layout; the scalar baselines too.
# The driver now also prints mean_mlups (all steps) and, for AA, even_mlups / odd_mlups.
# Second part: code-generation edits of edits.py on the AA kernels (and pull): `rp` hoists row
# base pointers out of the x-loop, `opq` keeps the scalar .vf constants in FP registers.
#                                                                                 -> notes3/lab5.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
WAIT_FOR="${WAIT_FOR:-notes3-(e2e-aa|perf|lab4)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
export STEPS=40
{
   echo "== lab5: code generation, field alignment $(date)"
   for round in 1 2; do
      for dt in f32 f64; do
         ro=1; [[ ${round} == 1 ]] && ro=0
         TAG="lab5-cg-r${round}" RUNONLY=${ro} RUNENV="AA=1" bash run.sh "${dt}-rvv-cse+aa+bpf=128+vf2"
         TAG="lab5-cg-r${round}" RUNONLY=${ro} RUNENV="AA=1" bash run.sh \
            "${dt}-rvv-cse+aa+bpf=128+vf2+rp" "${dt}-rvv-cse+aa+bpf=128+vf2+rp+opq"
      done
      TAG="lab5-cg-r${round}" RUNONLY=${ro} bash run.sh "f32-rvv-cse+bpf=128+vf2" "f32-rvv-cse+bpf=128+vf2+rp+opq"
   done
   for dt in f32 f64; do
      es=4; [[ ${dt} == f64 ]] && es=8
      pull=("${dt}-generic-cse_scalar" "${dt}-rvv-cse+bpf=128+vf2")
      aa=("${dt}-rvv-cse+aa+bpf=128+vf2" "${dt}-rvv-cse+aa+bpf=128+vf2+rp+opq")
      for round in 1 2; do
         for a in 16 32 64; do
            env="ALIGN=${a} XPAD=$((a / es))"
            ro=1; [[ ${round} == 1 && ${a} == 16 ]] && ro=0   # build once per kernel, then reuse
            TAG="lab5-r${round}" RUNONLY=${ro} RUNENV="${env}" bash run.sh "${pull[@]}"
            TAG="lab5-r${round}" RUNONLY=${ro} RUNENV="AA=1 ${env}" bash run.sh "${aa[@]}"
         done
         TAG="lab5-r${round}" RUNONLY=1 RUNENV="THP=1 ALIGN=32 XPAD=$((32 / es))" bash run.sh "${pull[@]}"
         TAG="lab5-r${round}" RUNONLY=1 RUNENV="AA=1 THP=1 ALIGN=32 XPAD=$((32 / es))" bash run.sh "${aa[@]}"
      done
   done
   echo "== done $(date)"
} > "${OUT}/lab5.log" 2>&1
