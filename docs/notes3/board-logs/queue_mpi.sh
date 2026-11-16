#!/usr/bin/env bash
# notes3 Phase 6 multi-core matrix; waits for the other notes3 board jobs first.
while screen -ls | grep -qE "notes3-(next|clang|aa64|lab2)"; do sleep 60; done
cd /home/bananapi/saleh
LOGDIR=/home/bananapi/saleh/notes3 VARIANTS="scalar scalar_cse explicit explicit_cse explicit_pf explicit_cse_pf" \
    bash my-e4-ws/scripts/walberla_bench_mpi.sh > /home/bananapi/saleh/notes3/e2e-mpi.log 2>&1
