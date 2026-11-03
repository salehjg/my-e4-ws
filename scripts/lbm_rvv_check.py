#!/usr/bin/env python3
"""LBM backend check: verify the D2Q9 BGK collide kernel produces the same results on
the RVV backend (VLS, VLEN = 256) as on the generic scalar backend, in f64 and f32.

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


def make_config(target, dtype="f64"):
    cfg = ps.CreateKernelConfig()
    cfg.default_dtype = "float32" if dtype == "f32" else "float64"
    if target == "rvv":
        #   Default lanes: one 256-bit register (4 x f64 / 8 x f32), like AVX
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
    return cfg


def build_collide(cfg, dtype="f64"):
    dt = "float32" if dtype == "f32" else "float64"
    flds = ps.fields(
        f"f0,f1,f2,f3,f4,f5,f6,f7,f8, g0,g1,g2,g3,g4,g5,g6,g7,g8: {dt}[2D]"
    )
    f, g = flds[:Q], flds[Q:]
    omega = ps.TypedSymbol("omega", dt)
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
    #   CSE as in lb-pystencils.py: without it every g_i recomputes rho, 1/rho, u^2
    return ps.create_kernel(ps.simp.sympy_cse(ps.AssignmentCollection(asms)), config=cfg).compile()


def run_collide(kernel, f_arrs, g_arrs, omega):
    args = {f"f{i}": f_arrs[i] for i in range(Q)}
    args.update({f"g{i}": g_arrs[i] for i in range(Q)})
    args["omega"] = omega
    kernel(**args)


#   RVV-vs-generic tolerance per precision. Both backends compute in the same
#   precision, so the only divergence is FMA contraction / reassociation, which is
#   ~machine-eps relative; f32 gets a correspondingly looser bound.
_TOL = {"f64": dict(rtol=1e-12, atol=1e-14), "f32": dict(rtol=1e-4, atol=1e-5)}


def main() -> int:
    nx, ny = 16, 51  # 51: not a multiple of the lane count -> remainder loop runs too
    rng = np.random.default_rng(1234)
    rc = 0
    for dtype in ("f64", "f32"):
        npdt = np.float32 if dtype == "f32" else np.float64
        f_ref = [np.ascontiguousarray(rng.random((nx, ny)) * 0.1 + 0.5, dtype=npdt)
                 for _ in range(Q)]
        omega = npdt(1.2)
        tol = _TOL[dtype]

        #   Reference: generic scalar backend at the same precision.
        kref = build_collide(make_config("generic", dtype), dtype)
        g_ref = [np.zeros((nx, ny), dtype=npdt) for _ in range(Q)]
        run_collide(kref, f_ref, g_ref, omega)

        k = build_collide(make_config("rvv", dtype), dtype)
        g = [np.zeros((nx, ny), dtype=npdt) for _ in range(Q)]
        run_collide(k, f_ref, g, omega)
        ok = all(np.allclose(g[i], g_ref[i], **tol) for i in range(Q))
        maxerr = max(float(np.max(np.abs(g[i] - g_ref[i]))) for i in range(Q))
        print(f"collide {dtype} rvv: match={ok} max_abs_err={maxerr:.3e}")
        rc |= 0 if ok else 1

    print("LBM RVV collide check:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
