#!/usr/bin/env bash
# Board job for docs/notes3 Loop 13: padding between the PDF slices, with 4 K pages and with THP.
#   screen -dmS notes3-lab6 bash misc/x60-lab/queue_lab6.sh
# lab5: with huge pages the f32 AA odd step gets 7% faster (TLB) but the even step 30% slower and the
# f32 pull kernel 25% slower; with 4 K pages the physical addresses of the 19 PDF slices are random
# beyond bit 12, with 2 MB pages they keep the virtual offsets, so the slices may conflict in cache
# sets or DRAM banks. Sweep the extra bytes between slices (driver PADF, in elements) on the landed
# kernels and two scalar baselines, reusing the lab5 binaries (RUNONLY=1).   -> notes3/lab6.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
WAIT_FOR="${WAIT_FOR:-notes3-(e2e-cg|e2e-halo)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
export STEPS=40 RUNONLY=1
{
   echo "== lab6: padding between PDF slices, 4 K pages and THP $(date)"
   for round in 1 2; do
      for thp in 0 1; do
         for bytes in 0 64 256 1088 4160 8256 16448 33024; do
            for dt in f32 f64; do
               es=4; [[ ${dt} == f64 ]] && es=8
               env="THP=${thp} PADF=$((bytes / es))"
               scalar="${dt}-generic-cse_scalar"; [[ ${dt} == f32 ]] && scalar="${dt}-generic-cse_scalar+aa"
               aa=AA=0; [[ ${scalar} == *+aa ]] && aa=AA=1
               TAG="lab6-r${round}" RUNENV="${env}" bash run.sh "${dt}-rvv-cse+bpf=128+vf2"
               TAG="lab6-r${round}" RUNENV="AA=1 ${env}" bash run.sh "${dt}-rvv-cse+aa+bpf=128+vf2"
               TAG="lab6-r${round}" RUNENV="${aa} ${env}" bash run.sh "${scalar}"
            done
         done
      done
   done
   echo "== done $(date)"
} > "${OUT}/lab6.log" 2>&1
