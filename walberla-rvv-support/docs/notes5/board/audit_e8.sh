#!/usr/bin/env bash
# notes5 audit, board check E8: the pystencils RVV test files on the board copy of the committed fork
# (mirrored-pystencil2 rvv-support a81dc547; the board copy's src/ and tests/ were compared by sha256 with the
# laptop). As test.on.bananapi.sh, but detached, without a push, and without writing bytecode into the repo copy.
#   screen -dmS notes5-e8 bash -c "bash /home/bananapi/saleh/notes5/audit_e8.sh > /home/bananapi/saleh/notes5/e8.log 2>&1"
set -u
while screen -ls 2>/dev/null | grep -q -E "notes5-e[0-7]"; do sleep 20; done
echo "== start $(date)"
cd /home/bananapi/saleh/my-e4-ws/submodules/pystencils || exit 1
export XDG_CACHE_HOME=/home/bananapi/saleh/.cache PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src
/home/bananapi/saleh/venv/bin/python -m pytest -o addopts='' -p no:cacheprovider -q \
    tests/nbackend/test_rvv_target.py tests/nbackend/test_rvv_codegen.py tests/nbackend/test_rvv_execution.py 2>&1 | tail -15
echo "== rc=${PIPESTATUS[0]}"
echo "== E8 DONE $(date)"
