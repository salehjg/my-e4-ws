#!/usr/bin/env bash
# Clang e2e runs for the notes3 Phase 6 matrix; waits for the running notes3 job first.
while screen -ls | grep -q notes3-next; do sleep 30; done
cd /home/bananapi/saleh/my-e4-ws
T=""
for v in scalar scalar_cse explicit explicit_cse explicit_pf explicit_cse_pf; do T="$T SweepgenLbmCPU_$v"; done
for p in f32 f64; do
    TARGETS="$T" WALBERLA_BUILD=/home/bananapi/saleh/walberla-build-clang-$p \
        bash scripts/walberla_lbm_bench.sh 64 200 3 > /home/bananapi/saleh/notes3/e2e-clang-$p.log 2>&1
done
