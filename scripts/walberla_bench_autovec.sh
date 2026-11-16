#!/usr/bin/env bash
# Experiment: the auto-vectorized builds of SweepgenLbmCPU. The same plain C++ sweeps as the
# scalar builds, compiled with waLBerla's flags (-march=rv64gcv_zvl256b on the K1), so the
# compiler may vectorize them by itself.
#   autovec          plain sweeps
#   autovec_cse      + lbmpy's global CSE ("auto-vectorized" in the slides)
#   autovec_cse_aa   + in-place AA streaming
#
# Usage: bash scripts/walberla_bench_autovec.sh <f32|f64> <cores>
#   cores = 1 is the single-core mode, cores = 4 or 8 the multicore mode (MPI).
# Run it on the board, detached (see walberla_bench_presentation.sh). Options: walberla_bench_run.sh
exec bash "$(dirname "$0")/walberla_bench_run.sh" "$1" "$2" autovec autovec_cse autovec_cse_aa
