#!/usr/bin/env bash
# Experiment: the auto-vectorized builds of SweepgenLdcCPU. The same plain C++ sweeps as the scalar
# builds, compiled with waLBerla's flags for this host (-march=rv64gcv_zvl256b), so the compiler may
# vectorize them by itself.
#   autovec          plain sweeps
#   autovec_cse      + lbmpy's global CSE ("auto-vectorized" in the slides)
#   autovec_cse_aa   + in-place AA streaming
#
# Usage: bash scripts/presentation4/autovec.sh <gcc|clang> <f32|f64> <cores>
# Run it on the board, detached (see all.sh). Options: run.sh
exec bash "$(dirname "$0")/run.sh" "$1" "$2" "$3" autovec autovec_cse autovec_cse_aa
