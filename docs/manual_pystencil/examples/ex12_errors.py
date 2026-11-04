"""Chapter 4: what pystencils rejects at code-generation time (and why)."""

from _manual import save

import sympy as sp
import pystencils as ps

f, g = ps.fields("f, g: double[2D]")
i = ps.fields("i: int64[2D]")


def vec_cfg(target, **kw):
    cfg = ps.CreateKernelConfig(target=target, **kw)
    cfg.cpu.vectorize.enable = True
    return cfg


cases = [
    ("in-place stencil: f[0,0] <- f[1,0]",
     lambda: ps.create_kernel(ps.Assignment(f.center, f[1, 0]))),
    ("write f[0,0], then read f[1,0]",
     lambda: ps.create_kernel([ps.Assignment(f.center, 1.0),
                               ps.Assignment(g.center, f[1, 0])])),
    ("same symbol assigned twice (not SSA)",
     lambda: ps.create_kernel([ps.Assignment(sp.Symbol("t"), f.center),
                               ps.Assignment(sp.Symbol("t"), 2 * f.center),
                               ps.Assignment(g.center, sp.Symbol("t"))])),
    ("float value stored into int64 field",
     lambda: ps.create_kernel(ps.Assignment(i.center, f.center))),
    ("int counter added to float, no cast",
     lambda: ps.create_kernel(ps.Assignment(g.center, f.center + ps.x_))),
    ("ghost_layers and iteration_slice both set",
     lambda: ps.create_kernel(ps.Assignment(g.center, f.center), ghost_layers=1,
                              iteration_slice=ps.make_slice[1:-1, 1:-1])),
    ("vectorize on Target.GenericCPU",
     lambda: ps.create_kernel(ps.Assignment(g.center, f.center),
                              vec_cfg(ps.Target.GenericCPU))),
    ("AVX, symbolic inner stride (needs scatter)",
     lambda: ps.create_kernel(ps.Assignment(g.center, f.center),
                              vec_cfg(ps.Target.X86_AVX))),
    ("exp() vectorized for AVX (no SVML)",
     lambda: ps.create_kernel(ps.Assignment(g.center, sp.exp(f.center)),
                              vec_cfg(ps.Target.X86_AVX, ghost_layers=0))),
    ("exp() vectorized for RISCV_RVV",
     lambda: ps.create_kernel(ps.Assignment(g.center, sp.exp(f.center)),
                              vec_cfg(ps.Target.RISCV_RVV, ghost_layers=0))),
]

lines = []
for label, make in cases:
    try:
        make()
        lines.append(f"{label}\n    -> accepted")
    except Exception as e:  # noqa: BLE001
        msg = " ".join(str(e).split())
        if len(msg) > 150:
            msg = msg[:147] + "..."
        lines.append(f"{label}\n    -> {type(e).__name__}: {msg}")
save("errors", "\n".join(lines))
