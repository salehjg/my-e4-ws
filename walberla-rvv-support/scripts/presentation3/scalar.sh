#!/usr/bin/env bash
# Experiment: the scalar builds of SweepgenLbmCPU, no vector instructions (-march=rv64gc).
#   scalar          plain scalar build ("plain scalar" in the slides)
#   scalar_cse      + lbmpy's global common-subexpression elimination
#   scalar_cse_aa   + in-place AA streaming ("best scalar build" in the slides)
#
# Usage: bash scripts/presentation3/scalar.sh <f32|f64> <cores>
#   cores = 1 is the single-core mode, cores = 4 or 8 the multicore mode (MPI).
# Run it on the board, detached (see all.sh). Options: run.sh
exec bash "$(dirname "$0")/run.sh" "$1" "$2" scalar scalar_cse scalar_cse_aa
