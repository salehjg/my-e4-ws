#!/usr/bin/env bash
# Push the repo to the Banana Pi F3 and run an arbitrary command in the remote repo
# root, with the board venv's python first on PATH and our pystencils on PYTHONPATH.
#
# Usage:   bash run.on.bananapi.sh <command...>
# Example: bash run.on.bananapi.sh python scripts/lbm_rvv_check.py
#          NO_PUSH=1 bash run.on.bananapi.sh python python/learn-lb-pystencil/lb-pystencils.py --target rvv --no-plot
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_REPO="/home/bananapi/saleh/my-e4-ws"
REMOTE_VENV="/home/bananapi/saleh/venv"

if [[ "${NO_PUSH:-0}" != "1" ]]; then
    bash "${HERE}/push.to.sh" bananapi
fi

# shellcheck disable=SC2029
ssh bananapi "cd ${REMOTE_REPO} \
  && export PATH=${REMOTE_VENV}/bin:\$PATH MPLBACKEND=Agg \
  && export PYTHONPATH=${REMOTE_REPO}/submodules/pystencils/src \
  && $*"
