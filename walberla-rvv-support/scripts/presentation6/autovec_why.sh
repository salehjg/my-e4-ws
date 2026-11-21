#!/usr/bin/env bash
# presentation6: why does the compiler not vectorize the generated stream/collide loop of
# SweepgenLdcCPU_autovec_cse_aa? (presentation5's autovec_why.sh on the machine profile of machine.sh.) Re-runs the
# exact compile command of the build tree with -fopt-info-vec-all, writing the object to a scratch file (the
# build tree is not touched). GCC only (-fopt-info is a GCC option).
# Usage: bash scripts/presentation6/autovec_why.sh [f32|f64]   (default f32); output in <base>/presentation6/autovec-why
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=machine.sh
source "${HERE}/machine.sh"
PREC="${1:-f32}"
T="${BUILD_ROOT}/build-gcc-${PREC}"
OUT="${P6DIR}/autovec-why/${PREC}"
mkdir -p "${OUT}"
cd "${T}" || exit 1
cmd=$("${PY}" - <<'PY'
import json
for e in json.load(open("compile_commands.json")):
    if e["file"].endswith("_gen/SweepgenLdcCPU_autovec_cse_aa/gen/SweepgenLdcCPU.cpp"):
        print(e["directory"]); print(e.get("command") or " ".join(e["arguments"]))
PY
)
dir=$(sed -n 1p <<< "${cmd}"); c=$(sed -n 2p <<< "${cmd}" | sed -E "s# -o [^ ]+# -o ${OUT}/k.o#")
cd "${dir}" || exit 1
echo "== ${MACHINE}, $(g++ --version | head -1)"; echo "== flags: $(grep -oE -- '-(O[0-9]|march=[^ ]+|mtune=[^ ]+)' <<< "${c}" | tr '\n' ' ')"
eval "${c} -fopt-info-vec-all" > "${OUT}/optinfo.txt" 2>&1; echo "rc=$?"
F=$(grep -o '[^ ]*_gen/SweepgenLdcCPU_autovec_cse_aa/gen/SweepgenLdcCPU.cpp' <<< "${c}" | head -1)
echo "== ctr_0 loops at lines: $(grep -n 'for (int64_t ctr_0' "${F}" | cut -d: -f1 | tr '\n' ' ')"
grep -E 'SweepgenLdcCPU.cpp:[0-9]+:[0-9]+: (optimized|missed)' "${OUT}/optinfo.txt" | sed 's#.*SweepgenLdcCPU.cpp:##' | sort -t: -k1,1n -u | head -60
echo "== AUTOVEC WHY DONE"
