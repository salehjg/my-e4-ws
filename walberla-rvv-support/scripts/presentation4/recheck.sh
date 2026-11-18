#!/usr/bin/env bash
# Interleaved recheck of the two method checks of extras.sh (docs/presentation4), one core.
#
# Why: extras.sh ran the 3 runs of each configuration back to back. In three of its four sessions
# the same executables ran 4 to 10 % slower than in all.sh, the wall sweeps (fixed work, same field
# hashes) included, so the board itself was slower then, and comparisons between sessions are
# unreliable. Here the two sides of each comparison alternate run by run, and the order flips every
# round (A B, B A, A B), so a slow period hits both sides:
#   1. warm-up 10 against 2000 steps, Clang f32 explicit_cse_aa_pf (extras: 5.58 against 5.86
#      MLUP/s; all.sh, warm-up 10: 6.19)
#   2. plain scalar and best scalar (scalar, scalar_cse_aa): vector tree against scalar tree, both
#      compilers and precisions
# Reference at the start and at the end: GCC f64 scalar_cse_aa with warm-up 10, which is exactly
# all.sh's configuration (all.sh 1.457, extras 1.333 MLUP/s): it shows the board's state.
# Before every run: the number of busy cores during one second (our runs are not running then)
# and the busiest processes, as evidence of other load on the shared board.
#
# No build (SKIP_BUILD=1): the executables of prepare.sh and the vector-tree scalar executables of
# extras.sh, each tied to its earlier log by the sha256 that run.sh prints.
#
# Start it on the board, detached:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-recheck bash -c \
#       "bash scripts/presentation4/recheck.sh > ../presentation4/logs/recheck.log 2>&1"
# Logs in LOGDIR (default <base>/presentation4/logs): recheck-<name>.log, one per configuration,
# all its runs appended (summary.py reads them as they are).
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

run1() {   # run1 <log name> <cc> <prec> <variant> <reps> [VAR=value ...]
    local name="$1" cc="$2" prec="$3" v="$4" reps="$5"; shift 5
    echo "== $(date +%T) ${name}: busy cores $(busy); top: $(ps -eo pcpu,comm --sort=-pcpu --no-headers \
        | awk '$2 != "ps"' | head -3 | tr -s ' ' | paste -sd ',')"
    env "$@" SKIP_BUILD=1 REPS="${reps}" bash "${HERE}/run.sh" "${cc}" "${prec}" 1 "${v}" \
        >> "${LOGDIR}/recheck-${name}.log" 2>&1
    grep -h '^SweepgenLdcCPU variant=' "${LOGDIR}/recheck-${name}.log" | tail -n "${reps}" \
        | sed -E 's/.*(mlups=[^ ]+).*(fieldhash=[^ ]+).*(t_bc=[^ ]+)/   \1 \2 \3/'
}

echo "== start $(date), ${ROUNDS} rounds"
run1 ref-start gcc f64 scalar_cse_aa 3

for r in $(seq 1 "${ROUNDS}"); do
    if (( r % 2 )); then order="10 2000"; else order="2000 10"; fi
    for w in ${order}; do
        run1 "warmup-clang-f32-${w}" clang f32 explicit_cse_aa_pf 1 WARMUP="${w}"
    done
done

for r in $(seq 1 "${ROUNDS}"); do
    if (( r % 2 )); then order="scalar vector"; else order="vector scalar"; fi
    for cc in gcc clang; do
        for prec in f32 f64; do
            for v in scalar scalar_cse_aa; do
                for t in ${order}; do
                    if [[ "${t}" == vector ]]; then
                        run1 "${t}tree-${cc}-${prec}-${v}" "${cc}" "${prec}" "${v}" 1 TREE_KIND=vector
                    else
                        run1 "${t}tree-${cc}-${prec}-${v}" "${cc}" "${prec}" "${v}" 1
                    fi
                done
            done
        done
    done
done

run1 ref-end gcc f64 scalar_cse_aa 3

echo
L="${LOGDIR}/recheck"
"${VENV}/bin/python" "${HERE}/summary.py" "reference start=${L}-ref-start.log" "reference end=${L}-ref-end.log"
"${VENV}/bin/python" "${HERE}/summary.py" "clang f32 warm-up 10=${L}-warmup-clang-f32-10.log" \
    "clang f32 warm-up 2000=${L}-warmup-clang-f32-2000.log"
for cc in gcc clang; do
    for prec in f32 f64; do
        "${VENV}/bin/python" "${HERE}/summary.py" \
            "${cc} ${prec} scalar tree=${L}-scalartree-${cc}-${prec}-scalar.log" \
            "${cc} ${prec} scalar tree=${L}-scalartree-${cc}-${prec}-scalar_cse_aa.log" \
            "${cc} ${prec} vector tree=${L}-vectortree-${cc}-${prec}-scalar.log" \
            "${cc} ${prec} vector tree=${L}-vectortree-${cc}-${prec}-scalar_cse_aa.log"
    done
done
echo "== RECHECK DONE $(date)"
