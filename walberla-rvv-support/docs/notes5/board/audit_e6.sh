#!/usr/bin/env bash
# notes5 audit, board experiment E6 (finding F18): is the split-loop conflict between the periodic box
# (presentation3: split 19 % slower than in place + prefetch) and the cavity (presentation4: 17 % faster) a
# memory-layout effect? No rebuild: the layout is changed through glibc tunables only.
#   default   as all.sh (operator new -> mmap for the large fields, 4 KB pages)
#   thp       GLIBC_TUNABLES=glibc.malloc.hugetlb=1             (2 MB pages; virtual offsets kept physically)
#   heap      GLIBC_TUNABLES=glibc.malloc.mmap_threshold=33554432 (f32 fields below 32 MB come from the brk heap:
#             other base alignment and other relative offsets)
# f32, GCC, core 2, explicit_cse_aa_pf and explicit_cse_aa_split of both apps (presentation3's periodic-box
# binaries, presentation4's verified cavity binaries), 2 rounds, mode order rotated. Waits for notes5-e3/e4/e5.
#   screen -dmS notes5-e6 bash -c "bash /home/bananapi/saleh/notes5/audit_e6.sh > /home/bananapi/saleh/notes5/e6.log 2>&1"
set -u
OUT=/home/bananapi/saleh/notes5
CPU=2
P3=/home/bananapi/saleh/walberla-build-gcc-f32/apps/benchmarks/SweepgenLbmCPU
P4=/home/bananapi/saleh/presentation4/build-gcc-f32/apps/benchmarks/SweepgenLdcCPU
while screen -ls 2>/dev/null | grep -q -E "notes5-e[345]"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
for e in "${P3}"/SweepgenLbmCPU_explicit_cse_aa_{pf,split} "${P4}"/SweepgenLdcCPU_explicit_cse_aa_{pf,split}; do
    echo "   $(sha256sum "${e}" | cut -c1-16) ${e}"
done
LOG="${OUT}/e6-layout.log"; : > "${LOG}"
setmode() {
    case "$1" in
        default) unset GLIBC_TUNABLES ;;
        thp)     export GLIBC_TUNABLES=glibc.malloc.hugetlb=1 ;;
        heap)    export GLIBC_TUNABLES=glibc.malloc.mmap_threshold=33554432 ;;
    esac
}
#   where do the big allocations land? (one short run per mode: the mappings of a running process)
for mode in default thp heap; do
    setmode "${mode}"
    taskset -c "${CPU}" "${P4}/SweepgenLdcCPU_explicit_cse_aa_split" 64 400 10 > /dev/null 2>&1 &
    pid=$!; sleep 3
    big=""
    while read -r range _ _ _ _ path; do
        s=$(( 16#${range#*-} - 16#${range%-*} ))
        (( s > 8388608 )) && big+="${range}($(( s / 1048576 ))MB${path:+ ${path}}) "
    done < "/proc/${pid}/maps"
    echo "== maps mode=${mode}: mappings > 8 MB: ${big} AnonHuge $(awk '/AnonHugePages/ {print $2}' /proc/${pid}/smaps_rollup)kB" | tee -a "${LOG}"
    wait "${pid}"
done
unset GLIBC_TUNABLES
for round in 1 2; do
    modes="default thp heap"; [[ "${round}" == 2 ]] && modes="heap thp default"
    for mode in ${modes}; do
        setmode "${mode}"
        for e in "${P3}"/SweepgenLbmCPU_explicit_cse_aa_{pf,split} "${P4}"/SweepgenLdcCPU_explicit_cse_aa_{pf,split}; do
            line="$(taskset -c "${CPU}" "${e}" 64 200 10 2>&1 | grep -E '^Sweepgen(Lbm|Ldc)CPU variant=')"
            echo "round=${round} mode=${mode} ${line}" | tee -a "${LOG}"
        done
        unset GLIBC_TUNABLES
    done
done
echo "== E6 DONE $(date)"
