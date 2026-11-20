#!/usr/bin/env bash
# presentation5: are long 8-core runs slower because the chip throttles?
# steps_check.sh found 8-core runs of 200 steps 2-5 % slower per step than runs of 60 or 30 steps (1-core runs:
# no difference). Under 8-core load the clusters reach 70-72 C; the K1's first passive trip point (cpufreq
# cooling) is 75 C. This job runs RVV in place + prefetch (GCC f64, 8 cores, the verified presentation4
# executable) for 200 and for 60 steps, twice each with a 60 s pause before every run, and samples every core's
# clock, the temperatures and the cpufreq cooling state every 0.5 s during each run.
# Start on the board, detached (about 6 min):
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation5-thermal \
#       bash -c "bash scripts/presentation5/thermal_check.sh > ../presentation5/logs/thermal.log 2>&1"
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
EXE="${P4DIR}/build-gcc-f64/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_explicit_cse_aa_pf"
# shellcheck source=env_record.sh
source "${HERE}/env_record.sh"
while screen -ls 2>/dev/null | grep -E "presentation4|notes5|presentation5" | grep -v presentation5-thermal | grep -q .; do sleep 20; done
h="$(sha256sum "${EXE}" | cut -c1-16)"
awk -v h="${h}" -v p="${EXE}" '$1 == "sha256" && $2 == h && $3 == p {f = 1} END {exit !f}' "${P4DIR}/logs/verify-gcc-f64.log" \
    && echo "   verified ${h} ${EXE}" || { echo "ABORT: NOT VERIFIED ${EXE}"; exit 1; }
echo "== start $(date)"; env_record

sampler() {   # one line per 0.5 s: time, max/min clock (MHz), cluster temps (C), cpufreq cooling state
    local t0; t0="$(date +%s.%N)"
    while :; do
        local f c0 c1 cs
        f="$(cat /sys/devices/system/cpu/cpu[0-7]/cpufreq/scaling_cur_freq | sort -n | sed -n '1p;$p' | tr '\n' ' ')"
        c0=$(( $(cat /sys/class/thermal/thermal_zone2/temp) / 1000 )); c1=$(( $(cat /sys/class/thermal/thermal_zone3/temp) / 1000 ))
        cs="$(cat /sys/class/thermal/cooling_device0/cur_state)"
        printf 'sample t=%.1f freq_min_max_khz=%s cluster0=%sC cluster1=%sC cpufreq_cooling=%s\n' \
            "$(echo "$(date +%s.%N) - ${t0}" | bc)" "${f% }" "${c0}" "${c1}" "${cs}"
        sleep 0.5
    done
}
for steps in 200 60 200 60; do
    sleep 60
    echo "== run ${steps} steps $(date +%T), before: $(cat /sys/class/thermal/thermal_zone2/temp) $(cat /sys/class/thermal/thermal_zone3/temp)"
    sampler & sp=$!
    mpirun -np 8 --bind-to core --map-by core "${EXE}" 64 "${steps}" 10 2>&1 | grep '^SweepgenLdcCPU variant='
    kill "${sp}"; wait "${sp}" 2>/dev/null
done
echo "== THERMAL DONE $(date)"
