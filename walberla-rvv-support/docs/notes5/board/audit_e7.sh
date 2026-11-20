#!/usr/bin/env bash
# notes5 audit, board experiment E7 (finding F19): do vector-load misses overlap on the X60, and do true scalar
# loads collapse at the stream cliff too?
#   - stream_order (docs/notes5/board/stream_order.cpp) built with -fno-tree-vectorize -fno-tree-slp-vectorize, so
#     its scalar=1 path is really scalar (with plain -O2 GCC turns the 8 scalar loads into vluxei64 gathers); the
#     vector path uses intrinsics and is unaffected. R = 8, 16, 24 x seq/rand x vector/scalar, huge pages.
#   - misc/x60-lab/probes/mem.cpp rebuilt the same way: "stream R 0 scalar=1" for R = 8, 16, 24, 32, against
#     notes3's p2-stream-levers.txt (352 cycles per line at R = 24, measured with the gather-vectorized binary).
# Core 2, 2 rounds. Waits for notes5-e6. Start detached:
#   screen -dmS notes5-e7 bash -c "bash /home/bananapi/saleh/notes5/audit_e7.sh > /home/bananapi/saleh/notes5/e7.log 2>&1"
set -u
OUT=/home/bananapi/saleh/notes5
REPO=/home/bananapi/saleh/my-e4-ws
CPU=2
while screen -ls 2>/dev/null | grep -q -E "notes5-e[3456]"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), freq $(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | tr '\n' ' ')"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
FL="-O2 -march=rv64gcv_zvl256b -fno-tree-vectorize -fno-tree-slp-vectorize"
g++ ${FL} "${OUT}/stream_order.cpp" -o "${OUT}/stream_order_nv" || { echo "BUILD FAILED"; exit 1; }
g++ ${FL/rv64gcv_zvl256b/rv64gcv_zvl256b_zicboz} "${REPO}/misc/x60-lab/probes/mem.cpp" -o "${OUT}/mem_nv" || { echo "BUILD FAILED"; exit 1; }
for b in stream_order_nv mem_nv; do
    echo "== ${b} $(sha256sum "${OUT}/${b}" | cut -c1-16): gathers $(llvm-objdump -d --mattr=+v "${OUT}/${b}" | grep -c -E 'vluxei|vloxei'), flw $(llvm-objdump -d "${OUT}/${b}" | grep -c flw)"
done
echo "== board mem (streams_check.sh build): gathers $(llvm-objdump -d --mattr=+v /home/bananapi/saleh/presentation4/probe/mem | grep -c -E 'vluxei|vloxei')"
LOG="${OUT}/e7-scalar-vs-vector.log"; : > "${LOG}"
for round in 1 2; do
    for R in 8 16 24; do
        for ord in seq rand; do
            for sc in 0 1; do taskset -c "${CPU}" "${OUT}/stream_order_nv" "${R}" "${ord}" thp=1 scalar="${sc}" | tee -a "${LOG}"; done
        done
    done
    for R in 8 16 24 32; do
        taskset -c "${CPU}" "${OUT}/mem_nv" stream "${R}" 0 thp=1 stagger=4160 scalar=1 | tee -a "${LOG}"
    done
done
echo "== E7 DONE $(date)"
