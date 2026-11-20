#!/usr/bin/env bash
# notes5 audit, board experiment E9 (finding F4): what memory bandwidth can the K1 deliver with 1, 2, 4, 8 cores?
# presentation4 slide 19 calls ~3.6 GB/s (estimated from bytes per cell) "the shared memory limit".
# N copies of the stream probe (misc/x60-lab/probes/mem.cpp, the streams_check.sh build; its stream path has no
# gathers) run at the same time, one per core (cores 0..N-1, i.e. cluster 0 first), each with its own arrays:
#   A  8 read streams per core (a pattern the prefetcher follows: 6 GB/s on one core)
#   B  the LBM pattern, 19 read + 23 write streams, with prefetch.r 128 B ahead (as the program's _pf builds)
#   C  2 read + 2 write streams per core
# mb=8 per stream (A: 64 MB per process, B: 336 MB per process at N = 1 only... see below), reps=10; every process
# prints its best pass, the sum over processes is an upper estimate of the concurrent bandwidth.
# Memory: B uses 42 x mb MB per process, so B runs with mb=2 (84 MB per process, 672 MB at N = 8).
#   screen -dmS notes5-e9 bash -c "bash /home/bananapi/saleh/notes5/audit_e9.sh > /home/bananapi/saleh/notes5/e9.log 2>&1"
set -u
OUT=/home/bananapi/saleh/notes5
MEM=/home/bananapi/saleh/presentation4/probe/mem
while screen -ls 2>/dev/null | grep -q -E "notes5-e[0-8]"; do sleep 20; done
echo "== start $(date), load $(cut -d' ' -f1-3 /proc/loadavg), MemAvailable $(awk '/MemAvailable/ {print $2}' /proc/meminfo) kB"
screen -ls | grep -E "presentation4" && { echo "ABORT: another timing job runs"; exit 1; }
LOG="${OUT}/e9-bandwidth.log"; : > "${LOG}"
run_n() { # run_n <tag> <N> <mem args...>
    local tag="$1" n="$2"; shift 2
    local tmp; tmp="$(mktemp -d)"
    for c in $(seq 0 $((n - 1))); do taskset -c "${c}" "${MEM}" "$@" > "${tmp}/${c}" 2>&1 & done
    wait
    local sum; sum="$(cat "${tmp}"/* | sed -n 's/.*GBps=\([0-9.]*\).*/\1/p' | awk '{s += $1} END {printf "%.3f", s}')"
    echo "${tag} N=${n} sum_GBps=${sum} per_process=$(cat "${tmp}"/* | sed -n 's/.*cyc_per_line=\([0-9.]*\) GBps=\([0-9.]*\).*/\2/p' | tr '\n' ' ')" | tee -a "${LOG}"
    rm -rf "${tmp}"
}
for round in 1 2; do
    for n in 1 2 4 8; do
        run_n "A-8read" "${n}" stream 8 0 thp=1 stagger=4160 mb=8 reps=10
        run_n "B-19r23w-pfr128" "${n}" stream 19 23 thp=1 stagger=4160 pfr=128 mb=2 reps=10
        run_n "C-2r2w" "${n}" stream 2 2 thp=1 stagger=4160 mb=8 reps=10
    done
done
echo "== E9 DONE $(date)"
