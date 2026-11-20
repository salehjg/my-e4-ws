#!/usr/bin/env bash
# notes5 audit, board experiment E4 (finding F15): sequential vs random line order past the stream cliff.
#   1. pointer chase (misc/x60-lab probes/mem.cpp "lat K", the binary of streams_check.sh): K = 1, 6 (MLP today)
#   2. stream_order (docs/notes5/board/stream_order.cpp): R = 8, 16, 19, 24, 32 read streams, seq vs rand,
#      huge pages, stagger 4160; R = 24 also with 4 KB pages; 2 rounds, order flipped
#   3. mem.cpp "stream 24 0" for the same R as a cross-check of the new probe's seq numbers
# Core 2, no perf. Waits until notes5-e1/e2/e3 have ended. Start detached:
#   screen -dmS notes5-e4 bash -c "bash /home/bananapi/saleh/notes5/audit_e4.sh > /home/bananapi/saleh/notes5/e4.log 2>&1"
set -u
OUT=/home/bananapi/saleh/notes5
MEM=/home/bananapi/saleh/presentation4/probe/mem
CPU=2
while screen -ls 2>/dev/null | grep -q -E "notes5-e[123]"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
g++ -O2 -march=rv64gcv_zvl256b "${OUT}/stream_order.cpp" -o "${OUT}/stream_order" || { echo "BUILD FAILED"; exit 1; }
echo "== stream_order $(sha256sum "${OUT}/stream_order.cpp" | cut -c1-16) source, $(sha256sum "${OUT}/stream_order" | cut -c1-16) binary"
echo "== mem $(sha256sum "${MEM}" | cut -c1-16)"
LOG="${OUT}/e4-stream-order.log"; : > "${LOG}"
for K in 1 6; do taskset -c "${CPU}" "${MEM}" lat "${K}" thp=1 | tee -a "${LOG}"; done
for round in 1 2; do
    orders="seq rand"; [[ "${round}" == 2 ]] && orders="rand seq"
    for R in 8 16 19 24 32; do
        for ord in ${orders}; do taskset -c "${CPU}" "${OUT}/stream_order" "${R}" "${ord}" thp=1 | tee -a "${LOG}"; done
    done
    for ord in ${orders}; do taskset -c "${CPU}" "${OUT}/stream_order" 24 "${ord}" thp=0 | tee -a "${LOG}"; done
    taskset -c "${CPU}" "${MEM}" stream 24 0 thp=1 stagger=4160 | tee -a "${LOG}"
    taskset -c "${CPU}" "${MEM}" stream 8 0 thp=1 stagger=4160 | tee -a "${LOG}"
done
echo "== E4 DONE $(date)"
