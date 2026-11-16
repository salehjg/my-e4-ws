#!/usr/bin/env bash
# Experiment: the explicit RVV builds of SweepgenLbmCPU (pystencils' RVV backend), with lbmpy's
# global CSE, one step at a time as in the slides:
#   explicit_cse            RVV code ("RVV at start" in the slides)
#   explicit_cse_pf         + software prefetch, 128 bytes ahead
#   explicit_cse_aa         + in-place AA streaming, without prefetch
#   explicit_cse_aa_pf      AA streaming and prefetch ("RVV, now" in the slides)
#   explicit_cse_aa_split   AA streaming, update split into passes with few streams each
#
# Usage: bash scripts/walberla_bench_rvv.sh <f32|f64> <cores>
#   cores = 1 is the single-core mode, cores = 4 or 8 the multicore mode (MPI).
# Run it on the board, detached (see walberla_bench_presentation.sh). Options: walberla_bench_run.sh
exec bash "$(dirname "$0")/walberla_bench_run.sh" "$1" "$2" \
    explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split
