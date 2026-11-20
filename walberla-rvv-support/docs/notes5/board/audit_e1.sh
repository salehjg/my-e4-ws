#!/usr/bin/env bash
# notes5 audit, board experiment E1 (docs/notes5/audit-findings-opus5.5.md). One core (core 2), the
# verified presentation4 executables only (sha256 checked against prepare.sh's verify logs), no build.
#
#   A  perf counters of the SCALAR builds (and explicit_cse as a cross-session check), GCC f32 and f64,
#      64^3, 20 steps minus 0 steps, the same two event groups and method as
#      scripts/presentation4/streams_check.sh section "ldc". Question: is the plain / best scalar
#      baseline itself memory-latency bound (late lines per cell, backend stalls)?
#   B  the stream probe (misc/x60-lab/probes/mem.cpp, the binary streams_check.sh built) with 4 KB pages
#      (thp=0) against huge pages (thp=1), R = 8 ... 28 read streams, stagger 4160, and our loop's
#      19 + 23 pattern with pfr = 0 / 128. Question: does the ~20-stream cliff hold with the page size
#      the program really uses (THP = madvise, waLBerla never calls madvise)?
#   C  the program itself with transparent huge pages (GLIBC_TUNABLES=glibc.malloc.hugetlb=1 makes
#      glibc madvise its mmap'd chunks) against the default, interleaved, order flipped every round,
#      3 rounds. Questions: does the page size change the timings; how stable is the plain scalar
#      baseline when it is interleaved with the RVV builds?
#
# Start detached:  screen -dmS notes5-e1 bash -c "bash /home/bananapi/saleh/notes5/audit_e1.sh > /home/bananapi/saleh/notes5/e1.log 2>&1"
set -u
P4=/home/bananapi/saleh/presentation4
OUT=/home/bananapi/saleh/notes5
CPU=2
mkdir -p "${OUT}"
EV1="cycles,instructions,l1d_prefetch_hit,l1d_prefetch_refill"
EV2="l1d_load_miss,l2_miss,l2_load_access,stalled_cycle_backend"
PARTS="${PARTS:-A B C}"
want() { [[ " ${PARTS} " == *" $1 "* ]]; }

echo "== start $(date), host $(hostname), load $(cut -d' ' -f1-3 /proc/loadavg), parts ${PARTS}"
echo "== governor $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | tr '\n' ' ') cur_freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
echo "== thp $(cat /sys/kernel/mm/transparent_hugepage/enabled) temps $(cat /sys/class/thermal/thermal_zone*/temp | tr '\n' ' ')"
screen -ls | grep -E "presentation4|notes" | grep -v notes5-e1 && { echo "ABORT: another timing job runs"; exit 1; }

exe_of() { # exe_of <cc> <prec> <variant>
    local tree="build-$1-$2"; [[ "$3" == scalar* ]] && tree+="-scalar"
    echo "${P4}/${tree}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_$3"
}
check_verified() { # check_verified <cc> <prec> <exe>: sha256 listed in prepare.sh's verify log
    local h; h="$(sha256sum "$3" | cut -c1-16)"
    if awk -v h="${h}" -v p="$3" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4}/logs/verify-$1-$2.log"; then
        echo "   verified ${h} $3"
    else
        echo "NOT VERIFIED ${h} $3"; exit 1
    fi
}

counted() { # counted <log> <header> <events> <command...>
    local log="$1" header="$2" ev="$3"; shift 3
    local tmp; tmp="$(mktemp)"
    {
        echo "== ${header} events=${ev}"
        taskset -c "${CPU}" perf stat -x, -e "${ev}" -o "${tmp}" "$@" 2>&1 | grep -E '^(stream|SweepgenLdcCPU)'
        grep -v -E '^#|^$' "${tmp}" | sed 's/^/perf,/'
    } >> "${log}"
    rm -f "${tmp}"
}

if want A; then
    LOG="${OUT}/e1-A-scalar-perf.log"; : > "${LOG}"
    for prec in f32 f64; do
        for v in scalar scalar_cse_aa explicit_cse; do
            exe="$(exe_of gcc "${prec}" "${v}")"; check_verified gcc "${prec}" "${exe}"
            echo "   sha256 $(sha256sum "${exe}" | cut -c1-16) ${exe}" >> "${LOG}"
            echo "== A gcc ${prec} ${v} $(date +%T)"
            for steps in 20 0; do
                for ev in "${EV1}" "${EV2}"; do
                    counted "${LOG}" "ldc cc=gcc prec=${prec} variant=${v} cells=64 steps=${steps}" "${ev}" "${exe}" 64 "${steps}" 0
                done
            done
        done
    done
fi

if want B; then
    LOG="${OUT}/e1-B-probe-thp.log"; : > "${LOG}"
    PROBE="${P4}/probe/mem"
    echo "== B probe $(sha256sum "${PROBE}" | cut -c1-16) ${PROBE} $(date +%T)"
    for run in 1 2; do
        for R in 8 16 19 20 21 22 23 24 28; do
            for thp in 0 1; do
                { echo "== probe run=${run} R=${R} thp=${thp}"
                  taskset -c "${CPU}" "${PROBE}" stream "${R}" 0 thp="${thp}" stagger=4160; } >> "${LOG}" 2>&1
            done
        done
        for pfr in 0 128; do
            for thp in 0 1; do
                { echo "== pattern run=${run} R=19 W=23 thp=${thp} pfr=${pfr}"
                  taskset -c "${CPU}" "${PROBE}" stream 19 23 thp="${thp}" stagger=4160 pfr="${pfr}"; } >> "${LOG}" 2>&1
            done
        done
    done
fi

if want C; then
    LOG="${OUT}/e1-C-program-thp.log"; : > "${LOG}"
    #   first: does the tunable really give the program huge pages? (sample AnonHugePages of the process)
    exe="$(exe_of gcc f32 explicit_cse_aa_split)"; check_verified gcc f32 "${exe}"
    for mode in default thp; do
        if [[ "${mode}" == thp ]]; then export GLIBC_TUNABLES=glibc.malloc.hugetlb=1; else unset GLIBC_TUNABLES; fi
        taskset -c "${CPU}" "${exe}" 64 200 10 > /dev/null 2>&1 &
        pid=$!; sleep 3
        echo "== C hugepage check mode=${mode}: $(grep -E 'AnonHugePages|^Rss' /proc/${pid}/smaps_rollup | tr -s ' ' | tr '\n' ' ')" | tee -a "${LOG}"
        wait "${pid}"
    done
    unset GLIBC_TUNABLES
    for prec in f32 f64; do
        for v in scalar scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do check_verified gcc "${prec}" "$(exe_of gcc "${prec}" "${v}")"; done
    done
    for round in 1 2 3; do
        modes="default thp"; [[ $((round % 2)) == 0 ]] && modes="thp default"
        for prec in f32 f64; do
            for v in scalar scalar_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do
                exe="$(exe_of gcc "${prec}" "${v}")"
                for mode in ${modes}; do
                    if [[ "${mode}" == thp ]]; then export GLIBC_TUNABLES=glibc.malloc.hugetlb=1; else unset GLIBC_TUNABLES; fi
                    busy="$(top -bn1 | awk 'NR==3{print $8}')"
                    line="$(taskset -c "${CPU}" "${exe}" 64 200 10 2>&1 | grep '^SweepgenLdcCPU variant=')"
                    echo "round=${round} mode=${mode} prec=${prec} idle_before=${busy} ${line}" | tee -a "${LOG}"
                done
                unset GLIBC_TUNABLES
            done
        done
    done
fi
echo "== E1 DONE $(date)"
