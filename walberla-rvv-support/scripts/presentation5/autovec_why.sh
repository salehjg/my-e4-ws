#!/usr/bin/env bash
# Why does the board's GCC 14.2 not vectorize the generated stream/collide loop of SweepgenLdcCPU_autovec_cse_aa?
# Re-runs the exact compile command of the build tree with -fopt-info-vec-all, writing the object to a scratch
# file (the build tree is not touched).
set -u
T=/home/bananapi/saleh/presentation4/build-gcc-f32
OUT=/home/bananapi/saleh/presentation5/autovec-why
mkdir -p "$OUT"
cd "$T"
cmd=$(/home/bananapi/saleh/venv/bin/python - <<'PY'
import json
for e in json.load(open("compile_commands.json")):
    if e["file"].endswith("_gen/SweepgenLdcCPU_autovec_cse_aa/gen/SweepgenLdcCPU.cpp"):
        print(e["directory"]); print(e.get("command") or " ".join(e["arguments"]))
PY
)
dir=$(sed -n 1p <<< "$cmd"); c=$(sed -n 2p <<< "$cmd" | sed -E "s# -o [^ ]+# -o $OUT/k.o#")
cd "$dir"
echo "== $(g++ --version | head -1)"; echo "== flags: $(grep -oE -- '-(O[0-9]|march=[^ ]+|mtune=[^ ]+)' <<< "$c" | tr '\n' ' ')"
eval "$c -fopt-info-vec-all" > "$OUT/optinfo.txt" 2>&1; echo "rc=$?"
F=$(grep -o '[^ ]*_gen/SweepgenLdcCPU_autovec_cse_aa/gen/SweepgenLdcCPU.cpp' <<< "$c" | head -1)
echo "== ctr_0 loops at lines: $(grep -n 'for (int64_t ctr_0' "$F" | cut -d: -f1 | tr '\n' ' ')"
grep -E 'SweepgenLdcCPU.cpp:[0-9]+:[0-9]+: (optimized|missed)' "$OUT/optinfo.txt" | sed 's#.*SweepgenLdcCPU.cpp:##' | sort -t: -k1,1n -u | head -60
echo "== AUTOVEC WHY DONE"
