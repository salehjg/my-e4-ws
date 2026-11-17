#!/usr/bin/env python3
"""Per-config performance probe (Phase 0).

For one (kernel, target, mode, dtype, compiler, vector-bits) configuration:
  * build the D2Q9 collide and/or pull-stream kernel,
  * time it -> MLUP/s,
  * disassemble the freshly compiled .so and print an op / real-spill histogram
    (FMA contraction, .vf/.vx scalar-operand forms, vfmv broadcasts, whole-register
    vector spills vl*r.v/vs*r.v, and f-register spills fld/fsd), and
  * optionally re-run the timed loop under `perf stat` for cycles/instructions/IPC.

The .so is pinned to a per-config objcache dir so exactly one module_*.so exists to
disassemble, and repeated runs of the same config skip recompilation.

Board only. Keep all paths under /home/bananapi/saleh/.

Examples:
    python scripts/rvv_perf_probe.py --kind collide --target rvv --mode fixed \
        --dtype f64 --vector-bits --perf
    python scripts/rvv_perf_probe.py --kind stream --target generic --dtype f32
"""
import argparse
import os
import platform
import re
import subprocess
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "submodules", "pystencils", "src"))

import pystencils as ps  # noqa: E402
from pystencils.jit.cpu import CpuJit, GccInfo, ClangInfo  # noqa: E402

C = np.array(
    [[0, 0], [1, 0], [0, 1], [-1, 0], [0, -1], [1, 1], [-1, 1], [-1, -1], [1, -1]],
    dtype=np.int32,
)
W = np.array([4/9, 1/9, 1/9, 1/9, 1/9, 1/36, 1/36, 1/36, 1/36], dtype=np.float64)
Q = 9

_CACHE_ROOT = os.path.join(_HERE, ".perfcache")


def config_id(a):
    return (f"{a.kind}_{a.target}_{a.mode}_{a.dtype}_{a.compiler}"
            f"_vb{int(a.vector_bits)}_vlen{a.vlen}")


def build_jit(a):
    info_cls = ClangInfo if a.compiler == "clang" else GccInfo
    extra = list(a.extra_cxxflags.split()) if a.extra_cxxflags else []
    if a.unroll:
        extra.append("-funroll-loops")
    #   Arch-qualified so x86 dev artifacts never collide with board riscv64 ones
    #   (the two share config_id but must never share a .so).
    objcache = os.path.join(_CACHE_ROOT, platform.machine(), config_id(a))
    os.makedirs(objcache, exist_ok=True)
    if a.target == "rvv":
        fixed = a.mode == "fixed" and a.vector_bits
        info = info_cls(target=ps.Target.RISCV_RVV, rvv_vlen=a.vlen,
                        rvv_fixed_length=fixed, extra_cxxflags=extra)
    else:
        info = info_cls(target=ps.Target.CurrentCPU, extra_cxxflags=extra)
    return CpuJit(info, objcache=objcache), objcache


def make_cfg(a, iteration_slice=None):
    cfg = ps.CreateKernelConfig()
    if iteration_slice is not None:
        cfg.iteration_slice = iteration_slice
    cfg.default_dtype = "float32" if a.dtype == "f32" else "float64"
    width = 32 if a.dtype == "f32" else 64
    if a.target == "rvv":
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
        cfg.cpu.vectorize.mode = a.mode
        cfg.cpu.rvv.vlen = a.vlen
        if a.mode == "fixed":
            cfg.cpu.vectorize.lanes = a.lanes or (a.vlen // width)
    jit, objcache = build_jit(a)
    cfg.jit = jit
    return cfg, objcache


def _fields(dt):
    return ps.fields(
        "f0,f1,f2,f3,f4,f5,f6,f7,f8, g0,g1,g2,g3,g4,g5,g6,g7,g8: "
        f"{dt}[2D]"
    )


def build_collide(a):
    cfg, objcache = make_cfg(a)
    dt = "float32" if a.dtype == "f32" else "float64"
    flds = _fields(dt)
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
    return ps.create_kernel(asms, config=cfg).compile(), objcache


def build_stream(a):
    interior = (slice(1, -1), slice(1, -1))
    cfg, objcache = make_cfg(a, interior)
    dt = "float32" if a.dtype == "f32" else "float64"
    flds = _fields(dt)
    f, g = flds[:Q], flds[Q:]
    asms = [ps.Assignment(f[i][0, 0], g[i][-int(cx), -int(cy)])
            for i, (cx, cy) in enumerate(C)]
    return ps.create_kernel(asms, config=cfg).compile(), objcache


def make_arrays(a):
    npdt = np.float32 if a.dtype == "f32" else np.float64
    rng = np.random.default_rng(1234)
    f = [np.ascontiguousarray(rng.random((a.nx, a.ny)) * 0.1 + 0.5, dtype=npdt)
         for _ in range(Q)]
    g = [np.zeros((a.nx, a.ny), dtype=npdt) for _ in range(Q)]
    return f, g, npdt


def runner_for(a, kernel):
    f, g, npdt = make_arrays(a)
    if a.kind == "collide":
        args = {f"f{i}": f[i] for i in range(Q)}
        args.update({f"g{i}": g[i] for i in range(Q)})
        args["omega"] = npdt(1.2)
    else:  # stream
        args = {f"f{i}": f[i] for i in range(Q)}
        args.update({f"g{i}": g[i] for i in range(Q)})

    def run():
        kernel(**args)
    return run


def bench(run, cells, iters):
    run()  # warm
    t0 = time.perf_counter()
    for _ in range(iters):
        run()
    dt = time.perf_counter() - t0
    return cells * iters / dt / 1e6, dt  # MLUP/s


def find_so(objcache):
    sos = [os.path.join(objcache, f) for f in os.listdir(objcache)
           if f.startswith("module_") and f.endswith(".so")]
    if not sos:
        return None
    return max(sos, key=os.path.getmtime)


_PATTERNS = {
    "vfmacc/vfmadd (FMA)": r"\bvf(n?m(acc|add|sac|sub))\.",
    ".vf/.vx scalar-op":   r"\bv[if]?\w+\.v[fx]\b",
    "vfmv.v.f broadcast":  r"\bvf?mv\.v\.[fx]\b",
    "vmv[124]r.v reg-move": r"\bvmv[124]r\.v\b",
    "vle/vse (vec ld/st)": r"\bv[ls]e\d+\.v\b",
    "vlse/vsse (strided)": r"\bv[ls]se\d+\.v\b",
    "vl*r.v/vs*r.v spill": r"\bv[ls]\d+r\.v\b",
    "fld/fsd f-spill":     r"\bf(ld|sd)\b",
    "vset*":               r"\bvset\w+\b",
}


def histogram(so_path):
    if so_path is None:
        print("  (no .so found to disassemble)")
        return
    try:
        out = subprocess.run(["objdump", "-d", so_path], capture_output=True,
                             text=True, check=True).stdout
    except Exception as e:  # noqa: BLE001
        print(f"  (objdump failed: {e})")
        return
    print(f"  disasm histogram ({os.path.basename(so_path)}):")
    for label, pat in _PATTERNS.items():
        n = len(re.findall(pat, out))
        print(f"    {label:24s} {n}")


def run_perf(a, cells, iters):
    flags = [
        sys.executable, os.path.abspath(__file__),
        "--role", "inner", "--kind", a.kind, "--target", a.target,
        "--mode", a.mode, "--dtype", a.dtype, "--compiler", a.compiler,
        "--vlen", str(a.vlen), "--nx", str(a.nx), "--ny", str(a.ny),
        "--iters", str(iters),
    ]
    flags += ["--vector-bits"] if a.vector_bits else ["--no-vector-bits"]
    if a.unroll:
        flags.append("--unroll")
    if a.extra_cxxflags:
        flags += ["--extra-cxxflags", a.extra_cxxflags]
    if a.lanes:
        flags += ["--lanes", str(a.lanes)]

    events = "cycles,instructions"
    cmd = ["perf", "stat", "-e", events, "--"] + flags
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 and "cycles" in r.stderr and "not" in r.stderr.lower():
        cmd = ["perf", "stat", "--"] + flags  # fall back to default events
        r = subprocess.run(cmd, capture_output=True, text=True)
    print("  perf stat (kernel-dominated run):")
    for line in r.stderr.splitlines():
        if any(k in line for k in ("cycles", "instructions", "insn per",
                                   "task-clock", "GHz", "elapsed")):
            print("   ", line.strip())
    #   surface the inner MLUP/s the child printed on stdout
    for line in r.stdout.splitlines():
        if "INNER_MLUPS" in line:
            print("   ", line.strip())


def build(a):
    return build_collide(a) if a.kind == "collide" else build_stream(a)


def cells_of(a):
    if a.kind == "stream":
        return (a.nx - 2) * (a.ny - 2)
    return a.nx * a.ny


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["collide", "stream"], default="collide")
    ap.add_argument("--target", choices=["generic", "rvv"], default="rvv")
    ap.add_argument("--mode", choices=["fixed", "vla"], default="fixed")
    ap.add_argument("--dtype", choices=["f64", "f32"], default="f64")
    ap.add_argument("--compiler", choices=["gcc", "clang"], default="gcc")
    ap.add_argument("--vector-bits", action=argparse.BooleanOptionalAction,
                    default=True)
    ap.add_argument("--unroll", action="store_true")
    ap.add_argument("--extra-cxxflags", default="")
    ap.add_argument("--vlen", type=int, default=256)
    ap.add_argument("--lanes", type=int, default=None)
    ap.add_argument("--nx", type=int, default=200)
    ap.add_argument("--ny", type=int, default=200)
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--perf", action="store_true")
    ap.add_argument("--role", choices=["outer", "inner"], default="outer")
    a = ap.parse_args()

    kernel, objcache = build(a)
    run = runner_for(a, kernel)
    cells = cells_of(a)

    if a.role == "inner":
        mlups, _ = bench(run, cells, a.iters)
        print(f"INNER_MLUPS {mlups:.3f}")
        return 0

    print(f"config: {config_id(a)}  grid={a.nx}x{a.ny} iters={a.iters}")
    mlups, secs = bench(run, cells, a.iters)
    print(f"  MLUP/s = {mlups:.3f}  ({secs:.3f}s for {a.iters} iters)")
    histogram(find_so(objcache))
    if a.perf:
        run_perf(a, cells, a.iters)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
