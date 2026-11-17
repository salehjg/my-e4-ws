#!/usr/bin/env python3
"""VLA acceptance harness (WP7): build one VLA kernel, run it on deterministic input,
and print a hash of the output field.

Run the *same* process under `qemu-riscv64 -cpu rv64,v=true,vlen=N` for several N and
compare the printed hashes: a correct vector-length-agnostic kernel produces
bit-identical field output at every VLEN. See scripts/run_vlen_sweep.sh.
"""
import os
import sys
import hashlib

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "submodules", "pystencils", "src"))

from pystencils import (  # noqa: E402
    Target,
    CreateKernelConfig,
    create_kernel,
    fields,
    Assignment,
)
from pystencils.jit import CpuJit  # noqa: E402
from pystencils.jit.cpu import GccInfo  # noqa: E402


def build_vla_kernel(vlen_floor: int = 128):
    f, g = fields("f, g: float64[2D]", layout="c")
    cfg = CreateKernelConfig()
    cfg.target = Target.RISCV_RVV
    cfg.default_dtype = "float64"
    cfg.index_dtype = "int64"
    cfg.cpu.vectorize.enable = True
    cfg.cpu.vectorize.mode = "vla"
    cfg.cpu.vectorize.assume_inner_stride_one = True
    cfg.cpu.rvv.vlen = vlen_floor
    #   Pin an explicit RVV -march (not CurrentCPU) so native and QEMU runs produce the
    #   *same* object-cache key -> the SAME .so is executed at every emulated VLEN
    #   (a true vector-length-agnostic-binary test), and we avoid QEMU's cpuinfo (svadu).
    cfg.jit = CpuJit(GccInfo(target=Target.RISCV_RVV, rvv_vlen=vlen_floor))
    #   A small polynomial: exercises +, -, * and broadcasts of scalar constants.
    expr = 3.0 * f.center() * f.center() - 2.0 * f.center() + 1.0
    return create_kernel([Assignment(g.center(), expr)], cfg).compile()


def main() -> int:
    k = build_vla_kernel()
    #   Deterministic input; inner extent 103 is prime -> exercises a ragged tail.
    n0, n1 = 7, 103
    f = np.ascontiguousarray(
        (np.arange(n0 * n1, dtype=np.float64).reshape(n0, n1) * 1e-3) - 3.0
    )
    g = np.zeros_like(f)
    k(f=f, g=g)

    ref = 3.0 * f * f - 2.0 * f + 1.0
    #   -ffast-math/FMA make the kernel differ from NumPy in the last bit, so compare
    #   with a tolerance for the "matches reference" check; the cross-VLEN acceptance
    #   is the *bit-identical hash* (same binary, different emulated VLEN).
    close = np.allclose(g, ref, rtol=1e-12, atol=1e-14)
    digest = hashlib.sha256(g.tobytes()).hexdigest()
    print(f"OUTPUT_HASH {digest}  MATCHES_NUMPY {close}")
    return 0 if close else 1


if __name__ == "__main__":
    raise SystemExit(main())
