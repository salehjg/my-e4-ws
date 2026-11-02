#!/usr/bin/env bash
# Push the repo to the Banana Pi F3 (SpacemiT K1, VLEN=256) and run pytest against
# the pystencils checkout there, natively on riscv64.
#
# Usage:   bash test.on.bananapi.sh <pytest-args...>
# Example: bash test.on.bananapi.sh tests/nbackend/test_rvv_codegen.py -q
#          NO_PUSH=1 bash test.on.bananapi.sh -k RISCV_RVV tests/nbackend   # skip the sync
#
# Notes:
#   * `-o addopts=''` is required -- the venv's pytest reads pystencils'
#     [tool.pytest] addopts which demand pytest-cov + --doctest-modules.
#   * PYTHONPATH=src (never `pip install -e`), so the synced tree is used as-is.
#   * The board is a SHARED machine; everything stays under /home/bananapi/saleh/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_REPO="/home/bananapi/saleh/my-e4-ws"
REMOTE_PY="/home/bananapi/saleh/venv/bin/python"

if [[ "${NO_PUSH:-0}" != "1" ]]; then
    bash "${HERE}/push.to.sh" bananapi
fi

# shellcheck disable=SC2029
ssh bananapi "cd ${REMOTE_REPO}/submodules/pystencils \
  && PYTHONPATH=src ${REMOTE_PY} -m pytest -o addopts='' -p no:cacheprovider $*"
