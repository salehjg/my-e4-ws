#!/usr/bin/env bash
# notes5 audit, board experiment E10 (findings F1, F6).
#   A  F1 for Clang: output every step vs last step (19 instead of 23 in-place streams), Clang f32 and f64,
#      scalar_cse_aa, explicit_cse_aa_pf, explicit_cse_aa_split, 2 rounds, interleaved, mode order flipped.
#   B  F6, the GCC f32 headline builds (scalar, scalar_cse_aa, explicit_cse_aa_pf, explicit_cse_aa_split) with the
#      fields on the brk heap (GLIBC_TUNABLES=glibc.malloc.mmap_threshold=33554432) against the default, 2 rounds.
#      (f64 fields exceed glibc's 32 MB mmap_threshold maximum, so f64 cannot be moved this way.)
# Verified executables only (sha256 against prepare.sh's verify logs), core 2.
#   screen -dmS notes5-e10 bash -c "bash /home/bananapi/saleh/notes5/audit_e10.sh > /home/bananapi/saleh/notes5/e10.log 2>&1"
set -u
P4=/home/bananapi/saleh/presentation4
OUT=/home/bananapi/saleh/notes5
CPU=2
while screen -ls 2>/dev/null | grep -q -E "notes5-e[0-9]\b"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
exe_of() { local tree="build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"; echo "${P4}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"; }
check_verified() {
    local h; h="$(sha256sum "$3" | cut -c1-16)"
    awk -v h="${h}" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4}/logs/verify-$1-$2.log" \
        && echo "   verified ${h} $3" || { echo "NOT VERIFIED ${h} $3"; exit 1; }
}
for prec in f32 f64; do for v in scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do check_verified clang "${prec}" "$(exe_of clang "${prec}" "${v}")"; done; done
for v in scalar scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do check_verified gcc f32 "$(exe_of gcc f32 "${v}")"; done
LOG="${OUT}/e10-A-clang-output-last.log"; : > "${LOG}"
for round in 1 2; do
    modes="every last"; [[ "${round}" == 2 ]] && modes="last every"
    for prec in f32 f64; do
        for v in scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do
            for mode in ${modes}; do
                if [[ "${mode}" == last ]]; then export SWEEPGEN_LDC_OUTPUT=last; else unset SWEEPGEN_LDC_OUTPUT; fi
                line="$(taskset -c "${CPU}" "$(exe_of clang "${prec}" "${v}")" 64 200 10 2>&1 | grep '^SweepgenLdcCPU variant=')"
                echo "round=${round} mode=${mode} prec=${prec} ${line}" | tee -a "${LOG}"
            done
            unset SWEEPGEN_LDC_OUTPUT
        done
    done
done
LOG="${OUT}/e10-B-gcc-f32-heap.log"; : > "${LOG}"
for round in 1 2; do
    modes="default heap"; [[ "${round}" == 2 ]] && modes="heap default"
    for v in scalar scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do
        for mode in ${modes}; do
            if [[ "${mode}" == heap ]]; then export GLIBC_TUNABLES=glibc.malloc.mmap_threshold=33554432; else unset GLIBC_TUNABLES; fi
            line="$(taskset -c "${CPU}" "$(exe_of gcc f32 "${v}")" 64 200 10 2>&1 | grep '^SweepgenLdcCPU variant=')"
            echo "round=${round} mode=${mode} prec=f32 ${line}" | tee -a "${LOG}"
        done
        unset GLIBC_TUNABLES
    done
done
echo "== E10 DONE $(date)"
