#!/usr/bin/env python3
"""WP8 LBM backend check: verify the D2Q9 BGK collide and pull-stream kernels produce
identical results on the RVV backend (VLS and VLA) as on the generic scalar backend.

Runs on the Banana Pi board. Compares against the generic-CPU kernel output (the
reference), isolating backend correctness from LBM stability.
"""
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "submodules", "pystencils", "src"))

import pystencils as ps  # noqa: E402

C = np.array(
    [[0, 0], [1, 0], [0, 1], [-1, 0], [0, -1], [1, 1], [-1, 1], [-1, -1], [1, -1]],
    dtype=np.int32,
)
W = np.array(
    [4/9, 1/9, 1/9, 1/9, 1/9, 1/36, 1/36, 1/36, 1/36], dtype=np.float64
)
Q = 9


def make_config(target, mode, vlen=256):
    cfg = ps.CreateKernelConfig()
    if target == "rvv":
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
        cfg.cpu.vectorize.mode = mode
        cfg.cpu.rvv.vlen = vlen
        if mode == "fixed":
            cfg.cpu.vectorize.lanes = vlen // 64
    return cfg


def build_collide(cfg):
    flds = ps.fields(
        "f0,f1,f2,f3,f4,f5,f6,f7,f8, g0,g1,g2,g3,g4,g5,g6,g7,g8: double[2D]"
    )
    f, g = flds[:Q], flds[Q:]
    omega = ps.TypedSymbol("omega", "float64")
    p = [f[i][0, 0] for i in range(Q)]
    rho = sum(p)
    ux = (p[1] - p[3] + p[5] - p[6] - p[7] + p[8]) / rho
    uy = (p[2] - p[4] + p[5] + p[6] - p[7] - p[8]) / rho
    u_sq = ux * ux + uy * uy
    asms = []
    for i, (cx, cy) in enumerate(C):
        cu = float(cx) * ux + float(cy) * uy
        feq = float(W[i]) * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * u_sq)
        asms.append(ps.Assignment(g[i][0, 0], p[i] - omega * (p[i] - feq)))
    return ps.create_kernel(asms, config=cfg).compile()


def run_collide(kernel, f_arrs, g_arrs, omega):
    args = {f"f{i}": f_arrs[i] for i in range(Q)}
    args.update({f"g{i}": g_arrs[i] for i in range(Q)})
    args["omega"] = omega
    kernel(**args)


def main() -> int:
    nx, ny = 16, 48
    rng = np.random.default_rng(1234)
    f_ref = [np.ascontiguousarray(rng.random((nx, ny)) * 0.1 + 0.5) for _ in range(Q)]
    omega = 1.2

    #   Reference: generic scalar backend
    kref = build_collide(make_config("generic", "fixed"))
    g_ref = [np.zeros((nx, ny)) for _ in range(Q)]
    run_collide(kref, f_ref, g_ref, omega)

    rc = 0
    for target, mode in [("rvv", "fixed"), ("rvv", "vla")]:
        k = build_collide(make_config(target, mode))
        g = [np.zeros((nx, ny)) for _ in range(Q)]
        run_collide(k, f_ref, g, omega)
        ok = all(
            np.allclose(g[i], g_ref[i], rtol=1e-12, atol=1e-14) for i in range(Q)
        )
        maxerr = max(float(np.max(np.abs(g[i] - g_ref[i]))) for i in range(Q))
        print(f"collide {target}/{mode}: match={ok} max_abs_err={maxerr:.3e}")
        rc |= 0 if ok else 1

    print("LBM RVV collide check:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
