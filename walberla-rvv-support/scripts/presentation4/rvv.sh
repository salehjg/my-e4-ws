#!/usr/bin/env bash
# Experiment: the explicit RVV builds of SweepgenLdcCPU (pystencils' RVV backend), with lbmpy's
# global CSE, one step at a time as in the slides:
#   explicit_cse            RVV code
#   explicit_cse_pf         + software prefetch, 128 bytes ahead
#   explicit_cse_aa         + in-place AA streaming, without prefetch
#   explicit_cse_aa_pf      AA streaming and prefetch ("RVV, now" in the slides)
#   explicit_cse_aa_split   AA streaming, update split into passes with few streams each
#
# Usage: bash scripts/presentation4/rvv.sh <gcc|clang> <f32|f64> <cores>
# Run it on the board, detached (see all.sh). Options: run.sh
exec bash "$(dirname "$0")/run.sh" "$1" "$2" "$3" \
    explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split
