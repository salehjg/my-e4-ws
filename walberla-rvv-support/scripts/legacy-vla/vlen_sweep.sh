#!/usr/bin/env bash
# WP7 VLA acceptance: run the SAME VLA kernel binary at several emulated VLENs and
# check the output field hash is bit-identical. Runs ON the Banana Pi board.
#
#   ssh bananapi 'bash /home/bananapi/saleh/my-e4-ws/scripts/legacy-vla/vlen_sweep.sh'
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PY=/home/bananapi/saleh/venv/bin/python
PROBE=/home/bananapi/saleh/vlenb_probe   # persists outside the (wiped) repo dir

cd "$REPO"

echo "== Confirm QEMU can override VLEN =="
g++ -march=rv64gcv -O2 "$HERE/vlenb_probe.cpp" -o "$PROBE"
echo -n "  native:      "; "$PROBE"
for VL in 128 256 512 1024; do
    echo -n "  qemu vlen=$VL: "
    qemu-riscv64 -cpu "rv64,v=true,vlen=$VL" "$PROBE"
done

echo
echo "== VLA kernel output hash across VLENs (must all match) =="
echo -n "  native (VLEN=256): "
PYTHONPATH=submodules/pystencils/src "$PY" "$HERE/vlen_sweep.py"
for VL in 128 256 512 1024; do
    echo -n "  qemu vlen=$VL:    "
    PYTHONPATH=submodules/pystencils/src \
        qemu-riscv64 -cpu "rv64,v=true,vlen=$VL" "$PY" "$HERE/vlen_sweep.py"
done
