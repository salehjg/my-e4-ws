#!/usr/bin/env bash
# notes5 audit, board experiment E3 (docs/notes5/audit-findings-opus5.5.md, conflict between presentation3 and
# presentation4: split loop 19 % slower than in place + prefetch in the periodic box, 17 % faster in the cavity).
# One core (core 2), GCC, no build. Interleaved, order flipped every round, 3 rounds.
#   A  presentation3's own periodic-box executables (SweepgenLbmCPU, built 2026-11-14 board time, the binaries
#      behind docs/notes3/board-logs/presentation3/), explicit_cse_aa_pf and explicit_cse_aa_split, f32 and f64,
#      64^3, 200 steps, warm-up 10 (presentation3's protocol). Does the conflict reproduce in one session?
#   B  presentation4's verified cavity executables, the same two builds, f32 and f64, warm-up 10 (all.sh) and
#      warm-up 1000 (developed flow; all.sh's warm-up check covered aa_pf only, never the split).
# It waits until notes5-e2 has ended. Start detached:
#   screen -dmS notes5-e3 bash -c "bash /home/bananapi/saleh/notes5/audit_e3.sh > /home/bananapi/saleh/notes5/e3.log 2>&1"
set -u
P4=/home/bananapi/saleh/presentation4
OUT=/home/bananapi/saleh/notes5
CPU=2
while screen -ls 2>/dev/null | grep -q -E "notes5-e1|notes5-e2"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
P3_f32=/home/bananapi/saleh/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU
P3_f64=/home/bananapi/saleh/walberla-build/apps/benchmarks/SweepgenLbmCPU
for prec in f32 f64; do
    d="P3_${prec}"; for v in explicit_cse_aa_pf explicit_cse_aa_split; do
        e="${!d}/SweepgenLbmCPU_${v}"; echo "   p3 $(sha256sum "${e}" | cut -c1-16) $(stat -c %y "${e}") ${e}"; done
    for v in explicit_cse_aa_pf explicit_cse_aa_split; do
        e="${P4}/build-gcc-${prec}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"; h="$(sha256sum "${e}" | cut -c1-16)"
        awk -v h="${h}" -v p="${e}" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4}/logs/verify-gcc-${prec}.log" \
            && echo "   p4 verified ${h} ${e}" || { echo "NOT VERIFIED ${e}"; exit 1; }
    done
done
LOG="${OUT}/e3-split-conflict.log"; : > "${LOG}"
run1() { # run1 <tag> <exe> <warmup>
    local line; line="$(taskset -c "${CPU}" "$2" 64 200 "$3" 2>&1 | grep -E '^Sweepgen(Lbm|Ldc)CPU variant=')"
    echo "round=${round} tag=$1 warmup=$3 ${line}" | tee -a "${LOG}"
}
for round in 1 2 3; do
    for prec in f32 f64; do
        d="P3_${prec}"
        order="explicit_cse_aa_pf explicit_cse_aa_split"; [[ $((round % 2)) == 0 ]] && order="explicit_cse_aa_split explicit_cse_aa_pf"
        for v in ${order}; do run1 "p3-periodic-${prec}" "${!d}/SweepgenLbmCPU_${v}" 10; done
        for w in 10 1000; do
            for v in ${order}; do run1 "p4-ldc-${prec}" "${P4}/build-gcc-${prec}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}" "${w}"; done
        done
    done
done
echo "== E3 DONE $(date)"
