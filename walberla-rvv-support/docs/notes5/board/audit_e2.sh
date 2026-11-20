#!/usr/bin/env bash
# notes5 audit, board experiment E2 (docs/notes5/audit-findings-opus5.5.md, finding F1).
# Is the "best scalar" baseline held back by the same stream cliff as the RVV builds?
# SWEEPGEN_LDC_OUTPUT=last (an existing option of SweepgenLdcCPU.cpp:131-132) writes rho and u only in the
# last step: the in-place loop then has 19 streams instead of 23, below the ~20-stream cliff. Same verified
# executables as all.sh (sha256 checked), one core (core 2), 64^3, 200 steps + 10 warm-up.
#   A  timing, interleaved: GCC f32 and f64 x {scalar_cse_aa, explicit_cse_aa, explicit_cse_aa_pf,
#      explicit_cse_aa_split} x {output every, output last}; the order of the two modes flips every round;
#      3 rounds. Field hashes are printed (output=last must give the same final fields).
#   B  perf counters (late lines per cell) of scalar_cse_aa and explicit_cse_aa with output=last, GCC f32 and
#      f64, 20 - 0 steps, as streams_check.sh section ldc.
# It waits until notes5-e1 has ended. Start detached:
#   screen -dmS notes5-e2 bash -c "bash /home/bananapi/saleh/notes5/audit_e2.sh > /home/bananapi/saleh/notes5/e2.log 2>&1"
set -u
P4=/home/bananapi/saleh/presentation4
OUT=/home/bananapi/saleh/notes5
CPU=2
EV1="cycles,instructions,l1d_prefetch_hit,l1d_prefetch_refill"
EV2="l1d_load_miss,l2_miss,l2_load_access,stalled_cycle_backend"
while screen -ls 2>/dev/null | grep -q notes5-e1; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), governor $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | tr '\n' ' ') freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }

exe_of() { local tree="build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"; echo "${P4}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"; }
check_verified() {
    local h; h="$(sha256sum "$3" | cut -c1-16)"
    awk -v h="${h}" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4}/logs/verify-$1-$2.log" \
        && echo "   verified ${h} $3" || { echo "NOT VERIFIED ${h} $3"; exit 1; }
}
VARS="scalar_cse_aa explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split"
for prec in f32 f64; do for v in ${VARS}; do check_verified gcc "${prec}" "$(exe_of gcc "${prec}" "${v}")"; done; done

LOG="${OUT}/e2-A-output-last.log"; : > "${LOG}"
for round in 1 2 3; do
    modes="every last"; [[ $((round % 2)) == 0 ]] && modes="last every"
    for prec in f32 f64; do
        for v in ${VARS}; do
            exe="$(exe_of gcc "${prec}" "${v}")"
            for mode in ${modes}; do
                if [[ "${mode}" == last ]]; then export SWEEPGEN_LDC_OUTPUT=last; else unset SWEEPGEN_LDC_OUTPUT; fi
                idle="$(top -bn2 -d0.5 | awk '/^%Cpu/{l=$8} END{print l}')"
                line="$(taskset -c "${CPU}" "${exe}" 64 200 10 2>&1 | grep '^SweepgenLdcCPU variant=')"
                echo "round=${round} mode=${mode} prec=${prec} idle_before=${idle} ${line}" | tee -a "${LOG}"
            done
            unset SWEEPGEN_LDC_OUTPUT
        done
    done
done

LOG="${OUT}/e2-B-output-last-perf.log"; : > "${LOG}"
export SWEEPGEN_LDC_OUTPUT=last
for prec in f32 f64; do
    for v in scalar_cse_aa explicit_cse_aa; do
        exe="$(exe_of gcc "${prec}" "${v}")"
        echo "   sha256 $(sha256sum "${exe}" | cut -c1-16) ${exe}" >> "${LOG}"
        for steps in 20 0; do
            for ev in "${EV1}" "${EV2}"; do
                tmp="$(mktemp)"
                { echo "== ldc cc=gcc prec=${prec} variant=${v} output=last cells=64 steps=${steps} events=${ev}"
                  taskset -c "${CPU}" perf stat -x, -e "${ev}" -o "${tmp}" "${exe}" 64 "${steps}" 0 2>&1 | grep '^SweepgenLdcCPU'
                  grep -v -E '^#|^$' "${tmp}" | sed 's/^/perf,/'; } >> "${LOG}"
                rm -f "${tmp}"
            done
        done
    done
done
unset SWEEPGEN_LDC_OUTPUT
echo "== E2 DONE $(date)"
