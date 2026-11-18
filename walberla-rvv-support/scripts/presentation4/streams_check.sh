#!/usr/bin/env bash
# Is the stream plot right, and is it the limit of our program? (docs/presentation4, slide
# "The real limit: too many data streams"; the plot is report 3's stream test.) One core.
#
# 1. The stream test of report 3, misc/x60-lab/probes/mem.cpp (unchanged), built here:
#    R read streams, 4 MB each, f32 vector loads (vle32), huge pages requested, array starts
#    staggered by S bytes. perf stat counts the X60's own events around each run:
#      l1d_prefetch_hit, l1d_prefetch_refill   lines the hardware prefetcher brought in and that
#                                              were then used / that it refilled
#      l1d_load_miss, l2_miss, l2_load_access  demand misses
#    The setup (filling the arrays) is removed by subtracting the same run with reps=0, so per
#    line = (count(reps=3) - count(reps=0)) / (3 * R * 4 MB / 64 B).
#    a. R = 1 ... 32, S = 4160 (report 3's value): if the hardware prefetcher stops at the cliff,
#       its hits per line fall to about zero there.
#    b. the same with S = 1600 and S = 12352: a cliff caused by the number of streams stays at the
#       same R; one caused by cache-set or DRAM-bank conflicts moves with the addresses.
#    c. the same with software prefetch (prefetch.r 512 bytes ahead, report 3's lever).
#    d. part a again at the end: the run-to-run spread.
# 2. The real program, GCC f32 and f64: the verified LDC executables of all.sh (sha256 printed),
#    64^3 cells, 20 steps minus 0 steps, same events: explicit_cse (AB pattern, 42 streams),
#    explicit_cse_pf, explicit_cse_aa (in place, 23 streams), explicit_cse_aa_pf,
#    explicit_cse_aa_split. Per cell update = (count(20) - count(0)) / (64^3 * 20).
# 3. Our loop's pattern in the stream test (slide "The stream test: the code behind the plot"): 19 read and
#    23 write streams, S = 4160, without and with software prefetch (prefetch.r 128 bytes ahead: report 3's
#    settings), 3 runs each, alternating, without perf (only the probe's own cycle counter). The probe
#    prints cycles per 64-byte line (best of its 3 passes); the slide shows the best of the 3 runs.
#
# STREAMS_PARTS selects the sections (default "sweep ldc pattern"), e.g. STREAMS_PARTS=pattern. (Not PARTS:
# all.sh uses that name, and a child script would inherit it.)
#
# It first waits until the screen presentation4-recheck has ended (no two timing jobs at once).
# Start it on the board, detached:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-streams bash -c \
#       "bash scripts/presentation4/streams_check.sh > ../presentation4/logs/streams.log 2>&1"
# Logs in LOGDIR: streams.log (this), streams-probe.log and streams-ldc.log (every run: a header
# line, the program's own result line, perf's CSV lines), streams-pattern.log (section 3: a header line
# and the probe's result line per run). scripts/presentation4/streams_table.py turns them into tables.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
CPU="${CPU:-2}"
PROBE_DIR="${P4DIR}/probe"
mkdir -p "${LOGDIR}" "${PROBE_DIR}"
EV1="cycles,instructions,l1d_prefetch_hit,l1d_prefetch_refill"
EV2="l1d_load_miss,l2_miss,l2_load_access,stalled_cycle_backend"
RS="1 2 4 6 8 10 12 14 16 17 18 19 20 21 22 23 24 28 32"
STREAMS_PARTS="${STREAMS_PARTS:-sweep ldc pattern}"
want() { [[ " ${STREAMS_PARTS} " == *" $1 "* ]]; }

echo "== waiting for screen presentation4-recheck to end $(date)"
while screen -ls 2>/dev/null | grep -q presentation4-recheck; do sleep 30; done
echo "== start $(date), host $(hostname), load: $(cut -d' ' -f1-3 /proc/loadavg), sections: ${STREAMS_PARTS}"

SRC="${REPO}/misc/x60-lab/probes/mem.cpp"
echo "== probe source $(sha256sum "${SRC}" | cut -c1-16) ${SRC}"
g++ -O2 -march=rv64gcv_zvl256b_zicboz "${SRC}" -o "${PROBE_DIR}/mem" || { echo "BUILD FAILED"; exit 1; }
echo "== probe binary $(sha256sum "${PROBE_DIR}/mem" | cut -c1-16) (g++ -O2 -march=rv64gcv_zvl256b_zicboz)"

counted() {   # counted <log> <header> <events> <command...>: one run under perf stat, appended to <log>
    local log="$1" header="$2" ev="$3"; shift 3
    local tmp; tmp="$(mktemp)"
    {
        echo "== ${header} events=${ev}"
        taskset -c "${CPU}" perf stat -x, -e "${ev}" -o "${tmp}" "$@" 2>&1 | grep -E '^(stream|SweepgenLdcCPU)'
        grep -v -E '^#|^$' "${tmp}" | sed 's/^/perf,/'
    } >> "${log}"
    rm -f "${tmp}"
}

probe_sweep() {   # probe_sweep <tag> <stagger> <pfr>
    local tag="$1" s="$2" pfr="$3"
    echo "== probe ${tag}: stagger=${s} pfr=${pfr} $(date +%T)"
    for R in ${RS}; do
        for reps in 3 0; do
            for ev in "${EV1}" "${EV2}"; do
                counted "${LOGDIR}/streams-probe.log" "probe tag=${tag} R=${R} stagger=${s} pfr=${pfr} reps=${reps}" \
                    "${ev}" "${PROBE_DIR}/mem" stream "${R}" 0 thp=1 stagger="${s}" pfr="${pfr}" reps="${reps}"
            done
        done
    done
}

if want sweep; then
: > "${LOGDIR}/streams-probe.log"
probe_sweep a 4160 0
probe_sweep b1 1600 0
probe_sweep b2 12352 0
probe_sweep c 4160 512
probe_sweep d 4160 0

fi
if want ldc; then
: > "${LOGDIR}/streams-ldc.log"
for prec in f32 f64; do
    for v in explicit_cse explicit_cse_pf explicit_cse_aa explicit_cse_aa_pf explicit_cse_aa_split; do
        exe="${P4DIR}/build-gcc-${prec}/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_${v}"
        echo "== ldc gcc ${prec} ${v}: sha256 $(sha256sum "${exe}" | cut -c1-16) $(date +%T)"
        echo "   sha256 $(sha256sum "${exe}" | cut -c1-16) ${exe}" >> "${LOGDIR}/streams-ldc.log"
        for steps in 20 0; do
            for ev in "${EV1}" "${EV2}"; do
                counted "${LOGDIR}/streams-ldc.log" "ldc cc=gcc prec=${prec} variant=${v} cells=64 steps=${steps}" \
                    "${ev}" "${exe}" 64 "${steps}" 0
            done
        done
    done
done
fi
if want pattern; then
    : > "${LOGDIR}/streams-pattern.log"
    for run in 1 2 3; do
        for pfr in 0 128; do
            echo "== pattern R=19 W=23 stagger=4160 pfr=${pfr} run ${run} $(date +%T)"
            { echo "== pattern R=19 W=23 stagger=4160 pfr=${pfr} run=${run}"
              taskset -c "${CPU}" "${PROBE_DIR}/mem" stream 19 23 thp=1 stagger=4160 pfr="${pfr}"; } \
                >> "${LOGDIR}/streams-pattern.log" 2>&1
        done
    done
fi
echo "== STREAMS DONE $(date)"
