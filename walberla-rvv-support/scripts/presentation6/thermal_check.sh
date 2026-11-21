#!/usr/bin/env bash
# presentation6: do long all-core runs slow down because the chip throttles? (presentation5's thermal_check.sh on
# the machine profile of machine.sh; there the K1 kept 1.6 GHz, max 73 C against a 75 C trip point.)
# Runs one verified build (GCC f64, VARIANT: RVV in place + prefetch where the explicit variants run, else best
# autovec) on all cores of the profile (the last of CORE_LIST) for 200 and for 60 steps, twice each with a 60 s
# pause before every run, and samples every 0.5 s during each run: the lowest and highest clock over the cores,
# every thermal zone, and the state of every cpufreq cooling device.
# bananapi, detached (about 6 min):
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation6-thermal \
#       bash -c "bash scripts/presentation6/thermal_check.sh > ../presentation6/logs/thermal.log 2>&1"
# monte3: part "thermal" of all.sh, through peak.sbatch
# Environment: VARIANT, CORES (default: the last of CORE_LIST)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
VARIANT="${VARIANT:-$( [[ "${EXPLICIT_OK}" == 1 ]] && echo explicit_cse_aa_pf || echo autovec_cse_aa)}"
CORES="${CORES:-${CORE_LIST##* }}"
EXE="$(p6_exe gcc f64 "${VARIANT}")"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"
p6_wait_turn presentation6-thermal
h="$(sha256sum "${EXE}" | cut -c1-16)"
p6_in_verify_log "${BUILD_ROOT}/logs/verify-gcc-f64.log" "${h}" "${EXE}" \
    && echo "   verified ${h} ${EXE}" || { echo "ABORT: NOT VERIFIED ${EXE}"; exit 1; }
echo "== start $(date), ${VARIANT} on ${CORES} cores"; p6_profile; env_record

temps() {   # every thermal zone, one word each: <type>=<C>
    local z mc s=""
    for z in /sys/class/thermal/thermal_zone*; do
        mc="$(cat "${z}/temp" 2>/dev/null)"; [[ "${mc}" =~ ^[0-9]+$ ]] && s+="$(cat "${z}/type")=$(( mc / 1000 ))C "
    done
    echo "${s:-n/a}"
}
sampler() {   # one line per 0.5 s: time, lowest and highest clock (kHz), temperatures, cpufreq cooling states
    local t0 f cs d; t0="$(date +%s%N)"
    while :; do
        f="$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | sort -n | sed -n '1p;$p' | tr '\n' ' ')"
        cs=""
        for d in /sys/class/thermal/cooling_device*; do
            [[ "$(cat "${d}/type" 2>/dev/null)" == *cpufreq* ]] && cs+="$(cat "${d}/cur_state") "
        done
        printf 'sample t=%s freq_min_max_khz=%s temps=%s cpufreq_cooling=%s\n' \
            "$(awk -v a="${t0}" -v b="$(date +%s%N)" 'BEGIN {printf "%.1f", (b - a) / 1e9}')" "${f:-n/a}" "$(temps)" "${cs:-n/a}"
        sleep 0.5
    done
}
for steps in 200 60 200 60; do
    sleep 60
    echo "== run ${steps} steps $(date +%T), before: $(temps)"
    sampler & sp=$!
    p6_mpirun "${CORES}" "${EXE}" 64 "${steps}" 10 2>&1 | grep '^SweepgenLdcCPU variant='
    kill "${sp}"; wait "${sp}" 2>/dev/null
done
echo "== THERMAL DONE $(date)"
