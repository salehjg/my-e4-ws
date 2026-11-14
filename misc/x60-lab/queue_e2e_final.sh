#!/usr/bin/env bash
# Board job for docs/notes3 Loop 14: the sweep without rho/u outputs and the direction-split AA
# stream/collide, end to end.
#   screen -dmS notes3-e2e-final bash misc/x60-lab/queue_e2e_final.sh
# STAGE (notes3/stage-final.tgz) holds sweepgen's LbmBulk (output_free_sweeps) and the app
# (SweepgenLbmCPU.py --split, lbm_split.py, SweepgenLbmCPU.cpp: SWEEPGEN_LBM_OUTPUT=last and
# SWEEPGEN_LBM_SPLIT, CMakeLists.txt: target SweepgenLbmCPU_explicit_cse_aa_split).
#   1. waits for the jobs before it
#   2. backs up the board's copies, unpacks STAGE, moves the staged files' mtimes to now
#   3. deletes every generated SweepgenLbmCPU source (Make does not track sweepgen's Python)
#   4. GCC f32 and f64 one-core matrices, every step writing rho/u   -> notes3/e2e-final-gcc-{f32,f64}.log
#   5. the same binaries with SWEEPGEN_LBM_OUTPUT=last                 -> notes3/e2e-final-last-gcc-{f32,f64}.log
#   6. perf profile of the f32 split application, output=last         -> notes3/perf-final-split.txt
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(dirname "${REPO}")"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-final.tgz}"
WAIT_FOR="${WAIT_FOR:-notes3-(e2e-cg|e2e-halo|lab6|lab7)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done
export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}"

V="scalar scalar_cse explicit_cse explicit_cse_pf scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
T=""
for v in ${V}; do T="${T} SweepgenLbmCPU_${v}"; done
BUILDS="walberla-build-gcc-f32:f32 walberla-build:f64"

{
   echo "== stage $(date)"
   tar -tzf "${STAGE}" | grep -v '/$' > "${OUT}/stage-final.files"
   : > "${OUT}/stage-final.old"
   while read -r f; do [[ -e "${f}" ]] && echo "${f}" >> "${OUT}/stage-final.old"; done < "${OUT}/stage-final.files"
   tar -czf "${OUT}/stage-final-backup.tgz" -T "${OUT}/stage-final.old"
   tar -xzvf "${STAGE}"
   xargs -r touch -c < "${OUT}/stage-final.files"
   for b in ${BUILDS}; do
      rm -fv "${BASE}/${b%%:*}"/apps/benchmarks/SweepgenLbmCPU/_gen/SweepgenLbmCPU_*/gen/SweepgenLbmCPU.{cpp,hpp}
   done
} > "${OUT}/e2e-final-stage.log" 2>&1 || exit 1

for b in ${BUILDS}; do
   dir="${BASE}/${b%%:*}"; tag=${b#*:}
   TARGETS="${T}" WALBERLA_BUILD="${dir}" bash scripts/walberla_lbm_bench.sh 64 200 3 > "${OUT}/e2e-final-gcc-${tag}.log" 2>&1
   SWEEPGEN_LBM_OUTPUT=last TARGETS="${T}" WALBERLA_BUILD="${dir}" bash scripts/walberla_lbm_bench.sh 64 200 3 \
      > "${OUT}/e2e-final-last-gcc-${tag}.log" 2>&1
done

APP="${BASE}/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU"
(
   cd "${OUT}"
   SWEEPGEN_LBM_OUTPUT=last taskset -c 2 perf record -e cpu-clock -F 2000 -o perf-final-split.data \
      "${APP}/SweepgenLbmCPU_explicit_cse_aa_split" 64 100 10 > perf-final-split.run 2>&1
   perf report -i perf-final-split.data --stdio --sort symbol --percent-limit 0.3 2> /dev/null \
      | grep -v "^#" | grep -v "^$" | head -40 > perf-final-split.txt
   echo "== perf done $(date)" >> perf-final-split.txt
)

echo "== e2e-final done $(date)" >> "${OUT}/perf-final-split.txt"
