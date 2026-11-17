#!/usr/bin/env bash
# Board job for docs/notes3 Loop 9 (landing in-place AA streaming). Runs ON THE BOARD, detached:
#   screen -dmS notes3-e2e-aa bash misc/x60-lab/queue_e2e_aa.sh
# Waits until no screen session matching WAIT_FOR is left (the earlier jobs build in the same
# source tree; lab3 may have installed the new RVV selector), then
#   1. unpacks STAGE (the waLBerla/sweepgen/script changes, staged from the laptop) into the repo
#   2. GCC f32 and f64 single-core end-to-end runs incl. the AA targets  -> notes3/e2e-aa-gcc-{f32,f64}.log
#   3. 4 and 8 MPI processes on the same binaries                        -> notes3/e2e-mpi.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(dirname "${REPO}")"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-aa.tgz}"
WAIT_FOR="${WAIT_FOR:-notes3-(next|clang|aa64|lab2|lab3|lab4)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done

echo "== unpack ${STAGE} $(date)" > "${OUT}/e2e-aa-stage.log"
#   lab3 (queue_lab3.sh) leaves the new RVV selector in the tree only if its gates passed
if [[ -f "${OUT}/lab3.ok" ]]; then echo "RVV selector: new (.vf + FMA)"; else echo "RVV selector: old"; fi >> "${OUT}/e2e-aa-stage.log"
tar -xzvf "${STAGE}" -C "${REPO}" >> "${OUT}/e2e-aa-stage.log" 2>&1 || exit 1

T=""
for v in scalar scalar_cse explicit_cse explicit_cse_pf scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf; do
   T="${T} SweepgenLbmCPU_${v}"
done
cd "${REPO}"
TARGETS="${T}" WALBERLA_BUILD="${BASE}/walberla-build-gcc-f32" \
   bash scripts/walberla_lbm_bench.sh 64 200 3 > "${OUT}/e2e-aa-gcc-f32.log" 2>&1
TARGETS="${T}" WALBERLA_BUILD="${BASE}/walberla-build" \
   bash scripts/walberla_lbm_bench.sh 64 200 3 > "${OUT}/e2e-aa-gcc-f64.log" 2>&1

cd "${BASE}"
CONFIGS="walberla-build-gcc-f32 gcc-f32;walberla-build gcc-f64" LOGDIR="${OUT}" \
   VARIANTS="scalar scalar_cse explicit_cse explicit_cse_pf scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf" \
   bash "${REPO}/scripts/walberla_bench_mpi.sh" > "${OUT}/e2e-mpi.log" 2>&1
