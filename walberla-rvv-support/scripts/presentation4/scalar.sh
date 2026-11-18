#!/usr/bin/env bash
# Experiment: the scalar builds of SweepgenLdcCPU, no vector instructions anywhere (the build tree
# compiles every file, waLBerla's libraries included, with -march=rv64gc).
#   scalar          plain scalar build ("plain scalar" in the slides)
#   scalar_cse      + lbmpy's global common-subexpression elimination
#   scalar_cse_aa   + in-place AA streaming ("best scalar build" in the slides)
#
# Usage: bash scripts/presentation4/scalar.sh <gcc|clang> <f32|f64> <cores>
# Run it on the board, detached (see all.sh). Options: run.sh
exec bash "$(dirname "$0")/run.sh" "$1" "$2" "$3" scalar scalar_cse scalar_cse_aa
