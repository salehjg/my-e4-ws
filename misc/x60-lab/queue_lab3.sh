#!/usr/bin/env bash
# Board job for docs/notes3 Loop 10 (RVV selector: .vf operands + fused multiply-add). Runs ON THE
# BOARD, detached:
#   screen -dmS notes3-lab3 bash misc/x60-lab/queue_lab3.sh
# Waits until no screen session matching WAIT_FOR is left, then
#   1. lab A/B: each kernel generated with the old selector and with the new one (`+vf2`)   -> notes3/lab3.log
#   2. gate 1: every new kernel's checksum matches its old twin (f32 rtol 1e-5, f64 rtol 1e-10)
#   3. unpacks STAGE (the pystencils change) and runs the RVV pytest files on the board      -> notes3/pytest-vf2.log
#   4. gate 2: pytest passes. Both gates passed: the change stays and notes3/lab3.ok is written
#      (the waLBerla e2e job that follows builds with it). Otherwise the old files are restored.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-vf.tgz}"
WAIT_FOR="${WAIT_FOR:-notes3-(next|clang|aa64|lab2)}"
while screen -ls | grep -qE "${WAIT_FOR}"; do sleep 30; done
rm -f "${OUT}/lab3.ok"

export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
cd "${REPO}/misc/x60-lab/lab"
{
   echo "== lab3: old vs new RVV selector $(date)"
   for v in f32-rvv-cse "f32-rvv-cse+bpf=128" f64-rvv-cse+bpf=128; do
      TAG=lab3 bash run.sh "$v" "$v+vf2"
   done
   for v in f32-rvv-cse+aa "f32-rvv-cse+aa+bpf=128" "f64-rvv-cse+aa+bpf=128"; do
      TAG=lab3 RUNENV="AA=1" bash run.sh "$v" "$v+vf2"
   done
   echo "== done $(date)"
} > "${OUT}/lab3.log" 2>&1

python3 - "${OUT}/lab3.log" > "${OUT}/lab3-gate.log" 2>&1 <<'EOF'
import re, sys
energy = {}
for line in open(sys.argv[1]):
    m = re.match(r"gcc-O3-(\S+)\t.*energy=(\S+)", line)
    if m:
        energy[m.group(1)] = float(m.group(2))
ok = bool(energy)
for name, e_new in energy.items():
    if not name.endswith("+vf2"):
        continue
    old = name[: -len("+vf2")]
    rtol = 1e-5 if name.startswith("f32") else 1e-10
    rel = abs(e_new - energy.get(old, float("nan"))) / abs(energy.get(old, float("nan")))
    good = rel <= rtol
    ok &= good
    print(f"{name}: energy {e_new:.12e} vs {energy.get(old)} rel {rel:.2e} {'ok' if good else 'MISMATCH'}")
print("GATE1", "ok" if ok else "FAILED")
sys.exit(0 if ok else 1)
EOF
gate1=$?

cd "${REPO}"
BACKUP="${OUT}/stage-vf-backup.tgz"
tar -tzf "${STAGE}" > "${OUT}/stage-vf.files"
tar -czf "${BACKUP}" -T "${OUT}/stage-vf.files"
tar -xzf "${STAGE}"
cd "${REPO}/submodules/pystencils"
(
   echo "== pytest RVV with the new selector $(date)"
   PYTHONPATH=src python -m pytest -o addopts='' -p no:cacheprovider -q \
      tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py \
      tests/nbackend/test_rvv_execution.py tests/nbackend/test_vectorization.py
   rc=$?
   echo "== done $(date) rc=${rc}"
   exit ${rc}
) > "${OUT}/pytest-vf2.log" 2>&1
gate2=$?

cd "${REPO}"
if [[ ${gate1} -eq 0 && ${gate2} -eq 0 ]]; then
   echo "lab3 gates passed $(date): new selector stays" > "${OUT}/lab3.ok"
else
   tar -xzf "${BACKUP}"
   echo "lab3 gates failed (gate1=${gate1} gate2=${gate2}) $(date): old selector restored" >> "${OUT}/lab3-gate.log"
fi
