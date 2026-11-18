#!/usr/bin/env bash
# Do the headline speedups repeat in another session? (docs/presentation4, one core.)
#
# Why: the recheck (recheck.sh) found that the same scalar executables run up to 10 % slower than in
# all.sh on an idle board, while an RVV executable ran as fast as in all.sh. A speedup is a ratio of
# two runs, so here its two sides alternate run by run: plain scalar, RVV in place + prefetch and
# RVV split loop (scalar, explicit_cse_aa_pf, explicit_cse_aa_split), both compilers and precisions,
# 3 rounds, the order reversed every second round. No build (SKIP_BUILD=1): the verified executables
# of all.sh, each tied to its log by the sha256 that run.sh prints.
#
# It first waits until the screen presentation4-streams has ended (no two timing jobs at once).
# Start it on the board, detached:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-speedup bash -c \
#       "bash scripts/presentation4/speedup_check.sh > ../presentation4/logs/speedup.log 2>&1"
# Logs in LOGDIR: speedup.log (this, with a short line per run), speedup-<cc>-<prec>-<variant>.log.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
VENV="${VENV:-${BASE}/venv}"
ROUNDS="${ROUNDS:-3}"
mkdir -p "${LOGDIR}"

busy() {   # cores busy during one second, from /proc/stat (idle = idle + iowait)
    local a b c d e f g h A B C D E F G H
    read -r _ a b c d e f g h _ < /proc/stat; sleep 1; read -r _ A B C D E F G H _ < /proc/stat
    awk -v i=$(( (D + E) - (d + e) )) -v t=$(( (A + B + C + D + E + F + G + H) - (a + b + c + d + e + f + g + h) )) \
        -v n="$(nproc)" 'BEGIN { printf "%.2f of %d", n * (t - i) / t, n }'
}

echo "== waiting for screen presentation4-streams to end $(date)"
while screen -ls 2>/dev/null | grep -q presentation4-streams; do sleep 30; done
echo "== start $(date), ${ROUNDS} rounds"

for r in $(seq 1 "${ROUNDS}"); do
    if (( r % 2 )); then order="scalar explicit_cse_aa_pf explicit_cse_aa_split"
    else order="explicit_cse_aa_split explicit_cse_aa_pf scalar"; fi
    for cc in gcc clang; do
        for prec in f32 f64; do
            for v in ${order}; do
                log="${LOGDIR}/speedup-${cc}-${prec}-${v}.log"
                echo "== $(date +%T) ${cc} ${prec} ${v}: busy cores $(busy)"
                SKIP_BUILD=1 REPS=1 bash "${HERE}/run.sh" "${cc}" "${prec}" 1 "${v}" >> "${log}" 2>&1
                grep -h '^SweepgenLdcCPU variant=' "${log}" | tail -n 1 \
                    | sed -E 's/.*(mlups=[^ ]+).*(fieldhash=[^ ]+).*(t_bc=[^ ]+)/   \1 \2 \3/'
            done
        done
    done
done

echo
for cc in gcc clang; do
    for prec in f32 f64; do
        "${VENV}/bin/python" "${HERE}/summary.py" \
            "${cc} ${prec} 1c=${LOGDIR}/speedup-${cc}-${prec}-scalar.log" \
            "${cc} ${prec} 1c=${LOGDIR}/speedup-${cc}-${prec}-explicit_cse_aa_pf.log" \
            "${cc} ${prec} 1c=${LOGDIR}/speedup-${cc}-${prec}-explicit_cse_aa_split.log"
    done
done
echo "== SPEEDUP DONE $(date)"
