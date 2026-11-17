"""Dump the D2Q9 LBM kernels as standalone C++ translation units (out-of-tree experiment).

Why: inside the JIT we only see a whole-run MLUP/s number. Here every kernel becomes a
plain .cpp that `run.sh` compiles with different compilers/flags and links against
`bench.cpp`, so kernels can be timed, counted with perf counters, disassembled -- and
hand-edited to test a hypothesis -- without touching pystencils.

Kernels (same assignments as python/learn-lb-pystencil/lb-pystencils.py):
  stream     g_i(x) = f_i(x - c_i)                 -- memory traffic only, no arithmetic
  fused      pull collide-stream, as the harness builds it (no CSE)
  fused_cse  the same assignments after `ps.simp.sympy_cse`
  fused_cse_neg / fused_cse_fma / fused_cse_vf
             fused_cse with the RVV code rewritten by fma_rewrite.py (negations folded /
             plus FMAs fused / constant splats passed as scalars): hand checks of what such
             a step in the backend would gain.
             Their generic sources equal fused_cse (compilers already do this for scalar C).
each for target `generic` (GenericCPU, scalar C) and `rvv` (RISCV_RVV, our intrinsics).

Each kernel becomes two translation units:
  NAME.cpp       the generated kernel, unchanged, with C linkage
  NAME.wrap.cpp  a fixed-signature wrapper `run_kernel(f, g, nx, ny, stride0, omega)` that maps
                 pystencils' parameters by name and calls the kernel
They are compiled separately on purpose. With the wrapper in the kernel's TU, the compiler
inlined the constant strides: inner stride 1, and one row stride shared by all 18 arrays.
That gave the generic (autovec) kernel knowledge the JIT never gives it, because in
pystencils' JIT every size and stride is a runtime argument.

Usage: python gen.py OUTDIR      (needs PYTHONPATH=submodules/pystencils/src)
"""

import pathlib
import re
import sys

import sympy as sp
import pystencils as ps

import fma_rewrite

C = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)]
W = [4 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 36, 1 / 36, 1 / 36, 1 / 36]
Q = 9
DTYPES = {"f64": ("float64", "double"), "f32": ("float32", "float")}
KINDS = ("stream", "fused", "fused_cse", "fused_cse_neg", "fused_cse_fma", "fused_cse_vf")


def make_assignments(kind: str, dtype: str):
    flds = ps.fields(
        ", ".join(f"f{i}" for i in range(Q)) + ", "
        + ", ".join(f"g{i}" for i in range(Q)) + f": {dtype}[2D]"
    )
    f, g = flds[:Q], flds[Q:]

    #   Pulled (streamed) populations arriving at this cell
    p = [f[i][-cx, -cy] for i, (cx, cy) in enumerate(C)]
    if kind == "stream":
        return [ps.Assignment(g[i][0, 0], p[i]) for i in range(Q)]

    #   BGK collision, written exactly like the harness' build_fused_collide_stream_kernel
    omega = sp.Symbol("omega")
    rho = sum(p)
    ux = (p[1] - p[3] + p[5] - p[6] - p[7] + p[8]) / rho
    uy = (p[2] - p[4] + p[5] + p[6] - p[7] - p[8]) / rho
    u_sq = ux * ux + uy * uy
    asms = []
    for i, (cx, cy) in enumerate(C):
        cu = float(cx) * ux + float(cy) * uy
        feq = float(W[i]) * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * u_sq)
        asms.append(ps.Assignment(g[i][0, 0], p[i] - omega * (p[i] - feq)))

    if kind.startswith("fused_cse"):
        return ps.simp.sympy_cse(ps.AssignmentCollection(asms))
    return asms


def make_config(target: str, dtype: str):
    #   Mirrors the harness' make_config(interior): GenericCPU, or RVV + vectorization
    cfg = ps.CreateKernelConfig(default_dtype=dtype, iteration_slice=(slice(1, -1), slice(1, -1)))
    if target == "rvv":
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
    return cfg


def wrapper_arg(name: str) -> str:
    """C++ expression for a kernel parameter, given the wrapper's (f, g, nx, ny, stride0, omega).

    All 18 arrays share one shape and row-major layout (like the harness' NumPy arrays),
    so every size/stride parameter maps to the same few values.
    """
    if m := re.fullmatch(r"_data_([fg])(\d)", name):
        return f"{m[1]}[{m[2]}]"
    if m := re.fullmatch(r"_size_[fg]\d_([01])", name):
        return ("nx", "ny")[int(m[1])]
    if m := re.fullmatch(r"_stride_[fg]\d_([01])", name):
        return ("stride0", "1")[int(m[1])]
    if name == "omega":
        return "omega"
    raise ValueError(f"unexpected kernel parameter {name!r}")


def decl_type(name: str, ctype: str) -> str:
    """Parameter type for the wrapper's declaration of `kernel`.

    With C linkage, `T *` for both `const T *` and `T *` parameters is ABI-compatible.
    """
    return f"{ctype} *" if name.startswith("_data_") else ctype if name == "omega" else "int64_t"


def emit(kind: str, target: str, dt_key: str) -> tuple[str, str]:
    """Return (kernel TU, wrapper TU)."""
    dtype, ctype = DTYPES[dt_key]
    kernel = ps.create_kernel(make_assignments(kind, dtype), make_config(target, dtype))
    code, note = kernel.get_c_code(), ""
    if kind in ("fused_cse_neg", "fused_cse_fma", "fused_cse_vf") and target == "rvv":
        code, stats = fma_rewrite.rewrite(code, kind.rsplit("_", 1)[1])
        note = f" rewrites={dict(stats)}"
    header = f"// generated by misc/rvv-vs-autovec/gen.py: kind={kind} target={target} dtype={dtype}{note}"
    kernel_tu = "\n".join(
        [header]
        + [f"#include {h}" for h in sorted(kernel.required_headers)]
        + ["#define RESTRICT __restrict__", "", 'extern "C" {', code, '}  // extern "C"', ""]
    )
    params = ", ".join(f"{decl_type(p.name, ctype)} {p.name}" for p in kernel.parameters)
    args = ", ".join(wrapper_arg(p.name) for p in kernel.parameters)
    wrapper_tu = "\n".join([
        header + " (wrapper)",
        "#include <cstdint>",
        "",
        f'extern "C" void kernel({params});',
        "",
        f'extern "C" void run_kernel({ctype} * const * f, {ctype} * const * g,',
        f"                           int64_t nx, int64_t ny, int64_t stride0, {ctype} omega)",
        "{",
        "   (void) omega;   // unused by the stream kernel",
        f"   kernel({args});",
        "}",
        "",
    ])
    return kernel_tu, wrapper_tu


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for dt_key in DTYPES:
        for kind in KINDS:
            for target in ("generic", "rvv"):
                kernel_tu, wrapper_tu = emit(kind, target, dt_key)
                name = f"{dt_key}-{kind}-{target}"
                (out / f"{name}.cpp").write_text(kernel_tu)
                (out / f"{name}.wrap.cpp").write_text(wrapper_tu)
                print(f"wrote {out / name}.cpp (+ .wrap.cpp)")


if __name__ == "__main__":
    main()
