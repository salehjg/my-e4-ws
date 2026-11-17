#!/usr/bin/env bash
# Board job for docs/notes3 Loop 12: land the pystencils code-generation changes (HoistRowPointers,
# in_register for constant .vf operands) in the waLBerla builds and measure end to end.
#   screen -dmS notes3-e2e-cg bash misc/x60-lab/queue_e2e_cg.sh
#   1. waits for the jobs before it
#   2. backs up the board's copies of the staged files, unpacks STAGE (notes3/stage-cg.tgz)
#   3. gate: the RVV pytest files on the board                     -> notes3/pytest-cg.log
#      on failure: previous files restored, new files removed, stop
#   4. deletes the generated sweeps of the explicit targets (neither Make nor Ninja tracks the
#      pystencils sources), rebuilds and runs the GCC f32 and f64 one-core matrices
#                                                                  -> notes3/e2e-cg-gcc-{f32,f64}.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(dirname "${REPO}")"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-cg.tgz}"
WAIT_FOR="${WAIT_FOR:-notes3-(e2e-aa|perf|lab5)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done
export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache

cd "${REPO}"
tar -tzf "${STAGE}" | grep -v '/$' > "${OUT}/stage-cg.files"
: > "${OUT}/stage-cg.new"; : > "${OUT}/stage-cg.old"
while read -r f; do
   if [[ -e "${f}" ]]; then echo "${f}" >> "${OUT}/stage-cg.old"; else echo "${f}" >> "${OUT}/stage-cg.new"; fi
done < "${OUT}/stage-cg.files"
tar -czf "${OUT}/stage-cg-backup.tgz" -T "${OUT}/stage-cg.old"
tar -xzf "${STAGE}"

(
   cd "${REPO}/submodules/pystencils"
   echo "== pytest RVV with row pointers + in_register $(date)"
   PYTHONPATH=src python -m pytest -o addopts='' -p no:cacheprovider -q \
      tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py \
      tests/nbackend/test_rvv_execution.py tests/nbackend/test_vectorization.py
   rc=$?
   echo "== done $(date) rc=${rc}"
   exit ${rc}
) > "${OUT}/pytest-cg.log" 2>&1
if [[ $? -ne 0 ]]; then
   tar -xzf "${OUT}/stage-cg-backup.tgz"
   xargs -r rm -f < "${OUT}/stage-cg.new"
   echo "gate failed $(date): previous pystencils restored" >> "${OUT}/pytest-cg.log"
   exit 1
fi

T=""
for v in scalar scalar_cse explicit_cse explicit_cse_pf scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf; do
   T="${T} SweepgenLbmCPU_${v}"
done
for b in walberla-build-gcc-f32:f32 walberla-build:f64; do
   dir="${BASE}/${b%%:*}"; tag=${b#*:}
   gen="${dir}/apps/benchmarks/SweepgenLbmCPU/_gen"
   for v in explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf; do
      rm -f "${gen}/SweepgenLbmCPU_${v}"/gen/SweepgenLbmCPU.{cpp,hpp}
   done
   TARGETS="${T}" WALBERLA_BUILD="${dir}" bash scripts/walberla_lbm_bench.sh 64 200 3 > "${OUT}/e2e-cg-gcc-${tag}.log" 2>&1
   for v in explicit_cse_pf explicit_cse_aa_pf; do
      f="${gen}/SweepgenLbmCPU_${v}/gen/SweepgenLbmCPU.cpp"
      echo "${v}: row pointers $(grep -c '_row' "${f}"), in_register $(grep -c 'in_register' "${f}"), .vf $(grep -c '_vf_' "${f}")" \
         >> "${OUT}/e2e-cg-gcc-${tag}.log"
   done
done
echo "== e2e-cg done $(date)" >> "${OUT}/e2e-cg-gcc-f64.log"
