#!/usr/bin/env bash
# Two method checks of docs/presentation4, run after all.sh (one core, both compilers, f32 and f64):
#
#   1. Timing does not depend on the flow state. The cavity starts from rest, so the first steps
#      see a flow that is zero in most of the box. scalar_cse_aa and explicit_cse_aa_pf are timed
#      after 10 and after 2000 warm-up steps; the MLUP/s must agree within the run-to-run noise.
#      These are the verified executables of prepare.sh (SKIP_BUILD=1).
#   2. presentation3's scalar baseline: the scalar variants built in the vector tree (only the
#      app's own files get -march=rv64gc there, waLBerla's libraries keep -march=rv64gcv_zvl256b,
#      as in presentation3) against the fully scalar tree of presentation4. These executables are
#      built here. The generated sweeps and the app's own code get -march=rv64gc in both trees,
#      so their field hashes are expected to equal those of the scalar tree's runs in all.sh
#      (compared by hand in the progress log).
#
# Start it on the board, detached:
#   cd /home/bananapi/saleh/my-e4-ws && screen -dmS presentation4-extras bash -c \
#       "bash scripts/presentation4/extras.sh > ../presentation4/logs/extras.log 2>&1"
# Logs in LOGDIR (default <base>/presentation4/logs): extras-warmup-<cc>-<prec>-<10|2000>.log,
# extras-vectortree-<cc>-<prec>.log
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASE="$(dirname "${REPO}")"
P4DIR="${P4DIR:-${BASE}/presentation4}"
LOGDIR="${LOGDIR:-${P4DIR}/logs}"
VENV="${VENV:-${BASE}/venv}"
mkdir -p "${LOGDIR}"
echo "== start $(date)"

for cc in gcc clang; do
    for prec in f32 f64; do
        for w in 10 2000; do
            log="${LOGDIR}/extras-warmup-${cc}-${prec}-${w}.log"
            echo "== warm-up ${w}: ${cc} ${prec} $(date +%T) -> ${log}"
            SKIP_BUILD=1 WARMUP="${w}" bash "${HERE}/run.sh" "${cc}" "${prec}" 1 scalar_cse_aa explicit_cse_aa_pf > "${log}" 2>&1
        done
        log="${LOGDIR}/extras-vectortree-${cc}-${prec}.log"
        echo "== scalar variants in the vector tree: ${cc} ${prec} $(date +%T) -> ${log}"
        TREE_KIND=vector bash "${HERE}/run.sh" "${cc}" "${prec}" 1 scalar scalar_cse scalar_cse_aa > "${log}" 2>&1
    done
done

echo
for cc in gcc clang; do
    for prec in f32 f64; do
        "${VENV}/bin/python" "${HERE}/summary.py" \
            "${cc} ${prec} warm-up 10=${LOGDIR}/extras-warmup-${cc}-${prec}-10.log" \
            "${cc} ${prec} warm-up 2000=${LOGDIR}/extras-warmup-${cc}-${prec}-2000.log" \
            "${cc} ${prec} scalar tree=${LOGDIR}/ldc-${cc}-scalar-${prec}-1core.log" \
            "${cc} ${prec} vector tree=${LOGDIR}/extras-vectortree-${cc}-${prec}.log"
    done
done
echo "== EXTRAS DONE $(date)"
