#!/usr/bin/env bash
# Baseline comparison for the D2Q9 LBM harness (python/learn-lb-pystencil/lb-pystencils.py).
#
# Six configurations -- the same pystencils kernels, built three ways, each with GCC and Clang:
#   scalar   generic kernels, -march=rv64gc   (no V extension at all -> truly scalar code)
#   autovec  generic kernels, -march=rv64gcv_zvl256b (the compiler auto-vectorizes with RVV)
#   rvv      our explicit RVV backend (Target.RISCV_RVV, VLS, VLEN = 256)
# on three full-step workloads (f64 cavity with NumPy reference, f64 + f32 periodic
# Taylor-Green with checksums). Each run is repeated REPS times; the summary reports the best.
#
# Each configuration gets its own JIT object cache (XDG_CACHE_HOME), so afterwards we can
# disassemble exactly that configuration's kernels and count RVV instructions -- this proves
# that "scalar" really contains none and the others do.
#
# Usage (on the board, from anywhere):  bash scripts/lbm_baselines.sh [REPS]
# Output: per-run log lines + a markdown summary table at the end (stdout).
set -u

REPS="${1:-3}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LB="${REPO}/python/learn-lb-pystencil/lb-pystencils.py"
#   Next to the repo, not in $HOME: the board is shared, we only write under /home/bananapi/saleh
CACHE_ROOT="${CACHE_ROOT:-$(dirname "${REPO}")/.cache/lbm-baselines}"
RESULTS="$(mktemp)"

#   Board defaults (overridable from the environment)
export PATH="${VENV:-/home/bananapi/saleh/venv}/bin:${PATH}"
export PYTHONPATH="${REPO}/submodules/pystencils/src"
export MPLBACKEND=Agg

CONFIGS=(
    "scalar-gcc|--target generic --compiler gcc --extra-cxxflags=-march=rv64gc"
    "scalar-clang|--target generic --compiler clang --extra-cxxflags=-march=rv64gc"
    "autovec-gcc|--target generic --compiler gcc"
    "autovec-clang|--target generic --compiler clang"
    "rvv-gcc|--target rvv --compiler gcc"
    "rvv-clang|--target rvv --compiler clang"
)
WORKLOADS=(
    "f64-cavity-100x100x200|--dtype f64 --nx 100 --ny 100 --steps 200"
    "f64-periodic-200x200x100|--dtype f64 --periodic --nx 200 --ny 200 --steps 100"
    "f32-periodic-200x200x100|--dtype f32 --periodic --nx 200 --ny 200 --steps 100"
)

#   Fresh caches: the instruction count below must only see this run's modules
rm -rf "${CACHE_ROOT}"

echo "== lbm baselines start $(date), reps=${REPS}"
for cfg in "${CONFIGS[@]}"; do
    cname="${cfg%%|*}"; cargs="${cfg#*|}"
    export XDG_CACHE_HOME="${CACHE_ROOT}/${cname}"   # per-config JIT cache
    for wl in "${WORKLOADS[@]}"; do
        wname="${wl%%|*}"; wargs="${wl#*|}"
        for rep in $(seq 1 "${REPS}"); do
            #   NumPy reference comparison only once per (config, workload): it is slow
            extra="--no-plot"; [[ "${rep}" -gt 1 ]] && extra="${extra} --no-compare"
            # shellcheck disable=SC2086
            out="$(python "${LB}" ${cargs} ${wargs} ${extra} 2>&1)"
            mlups="$(grep -oP 'timing: .* -> \K[0-9.]+(?= MLUP/s)' <<<"${out}")"
            check="$(grep -oP 'rel_l2=[^,]+|sum_f=\S+' <<<"${out}" | head -1)"
            echo "${wname} ${cname} rep${rep} ${mlups:-FAIL} ${check}"
            echo "${wname},${cname},${mlups:-0},${check}" >> "${RESULTS}"
            [[ -z "${mlups}" ]] && echo "${out}" | tail -5
        done
    done
done

#   llvm-objdump, not GNU objdump: binutils 2.42 (Ubuntu 24.04) prints Clang's RVV code as
#   raw `.insn` words, so Clang builds would wrongly count as 0. LLVM decodes GCC output too.
OBJDUMP="${OBJDUMP:-llvm-objdump}"

echo
echo "== RVV instructions in each configuration's compiled kernels (${OBJDUMP})"
for cfg in "${CONFIGS[@]}"; do
    cname="${cfg%%|*}"
    n=0
    for so in $(find "${CACHE_ROOT}/${cname}" -name "*.so" 2>/dev/null); do
        #   all RVV mnemonics start with 'v' (vle64.v, vfadd.vv, vsetvli, ...)
        k=$("${OBJDUMP}" -d --no-show-raw-insn "${so}" | awk '$2 ~ /^v/ {n++} END {print n+0}')
        n=$((n + k))
    done
    echo "${cname}: ${n}"
done

echo
echo "== Summary: best MLUP/s of ${REPS} runs (check value from the runs)"
python - "${RESULTS}" <<'EOF'
import sys, collections
best, check = collections.defaultdict(float), {}
order_w, order_c = [], []
for line in open(sys.argv[1]):
    w, c, mlups, chk = line.rstrip("\n").split(",", 3)
    if w not in order_w: order_w.append(w)
    if c not in order_c: order_c.append(c)
    best[w, c] = max(best[w, c], float(mlups))
    check.setdefault((w, c), chk)
print("| workload | " + " | ".join(order_c) + " |")
print("|---" * (len(order_c) + 1) + "|")
for w in order_w:
    print(f"| {w} | " + " | ".join(f"{best[w, c]:.2f}" for c in order_c) + " |")
print()
for w in order_w:
    print(f"{w}: " + "; ".join(f"{c} {check[w, c]}" for c in order_c))
EOF
rm -f "${RESULTS}"
echo "== done $(date)"
