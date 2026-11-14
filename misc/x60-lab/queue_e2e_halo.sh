#!/usr/bin/env bash
# Board job for docs/notes3 Loop 13: halo exchange one PDF slot at a time.
#   screen -dmS notes3-e2e-halo bash misc/x60-lab/queue_e2e_halo.sh
# The f32 AA application spends 17.8% of its samples in the pack infos' localCopy (perf-e2e-aa.txt):
# they loop over the slots per cell, so an x face costs one cache line per value. The staged
# GenericFieldPackInfos.hpp loops over the slots outside (localCopy, pack, unpack) and turns the AA
# push skip test into a box intersection per slot.
#   1. waits for the jobs before it
#   2. REVERT_CG=1 restores the pystencils files that e2e-cg replaced (notes3/stage-cg-backup.tgz) and
#      regenerates the explicit sweeps; REVERT_CG=auto (default) does so unless e2e-cg made AA + pf
#      at least 2% faster than e2e-aa for both f32 and f64; REVERT_CG=0 keeps them
#   3. backs up the board's GenericFieldPackInfos.hpp, unpacks STAGE (notes3/stage-halo.tgz)
#   4. GCC f32 and f64 one-core matrices (Make rebuilds every target that includes the header)
#                                                                   -> notes3/e2e-halo-gcc-{f32,f64}.log
#   5. perf profile of the f32 AA + pf application                  -> notes3/perf-halo-aa.txt
#   6. the same application with huge pages (GLIBC_TUNABLES=glibc.malloc.hugetlb=1), 4 targets
#                                                                   -> notes3/e2e-halo-thp-gcc-{f32,f64}.log
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="$(dirname "${REPO}")"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-halo.tgz}"
WAIT_FOR="${WAIT_FOR:-notes3-e2e-cg}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done
export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}"

V="scalar scalar_cse explicit_cse explicit_cse_pf scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf"
T=""
for v in ${V}; do T="${T} SweepgenLbmCPU_${v}"; done
BUILDS="walberla-build-gcc-f32:f32 walberla-build:f64"

#  MLUP/s of explicit_cse_aa_pf in the summary table of a walberla_lbm_bench.sh log
aa_pf() { awk -F'|' '$2 ~ /^ explicit_cse_aa_pf $/ { gsub(/ /, "", $3); print $3 }' "$1"; }
{
   echo "== stage $(date)"
   #  auto: keep the e2e-cg code generation only if it made AA + pf at least 2% faster for f32 and f64
   if [[ "${REVERT_CG:-auto}" == auto ]]; then
      REVERT_CG=0
      for dt in f32 f64; do
         old=$(aa_pf "${OUT}/e2e-aa-gcc-${dt}.log"); new=$(aa_pf "${OUT}/e2e-cg-gcc-${dt}.log")
         echo "explicit_cse_aa_pf ${dt}: e2e-aa ${old}, e2e-cg ${new}"
         awk -v o="${old:-0}" -v n="${new:-0}" 'BEGIN { exit !(o > 0 && n >= 1.02 * o) }' || REVERT_CG=1
      done
   fi
   if [[ "${REVERT_CG}" == 1 ]]; then
      tar -xzf "${OUT}/stage-cg-backup.tgz" && xargs -r rm -f < "${OUT}/stage-cg.new"
      for b in ${BUILDS}; do
         gen="${BASE}/${b%%:*}/apps/benchmarks/SweepgenLbmCPU/_gen"
         for v in explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf; do
            rm -f "${gen}/SweepgenLbmCPU_${v}"/gen/SweepgenLbmCPU.{cpp,hpp}
         done
      done
      echo "pystencils: e2e-cg changes reverted"
   else
      echo "pystencils: as left by e2e-cg"
   fi
   tar -tzf "${STAGE}" | grep -v '/$' > "${OUT}/stage-halo.files"
   tar -czf "${OUT}/stage-halo-backup.tgz" -T "${OUT}/stage-halo.files"
   tar -xzvf "${STAGE}"
   #  The board's clock is behind the laptop's: staged files carry mtimes in the future, and Make
   #  would rebuild everything that includes them on every later build (e.g. the THP runs)
   cat "${OUT}/stage-cg.files" "${OUT}/stage-halo.files" | xargs -r touch -c
} > "${OUT}/e2e-halo-stage.log" 2>&1 || exit 1

for b in ${BUILDS}; do
   TARGETS="${T}" WALBERLA_BUILD="${BASE}/${b%%:*}" bash scripts/walberla_lbm_bench.sh 64 200 3 \
      > "${OUT}/e2e-halo-gcc-${b#*:}.log" 2>&1
done

APP="${BASE}/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU"
(
   cd "${OUT}"
   taskset -c 2 perf record -e cpu-clock -F 2000 -o perf-halo-aa.data "${APP}/SweepgenLbmCPU_explicit_cse_aa_pf" 64 100 10 \
      > perf-halo-aa.run 2>&1
   perf report -i perf-halo-aa.data --stdio --sort symbol --percent-limit 0.3 2> /dev/null \
      | grep -v "^#" | grep -v "^$" | head -40 > perf-halo-aa.txt
   echo "== perf done $(date)" >> perf-halo-aa.txt
)

#  Huge pages for the whole application (glibc madvises its mmap chunks, i.e. the fields), on the
#  vector and the scalar builds alike; Loop 0 measured +7/+8% on the pre-notes3 kernels
THPV=""
for v in scalar scalar_cse_aa explicit_cse_pf explicit_cse_aa_pf; do THPV="${THPV} SweepgenLbmCPU_${v}"; done
for b in ${BUILDS}; do
   GLIBC_TUNABLES=glibc.malloc.hugetlb=1 TARGETS="${THPV}" WALBERLA_BUILD="${BASE}/${b%%:*}" \
      bash scripts/walberla_lbm_bench.sh 64 200 3 > "${OUT}/e2e-halo-thp-gcc-${b#*:}.log" 2>&1
done

echo "== e2e-halo done $(date)" >> "${OUT}/e2e-halo-thp-gcc-f64.log"
