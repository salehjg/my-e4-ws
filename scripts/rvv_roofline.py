#!/usr/bin/env python3
"""Roofline / datapath probe (Phase 0).

Measure the K1's *achievable* vector-vs-scalar FLOP rate on a compute-bound
micro-kernel (independent Horner-polynomial chains: high arithmetic intensity, so
memory is not the limit), for both f64 and f32.

Why: the performance plan claims the X60 has a 128-bit-wide vector datapath behind
its VLEN=256 registers, giving f64 compute a ~2x ceiling over scalar. This confirms
it empirically:
  * vector/scalar ~2x (f64) and ~4x (f32)  => 128-bit datapath.
  * vector/scalar ~4x (f64) and ~8x (f32)  => full 256-bit datapath.

Board only — GFLOP/s under QEMU is meaningless.

Usage:
    python scripts/rvv_roofline.py [--compiler gcc|clang] [--vlen 256] [--n 16384]
"""
import argparse
import os
import sys
import time

import numpy as np
import sympy as sp

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "submodules", "pystencils", "src"))

import pystencils as ps  # noqa: E402
from pystencils.jit.cpu import CpuJit, GccInfo, ClangInfo  # noqa: E402

NACC = 8   # independent accumulator chains -> exposes ILP to saturate throughput
CHAIN = 8  # FMAs per chain
FLOPS_PER_ELEM = NACC * CHAIN * 2 + (NACC - 1)  # FMA=2 flops, plus the final sum


def _jit(target, compiler, vlen):
    info_cls = ClangInfo if compiler == "clang" else GccInfo
    if target == "rvv":
        return CpuJit(info_cls(target=ps.Target.RISCV_RVV, rvv_vlen=vlen,
                               rvv_fixed_length=True))
    return CpuJit(info_cls(target=ps.Target.CurrentCPU))


def build(target, dtype, compiler, vlen):
    dt = "float32" if dtype == "f32" else "float64"
    width = 32 if dtype == "f32" else 64
    f, g = ps.fields(f"f, g: {dt}[1D]")
    x = f.center()

    #   Build NACC independent Horner chains via explicit subexpression
    #   assignments so sympy cannot expand the polynomial into a dense form;
    #   each `s*x + c` stays a single FMA and the chains are data-independent.
    asms = []
    accs = []
    for j in range(NACC):
        s = sp.Symbol(f"a{j}_0")
        asms.append(ps.Assignment(s, sp.Float(0.5 + 0.001 * j) * x + sp.Float(1.0)))
        for k in range(1, CHAIN):
            s2 = sp.Symbol(f"a{j}_{k}")
            asms.append(ps.Assignment(s2, s * x + sp.Float(1.0 + 0.002 * k)))
            s = s2
        accs.append(s)
    tot = accs[0]
    for a in accs[1:]:
        tot = tot + a
    asms.append(ps.Assignment(g.center(), tot))

    cfg = ps.CreateKernelConfig()
    cfg.default_dtype = dt
    if target == "rvv":
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
        cfg.cpu.vectorize.mode = "fixed"
        cfg.cpu.rvv.vlen = vlen
        cfg.cpu.vectorize.lanes = vlen // width
    cfg.jit = _jit(target, compiler, vlen)
    return ps.create_kernel(asms, config=cfg).compile()


def bench(kernel, n, npdt):
    f = np.ascontiguousarray(np.linspace(0.0, 0.9, n, dtype=npdt))
    g = np.zeros(n, dtype=npdt)
    kernel(f=f, g=g)  # warm-up + correctness sanity
    if not np.isfinite(g).all():
        raise RuntimeError("non-finite output — polynomial overflowed")

    flops_per_call = n * FLOPS_PER_ELEM
    iters = max(30, int(2.0e9 / flops_per_call))
    t0 = time.perf_counter()
    for _ in range(iters):
        kernel(f=f, g=g)
    dt = time.perf_counter() - t0
    gflops = flops_per_call * iters / dt / 1e9
    return gflops, iters


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", choices=["gcc", "clang"], default="gcc")
    ap.add_argument("--vlen", type=int, default=256)
    ap.add_argument("--n", type=int, default=16384)
    args = ap.parse_args()

    print(f"roofline: compiler={args.compiler} vlen={args.vlen} n={args.n} "
          f"NACC={NACC} CHAIN={CHAIN} flops/elem={FLOPS_PER_ELEM}")
    results = {}
    for dtype in ("f64", "f32"):
        npdt = np.float32 if dtype == "f32" else np.float64
        for target in ("generic", "rvv"):
            k = build(target, dtype, args.compiler, args.vlen)
            gflops, iters = bench(k, args.n, npdt)
            results[(dtype, target)] = gflops
            print(f"  {dtype} {target:8s}: {gflops:8.3f} GFLOP/s  (iters={iters})")
    for dtype in ("f64", "f32"):
        s = results[(dtype, "generic")]
        v = results[(dtype, "rvv")]
        print(f"  RATIO {dtype}: rvv/scalar = {v / s:.2f}x")
    print("interpretation: ~2x(f64)/~4x(f32) => 128-bit datapath; "
          "~4x/~8x => 256-bit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
