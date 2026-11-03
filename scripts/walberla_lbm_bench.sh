#!/usr/bin/env bash
# End-to-end waLBerla benchmark on the board: build the SweepgenLbmCPU variants
# (submodules/walberla/apps/benchmarks/SweepgenLbmCPU) in the existing waLBerla build dir,
# run each one pinned to one core, and print a summary.
#
# Variants (see the app's CMakeLists.txt):
#   scalar    GenericCPU sweeps, -march=rv64gc (no V extension)
#   autovec   GenericCPU sweeps, -march=rv64gcv_zvl256b (GCC auto-vectorizes)
#   explicit  Target.CurrentCPU = RISCV_RVV, vectorized: our RVV backend
# each with lbmpy's default optimisation and with global CSE (_cse).
#
# Run it detached, so it survives a lost connection:
#   screen -dmS walberla-bench bash -c "bash scripts/walberla_lbm_bench.sh > ../walberla-bench.log 2>&1"
# Usage: bash scripts/walberla_lbm_bench.sh [CELLS=64] [STEPS=200] [REPS=3]
set -u

CELLS="${1:-64}"
STEPS="${2:-200}"
REPS="${3:-3}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${WALBERLA_BUILD:-$(dirname "${REPO}")/walberla-build}"
CPU="${CPU:-2}"
#   -j2: the heaviest waLBerla translation units need ~1.3 GB each, the board has 3.7 GB
JOBS="${JOBS:-2}"

export PATH="${VENV:-/home/bananapi/saleh/venv}/bin:${PATH}"
#   Code generation uses our pystencils and sweepgen from the synced repo
export PYTHONPATH="${REPO}/submodules/pystencils/src:${REPO}/submodules/walberla/sweepgen/src"
#   lbmpy/pystencils caches stay in our folder: the board is shared
export XDG_CACHE_HOME="$(dirname "${REPO}")/.cache"

TARGETS=""
for v in scalar autovec explicit; do TARGETS="${TARGETS} SweepgenLbmCPU_${v} SweepgenLbmCPU_${v}_cse"; done
APPDIR="${BUILD}/apps/benchmarks/SweepgenLbmCPU"

echo "== configure $(date)"
cmake "${BUILD}" > "${BUILD}/configure.log" 2>&1 || { echo "CONFIGURE FAILED"; tail -30 "${BUILD}/configure.log"; exit 1; }

for t in ${TARGETS}; do
    echo "== build ${t} $(date +%T)"
    if ! cmake --build "${BUILD}" --target "${t}" -j "${JOBS}" > "${BUILD}/build-${t}.log" 2>&1; then
        echo "BUILD FAILED ${t}"; grep -m20 -E "error|Error" "${BUILD}/build-${t}.log"
    fi
done

#   RVV instructions in each variant's generated sweep object (llvm-objdump: GNU objdump
#   2.42 cannot decode Clang's RVV code; it is used for GCC's here only for consistency)
echo
echo "== RVV instructions in the generated sweeps (gen/SweepgenLbmCPU.cpp.o)"
for t in ${TARGETS}; do
    obj="$(find "${APPDIR}/CMakeFiles/${t}.dir" -name 'SweepgenLbmCPU.cpp.o' -path '*_gen*' 2>/dev/null | head -1)"
    n="n/a"
    [[ -n "${obj}" ]] && n=$(llvm-objdump -d --no-show-raw-insn "${obj}" | awk '$2 ~ /^v/ {n++} END {print n+0}')
    echo "${t}: ${n}"
done

echo
echo "== run $(date), ${CELLS}^3 cells, ${STEPS} steps, ${REPS} reps, core ${CPU}"
RESULTS="$(mktemp)"
for t in ${TARGETS}; do
    exe="${APPDIR}/${t}"
    [[ -x "${exe}" ]] || { echo "${t}: missing"; continue; }
    for r in $(seq 1 "${REPS}"); do
        line="$(taskset -c "${CPU}" "${exe}" "${CELLS}" "${STEPS}" 10 2>&1 | grep '^SweepgenLbmCPU' || echo "${t} FAILED")"
        echo "${line}"
        echo "${line}" >> "${RESULTS}"
    done
done

echo
echo "== Summary: best MLUP/s of ${REPS} runs"
python - "${RESULTS}" <<'EOF'
import sys, re
best, energy = {}, {}
for line in open(sys.argv[1]):
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    if "mlups" not in kv:
        continue
    v = kv["variant"].replace("SweepgenLbmCPU_", "")
    best[v] = max(best.get(v, 0.0), float(kv["mlups"]))
    energy.setdefault(v, float(kv["energy"]))
base = best.get("scalar")
print("| variant | MLUP/s | vs scalar | kinetic energy (checksum) |")
print("|---|---|---|---|")
for v, m in best.items():
    rel = f"{m / base:.2f}x" if base else "-"
    print(f"| {v} | {m:.2f} | {rel} | {energy[v]:.12e} |")
EOF
rm -f "${RESULTS}"
echo "== done $(date)"
