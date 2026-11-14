#!/usr/bin/env bash
# Board job for docs/notes3 Loop 12: where do the AA application's cycles go outside the sweep?
# The lab (kernel only) gives 8.99 MLUP/s for generated AA + prefetch, the application 7.08, a
# 21% gap against 8% for pull. Profile both executables (cpu-clock sampling: hardware-event
# sampling yields no samples on the X60), on core 2.             -> notes3/perf-e2e-{aa,pull}.txt
#   screen -dmS notes3-perf bash misc/x60-lab/queue_perf_e2e.sh
set -u
OUT=/home/bananapi/saleh/notes3
APP=/home/bananapi/saleh/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU
WAIT_FOR="${WAIT_FOR:-notes3-e2e-aa}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 60; done
cd "${OUT}"
for v in aa:explicit_cse_aa_pf pull:explicit_cse_pf; do
   tag=${v%%:*}; exe=${APP}/SweepgenLbmCPU_${v#*:}
   taskset -c 2 perf record -e cpu-clock -F 2000 -o "perf-e2e-${tag}.data" "${exe}" 64 100 10 > "perf-e2e-${tag}.run" 2>&1
   perf report -i "perf-e2e-${tag}.data" --stdio --sort symbol --percent-limit 0.3 2> /dev/null \
      | grep -v "^#" | grep -v "^$" | head -40 > "perf-e2e-${tag}.txt"
done
echo "== perf done $(date)" >> perf-e2e-aa.txt
