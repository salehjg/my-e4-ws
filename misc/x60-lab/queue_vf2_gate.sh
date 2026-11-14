#!/usr/bin/env bash
# Re-run gate 2 of queue_lab3.sh (gate 1, the lab checksums, passed): unpack the staged pystencils
# change, run the RVV pytest files on the board; keep the change and write notes3/lab3.ok if they
# pass, restore the previous files otherwise.
#   screen -dmS notes3-lab3 bash misc/x60-lab/queue_vf2_gate.sh
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/home/bananapi/saleh/notes3
STAGE="${STAGE:-${OUT}/stage-vf.tgz}"
export PATH=/home/bananapi/saleh/venv/bin:$PATH XDG_CACHE_HOME=/home/bananapi/saleh/.cache
rm -f "${OUT}/lab3.ok"
cd "${REPO}"
BACKUP="${OUT}/stage-vf-backup.tgz"
tar -tzf "${STAGE}" > "${OUT}/stage-vf.files"
tar -czf "${BACKUP}" -T "${OUT}/stage-vf.files"
tar -xzf "${STAGE}"
cd "${REPO}/submodules/pystencils"
(
   echo "== pytest RVV with the new selector (retry) $(date)"
   PYTHONPATH=src python -m pytest -o addopts='' -p no:cacheprovider -q \
      tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py \
      tests/nbackend/test_rvv_execution.py tests/nbackend/test_vectorization.py
   rc=$?
   echo "== done $(date) rc=${rc}"
   exit ${rc}
) > "${OUT}/pytest-vf2.log" 2>&1
gate2=$?
cd "${REPO}"
if [[ ${gate2} -eq 0 ]]; then
   echo "gate 2 passed on retry $(date): new selector stays" > "${OUT}/lab3.ok"
else
   tar -xzf "${BACKUP}"
   echo "gate 2 failed on retry $(date): old selector restored" >> "${OUT}/lab3-gate.log"
fi
